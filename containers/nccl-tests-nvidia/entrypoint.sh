#!/usr/bin/env bash
# NCCL perf container. One image, two services selected via $NCCL_TEST:
#   - allreduce: topology/debug capture + best-of-3 perf, SKU-floor on busbw@8GB,
#     per-size table, NVLink transport assertion.
#   - alltoall : single perf run; exit 0 alone is the pass signal (per plan).
#
# Both runs capture concurrent `nvidia-smi dmon` to /results/<name>_dmon.log.
# SUITE drives both the result-file basename and the in-TAP suite label.
# tap-reporter's SUITE_FILES expects nccl-allreduce.json / nccl-alltoall.json,
# so the suite name must match — not the bare NCCL_TEST value.
SUITE="nccl-${NCCL_TEST:-unknown}"
source /lib/result.sh
source /lib/nvidia_models.sh

: "${GPU_COUNT:?GPU_COUNT is not set}"
: "${NCCL_TEST:?NCCL_TEST must be allreduce or alltoall}"

case "$NCCL_TEST" in
  allreduce) BIN_CANDIDATES="all_reduce_perf" ;;
  alltoall)  BIN_CANDIDATES="alltoall_perf"   ;;
  *) die "unsupported NCCL_TEST: $NCCL_TEST" ;;
esac

