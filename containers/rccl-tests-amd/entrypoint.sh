#!/usr/bin/env bash
# RCCL perf container. RCCL is AMD's NCCL; rccl-tests build the same
# *_perf binary names as nccl-tests. One image, two services selected via
# $RCCL_TEST:
#   - allreduce: all_reduce_perf
#   - alltoall : alltoall_perf
#
# Gate: best-of-3 busbw@8GB (in-place column) against a per-collective
# SKU floor from amd_models.sh ($RCCL_ALLREDUCE_FLOOR / $RCCL_ALLTOALL_FLOOR).
# Floors were calibrated across three idle 8x MI325X hosts (spread <1%);
# best-of-3 absorbs run-to-run noise. If no run yields a parseable Avg bus
# bandwidth the collective could not complete and the point fails. No
# NVLink-transport assertion (that is NVIDIA-specific).
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

# rccl-tests perf rows mirror nccl-tests exactly. Columns:
#   size count type redop root | time algbw busbw err | time algbw busbw err
#    $1   $2   $3    $4   $5     $6    $7    $8   $9    $10   $11   $12  $13
# busbw is $8 (out-of-place) / $12 (in-place). The floor gates on the
# in-place busbw at the 8 GB row (matches the NVIDIA path).
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

# Best-of-3 by average bus bandwidth. A run that exits non-zero or produces
# no Avg line simply is not selected; if none of the three yields one the
# collective could not complete and the point fails below.
best_avg=""
best_run=""
for i in 1 2 3; do
  run_file="/tmp/rccl-${SUITE}-run${i}.log"
  log "perf run $i/3 ($RCCL_TEST)"
  if ! run_rccl_perf > "$run_file" 2>&1; then
    log "perf run $i exited non-zero"
  fi
  avg="$(parse_avg_busbw "$run_file")"
  log "  avg busbw: ${avg:-<none>}"
  if [ -n "$avg" ]; then
    if [ -z "$best_avg" ] || awk -v a="$avg" -v b="$best_avg" 'BEGIN{exit !(a>b)}'; then
      best_avg="$avg"
      best_run="$run_file"
    fi
  fi
done

if [ -n "$best_run" ]; then
  cp "$best_run" "/results/${SUITE}_best.log" || true
  cp "$best_run" "/results/${SUITE}_run.log" || true
  busbw_8g="$(awk '
    /^#/ { next }
    NF >= 13 && $1 == "8589934592" { print $12; exit }
  ' "$best_run")"
  [ -n "$busbw_8g" ] || busbw_8g="0"
  per_size_all="$(parse_per_size "$best_run" | jq -s '.')"
else
  busbw_8g="0"
  per_size_all="[]"
fi
best_avg_num="${best_avg:-0}"

# Pass/fail: a usable best run AND busbw@8GB at or above the floor.
pass=true
if [ -z "$best_run" ]; then
  pass=false
  msg="RCCL $BIN_CANDIDATES produced no parseable Avg bus bandwidth in 3 runs — the collective could not complete"
elif awk -v a="$busbw_8g" -v b="$FLOOR" 'BEGIN{exit !(a < b)}'; then
  pass=false
  msg="RCCL $BIN_CANDIDATES busbw@8GB is ${busbw_8g} GB/s, below the ${FLOOR} GB/s floor (best of 3 runs)"
fi

# On failure prepend a human-readable `message` field (convention: every
# not-ok diagnostic starts with `message`). Performance fields are kept on
# pass too — useful for tracking drift over time.
diag="$(jq -n \
  --argjson busbw_8g_GBps "$busbw_8g" \
  --argjson floor "$FLOOR" \
  --argjson best_avg "$best_avg_num" \
  --argjson per_size "$per_size_all" \
  --argjson pass "$pass" \
  --arg msg "${msg:-}" '
  { busbw_8g_GBps: $busbw_8g_GBps, floor_GBps: $floor, best_avg_busbw_GBps: $best_avg, per_size_table: $per_size }
  | if $pass then . else { message: $msg } + . end')"

tests="$(jq -n --argjson pass "$pass" --argjson diag "$diag" \
  --arg name "RCCL ${BIN_CANDIDATES} busbw@8GB >= ${FLOOR} GB/s" '[
  { ok: $pass, name: $name, directive: null, diagnostic: $diag }
]')"

jq -n --arg suite "$SUITE" --argjson tests "$tests" \
  '{ suite: $suite, tests: $tests }' > "$OUT_JSON"
log "ok (busbw@8GB=${busbw_8g} floor=${FLOOR} best_avg=${best_avg:-<none>} pass=${pass})"
