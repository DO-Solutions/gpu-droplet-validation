#!/usr/bin/env bash
# RCCL perf container. RCCL is AMD's NCCL; rccl-tests build the same
# *_perf binary names as nccl-tests. One image, two services selected via
# $RCCL_TEST:
#   - allreduce: all_reduce_perf
#   - alltoall : alltoall_perf
#
# Per decision: pass == exit code 0 for BOTH collectives (exit-code-only
# gate — single known-bad host means no trusted busbw baseline yet). We
# still parse per-size + avg busbw and stash it in the diagnostic so a
# bandwidth floor can be calibrated later. No NVLink-transport assertion
# (that is NVIDIA-specific).
#
# Both runs capture a concurrent rocm-smi sample stream to
# /results/<suite>_dmon.log (the AMD analogue of `nvidia-smi dmon`).
# SUITE drives both the result-file basename and the in-TAP suite label;
# tap-reporter's SUITE_FILES expects rccl-allreduce.json / rccl-alltoall.json.
SUITE="rccl-${RCCL_TEST:-unknown}"
source /lib/result.sh
source /lib/amd_models.sh

: "${GPU_COUNT:?GPU_COUNT is not set}"
: "${RCCL_TEST:?RCCL_TEST must be allreduce or alltoall}"

case "$RCCL_TEST" in
  allreduce) BIN_CANDIDATES="all_reduce_perf" ;;
  alltoall)  BIN_CANDIDATES="alltoall_perf"   ;;
  *) die "unsupported RCCL_TEST: $RCCL_TEST" ;;
esac

# Find the binary. rccl-tests images vary on layout; check common paths.
find_bin() {
  local b="$1"
  if command -v "$b" >/dev/null 2>&1; then command -v "$b"; return 0; fi
  local p
  for p in /workspace/rccl-tests/build/$b /opt/rccl-tests/build/$b \
           /rccl-tests/build/$b /usr/local/bin/$b /usr/bin/$b; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  p="$(find / -maxdepth 6 -type f -name "$b" -executable 2>/dev/null | head -n1)"
  [ -n "$p" ] && { echo "$p"; return 0; }
  return 1
}

BIN="$(find_bin "$BIN_CANDIDATES")" || die "could not locate $BIN_CANDIDATES in image"
log "binary: $BIN"

OUT_JSON="/results/${SUITE}.json"
DMON_LOG="/results/${SUITE}_dmon.log"

# AMD analogue of `nvidia-smi dmon`: sample power/temp/util/vram every 1s.
# `amd-smi monitor` is the modern equivalent; fall back to rocm-smi loop.
if command -v amd-smi >/dev/null 2>&1; then
  amd-smi monitor -p -t -u -v > "$DMON_LOG" 2>/dev/null &
  DMON_PID=$!
else
  ( while true; do date -u +%Y-%m-%dT%H:%M:%SZ; rocm-smi 2>/dev/null; sleep 1; done ) > "$DMON_LOG" 2>/dev/null &
  DMON_PID=$!
fi
# shellcheck disable=SC2064
trap "kill $DMON_PID 2>/dev/null || true" EXIT

run_rccl_perf() {
  "$BIN" -b 32K -e 8G -f 2 -g "$GPU_COUNT" -w 5 -n 20
}

# rccl-tests perf rows mirror nccl-tests exactly. Columns:
#   size count type redop root | time algbw busbw err | time algbw busbw err
#    $1   $2   $3    $4   $5     $6    $7    $8   $9    $10   $11   $12  $13
# busbw is $8 (out-of-place) / $12 (in-place). Reported for later floor
# calibration only — not gated here.
parse_per_size() {
  awk '
    /^#/ { next }
    NF >= 13 && $1 ~ /^[0-9]+$/ {
      printf "{\"size\":%s,\"busbw_oop\":%s,\"busbw_ip\":%s}\n", $1, $8, $12
    }
  ' "$1"
}
parse_avg_busbw() {
  awk -F: '/Avg bus bandwidth/ { gsub(/ /,"",$2); print $2; exit }' "$1"
}

run_file="/tmp/rccl-${SUITE}.log"
rc=0
log "perf run ($RCCL_TEST)"
run_rccl_perf > "$run_file" 2>&1 || rc=$?
cp "$run_file" "/results/${SUITE}_run.log" || true

per_size_all="$(parse_per_size "$run_file" | jq -s '.')"
avg="$(parse_avg_busbw "$run_file")"

pass=true
[ "$rc" -eq 0 ] || pass=false

# On failure prepend a human-readable `message` field (convention: every
# not-ok diagnostic starts with `message`). busbw fields are kept on pass
# too — useful for the future floor calibration.
diag="$(jq -n \
  --arg avg "${avg:-}" \
  --argjson per_size "$per_size_all" \
  --argjson rc "$rc" \
  --argjson pass "$pass" '
  { exit_code: $rc, avg_busbw_GBps: $avg, per_size_table: $per_size }
  | if $pass then . else { message: "'"$BIN_CANDIDATES"' exited with code \($rc) — the RCCL collective could not complete" } + . end')"

tests="$(jq -n --argjson pass "$pass" --argjson diag "$diag" \
  --arg name "RCCL ${BIN_CANDIDATES} exit code == 0" '[
  { ok: $pass, name: $name, directive: null, diagnostic: $diag }
]')"

jq -n --arg suite "$SUITE" --argjson tests "$tests" \
  '{ suite: $suite, tests: $tests }' > "$OUT_JSON"
log "ok (exit=$rc avg_busbw=${avg:-<none>})"