# Find the binary. nccl-tests images vary on layout; check common paths.
find_bin() {
  local b="$1"
  if command -v "$b" >/dev/null 2>&1; then command -v "$b"; return 0; fi
  local p
  for p in /workspace/nccl-tests/build/$b /opt/nccl-tests/build/$b /usr/local/bin/$b /usr/bin/$b; do
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
DEBUG_LOG="/results/${SUITE}_debug.log"

# Start dmon for the run window. Sample SM/util/mem/power every 1s.
nvidia-smi dmon -s pucvmet -d 1 -o T > "$DMON_LOG" 2>/dev/null &
DMON_PID=$!
# shellcheck disable=SC2064
trap "kill $DMON_PID 2>/dev/null || true" EXIT

run_nccl_perf() {
  # Returns stdout of the perf run; caller redirects.
  "$BIN" -b 32K -e 8G -f 2 -g "$GPU_COUNT" -w 5 -n 20
}

# Extract per-size busbw rows. nccl-tests perf output rows start with size in
# bytes. Columns: size count type redop root time algbw busbw err  time algbw busbw err
# (the second triplet is "in-place"). We use the in-place busbw (column 11).
parse_per_size() {
  awk '
    /^#/ { next }
    NF >= 12 && $1 ~ /^[0-9]+$/ {
      printf "{\"size\":%s,\"busbw_oop\":%s,\"busbw_ip\":%s}\n", $1, $8, $11
    }
  ' "$1"
}

parse_avg_busbw() {
  awk -F: '/Avg bus bandwidth/ { gsub(/ /,"",$2); print $2; exit }' "$1"
}

emit_tests_json() {
  local jsonpath="$1"; shift
  jq -n --arg suite "$SUITE" --argjson tests "$1" '{ suite: $suite, tests: $tests }' > "$jsonpath"
}

if [ "$NCCL_TEST" = "allreduce" ]; then
  # 1. Debug capture: small-message run with NCCL_DEBUG=INFO to log topology
  #    and transport (NVL vs PIX/SYS/PHB).
  log "debug capture (1G, NCCL_DEBUG=INFO)"
  NCCL_DEBUG=INFO "$BIN" -b 1G -e 1G -n 1 -g "$GPU_COUNT" \
    > "$DEBUG_LOG" 2>&1 || true

  # 2. Perf: best-of-3 by average bus bandwidth.
  best_avg=""
  best_run=""
  for i in 1 2 3; do
    run_file="/tmp/nccl-${SUITE}-run${i}.log"
    log "perf run $i/3"
    if ! run_nccl_perf > "$run_file" 2>&1; then
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
  [ -n "$best_run" ] || die "no NCCL perf run produced an Avg bus bandwidth line"

  cp "$best_run" "/results/${SUITE}_best.log"

  # 3. Extract busbw@8GB from the best run's in-place column.
  busbw_8g="$(awk '
    /^#/ { next }
    NF >= 12 && $1 == "8589934592" { print $11; exit }
  ' "$best_run")"
  [ -n "$busbw_8g" ] || busbw_8g="0"

  # 4. Per-size table (8 MB / 64 MB / 1 GB / 8 GB).
  per_size_all="$(parse_per_size "$best_run" | jq -s '.')"
  per_size_table="$(echo "$per_size_all" | jq '[ .[] | select(.size==8388608 or .size==67108864 or .size==1073741824 or .size==8589934592) ]')"

  # 5. NVLink transport check from the debug log.
  # NCCL 2.29 dropped the legacy "via NVL/PIX/SYS/PHB" annotations. Instead the
  # healthy-NVLink debug log shows two signals:
  #   - "Check P2P Type isAllDirectP2p 1 directMode 1 isAllCudaP2p 1" once per
  #     rank, indicating every GPU has direct P2P to every other GPU. A "0" in
  #     either isAllDirectP2p or isAllCudaP2p means P2P fell back.
  #   - "NVLS multicast support is available on dev N" once per dev when the
  #     NVLink Switch is usable.
  # We also look for explicit fallback signatures NCCL emits when P2P fails,
  # because those would invalidate the busbw numbers above.
  direct_lines="$(grep "isAllDirectP2p" "$DEBUG_LOG" 2>/dev/null || true)"
  direct_count="$(printf '%s\n' "$direct_lines" | grep -c "isAllDirectP2p 1 directMode 1 isAllCudaP2p 1" || true)"
  not_direct="$(printf '%s\n' "$direct_lines" | grep -E "isAllDirectP2p 0|isAllCudaP2p 0" || true)"
  nvls_count="$(grep -c "NVLS multicast support is available on dev" "$DEBUG_LOG" 2>/dev/null || true)"
  fallback_lines="$(grep -E "Falling back to|Cannot use P2P|cannot enable peer access|disabling P2P" "$DEBUG_LOG" 2>/dev/null || true)"

  # Floor pass/fail point.
  pass_floor=true
  if awk -v a="$busbw_8g" -v b="$NCCL_ALLREDUCE_FLOOR" 'BEGIN{exit !(a < b)}'; then
    pass_floor=false
  fi

  diag_floor="$(jq -n \
    --argjson busbw_8g_GBps "$busbw_8g" \
    --argjson floor "$NCCL_ALLREDUCE_FLOOR" \
    --argjson best_avg "${best_avg:-0}" \
    --argjson per_size "$per_size_table" \
    '{ busbw_8g_GBps: $busbw_8g_GBps, floor_GBps: $floor, best_avg_busbw_GBps: $best_avg, per_size_table: $per_size }')"

  # NVLink transport pass/fail point.
  # Pass requires: every rank reports full direct P2P, the NVLS multicast
  # signal appears at least once per GPU (count == GPU_COUNT), and there
  # are no fallback / "Cannot use P2P" lines.
  nvl_ok=true
  diag_nvl_extra="{}"
  if [ -n "$not_direct" ]; then
    nvl_ok=false
    diag_nvl_extra="$(echo "$diag_nvl_extra" | jq --arg lines "$not_direct" '. + { not_all_direct_p2p: $lines }')"
  fi
  if [ "$direct_count" -lt "$GPU_COUNT" ]; then
    nvl_ok=false
    diag_nvl_extra="$(echo "$diag_nvl_extra" | jq --argjson got "$direct_count" --argjson want "$GPU_COUNT" '. + { direct_p2p_ranks_seen: $got, expected: $want }')"
  fi
  if [ "$nvls_count" -lt "$GPU_COUNT" ]; then
    nvl_ok=false
    diag_nvl_extra="$(echo "$diag_nvl_extra" | jq --argjson got "$nvls_count" --argjson want "$GPU_COUNT" '. + { nvls_multicast_dev_count: $got, expected: $want }')"
  fi
  if [ -n "$fallback_lines" ]; then
    nvl_ok=false
    diag_nvl_extra="$(echo "$diag_nvl_extra" | jq --arg lines "$fallback_lines" '. + { transport_fallback: $lines }')"
  fi

  tests="$(jq -n \
    --argjson pass_floor "$pass_floor" \
    --argjson nvl_ok "$nvl_ok" \
    --argjson diag_floor "$diag_floor" \
    --argjson diag_nvl_extra "$diag_nvl_extra" \
    --arg floor_name "NCCL allreduce busbw@8GB >= $NCCL_ALLREDUCE_FLOOR GB/s" '
    [
      { ok: $pass_floor, name: $floor_name,  diagnostic: $diag_floor },
      { ok: $nvl_ok,     name: "NCCL transport is NVLink (no PIX/SYS/PHB)", diagnostic: ($diag_nvl_extra | if (. | length)==0 then null else . end) }
    ]')"

  emit_tests_json "$OUT_JSON" "$tests"
  log "ok (busbw@8GB=$busbw_8g floor=$NCCL_ALLREDUCE_FLOOR)"

else
  # alltoall: single perf run, pass = exit 0 (no SKU floor per plan).
  run_file="/tmp/nccl-${SUITE}.log"
  rc=0
  log "perf run (alltoall)"
  run_nccl_perf > "$run_file" 2>&1 || rc=$?
  cp "$run_file" "/results/${SUITE}_run.log" || true

  per_size_all="$(parse_per_size "$run_file" | jq -s '.')"
  avg="$(parse_avg_busbw "$run_file")"
  diag="$(jq -n --arg avg "${avg:-}" --argjson per_size "$per_size_all" --argjson rc "$rc" '
    { exit_code: $rc, avg_busbw_GBps: $avg, per_size_table: $per_size }')"

  pass=true
  [ "$rc" -eq 0 ] || pass=false

  tests="$(jq -n --argjson pass "$pass" --argjson diag "$diag" '[
    { ok: $pass, name: "NCCL alltoall_perf exit code == 0", diagnostic: $diag }
  ]')"
  emit_tests_json "$OUT_JSON" "$tests"
  log "ok (exit=$rc)"
fi
