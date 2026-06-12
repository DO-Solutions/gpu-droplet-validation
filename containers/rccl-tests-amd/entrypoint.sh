#!/usr/bin/env bash
# RCCL perf container. RCCL is AMD's NCCL; rccl-tests build the same
# *_perf binary names as nccl-tests. One image, two services selected via
# $RCCL_TEST:
#   - allreduce: all_reduce_perf
#   - alltoall : alltoall_perf
#
# Gate: mean-of-3 busbw@8GB (in-place column) against a per-collective
# SKU floor from amd_models.sh ($RCCL_ALLREDUCE_FLOOR / $RCCL_ALLTOALL_FLOOR).
# Floors were calibrated across three idle 8x MI325X hosts (spread <1%) and sit
# ~5-6% below the min healthy run, so averaging (rather than best-of-3) still
# clears on a healthy host but a single low run drags the mean below the floor
# instead of being masked. If no run yields a busbw@8GB row the collective could
# not complete and the point fails. No NVLink-transport assertion (NVIDIA-only).
# Raw output of all 3 perf runs is saved to /results/<suite>_run{1,2,3}.log so
# the upstream rccl-tests tables survive (matches dcgm-diag_raw.json / rvs.log).
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
  allreduce) BIN_CANDIDATES="all_reduce_perf"; FLOOR="${RCCL_ALLREDUCE_FLOOR:-}" ;;
  alltoall)  BIN_CANDIDATES="alltoall_perf";   FLOOR="${RCCL_ALLTOALL_FLOOR:-}"  ;;
  *) die "unsupported RCCL_TEST: $RCCL_TEST" ;;
esac
: "${FLOOR:?no RCCL busbw floor for $RCCL_TEST — check amd_models.sh}"

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
log "binary: $BIN (floor: ${FLOOR} GB/s busbw@8GB)"

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

parse_avg_busbw() {
  awk -F: '/Avg bus bandwidth/ { gsub(/ /,"",$2); print $2; exit }' "$1"
}
# busbw@8GB from the in-place busbw column ($12) of a single run log — the value
# the SKU floor gates on.
parse_busbw_8g() {
  awk '/^#/ { next } NF >= 13 && $1 == "8589934592" { print $12; exit }' "$1"
}

# Mean-of-3 on busbw@8GB. A run that exits non-zero or produces no 8 GB row
# simply contributes no sample; if none of the three do, the collective could
# not complete and the point fails below. Averaging the gated metric (rather
# than gating on the best of 3) keeps a single low run from being masked.
# Save the raw output of every run to /results unconditionally — including runs
# that exit non-zero or produce no 8 GB row, since those are the interesting
# failures. People read the actual rccl-tests tables rather than a synthetic
# summary (matches dcgm-diag_raw.json / rvs.log: the upstream artifact survives).
run_busbws=()   # busbw@8GB per run that produced an 8 GB row — the gated samples
for i in 1 2 3; do
  run_file="/results/${SUITE}_run${i}.log"
  log "perf run $i/3 ($RCCL_TEST)"
  if ! run_rccl_perf > "$run_file" 2>&1; then
    log "perf run $i exited non-zero"
  fi
  b8="$(parse_busbw_8g "$run_file")"
  avg="$(parse_avg_busbw "$run_file")"
  log "  busbw@8GB: ${b8:-<none>}  avg busbw: ${avg:-<none>}"
  [ -n "$b8" ] && run_busbws+=("$b8")
done

if [ "${#run_busbws[@]}" -gt 0 ]; then
  busbw_8g="$(printf '%s\n' "${run_busbws[@]}" | awk '{ s += $1; n++ } END { printf "%.2f", (n ? s / n : 0) }')"
  per_run_busbw="$(printf '%s\n' "${run_busbws[@]}" | jq -s '.')"
else
  busbw_8g="0"
  per_run_busbw="[]"
fi

# Pass/fail: at least one usable run AND mean busbw@8GB at or above the floor.
pass=true
if [ "${#run_busbws[@]}" -eq 0 ]; then
  pass=false
  msg="RCCL $BIN_CANDIDATES produced no parseable busbw@8GB in 3 runs — the collective could not complete"
elif awk -v a="$busbw_8g" -v b="$FLOOR" 'BEGIN{exit !(a < b)}'; then
  pass=false
  msg="RCCL $BIN_CANDIDATES mean busbw@8GB is ${busbw_8g} GB/s (per run: ${per_run_busbw}), below the ${FLOOR} GB/s floor (mean of 3 runs)"
fi

# On failure prepend a human-readable `message` field (convention: every
# not-ok diagnostic starts with `message`). Performance fields are kept on
# pass too — useful for tracking drift over time.
diag="$(jq -n \
  --argjson mean_busbw_8g_GBps "$busbw_8g" \
  --argjson floor "$FLOOR" \
  --argjson per_run "$per_run_busbw" \
  --argjson pass "$pass" \
  --arg msg "${msg:-}" '
  { mean_busbw_8g_GBps: $mean_busbw_8g_GBps, floor_GBps: $floor, per_run_busbw_8g_GBps: $per_run }
  | if $pass then . else { message: $msg } + . end')"

tests="$(jq -n --argjson pass "$pass" --argjson diag "$diag" \
  --arg name "RCCL ${BIN_CANDIDATES} mean busbw@8GB >= ${FLOOR} GB/s" '[
  { ok: $pass, name: $name, directive: null, diagnostic: $diag }
]')"

jq -n --arg suite "$SUITE" --argjson tests "$tests" \
  '{ suite: $suite, tests: $tests }' > "$OUT_JSON"
log "ok (mean busbw@8GB=${busbw_8g} floor=${FLOOR} per_run=${per_run_busbw} pass=${pass})"
