#!/usr/bin/env bash
# NCCL perf container. One image, two services selected via $NCCL_TEST:
#   - allreduce: topology/debug capture + mean-of-3 perf, SKU-floor on busbw@8GB,
#     NVLink transport assertion. Raw output of all 3 perf runs is saved to
#     /results/<suite>_run{1,2,3}.log so the upstream nccl-tests tables survive.
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

parse_avg_busbw() {
  awk -F: '/Avg bus bandwidth/ { gsub(/ /,"",$2); print $2; exit }' "$1"
}

# busbw@8GB from the in-place busbw column ($12) of a single run log. This is
# the value the SKU floor gates on.
parse_busbw_8g() {
  awk '/^#/ { next } NF >= 13 && $1 == "8589934592" { print $12; exit }' "$1"
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

  # 2. Perf: mean-of-3 on busbw@8GB. Averaging the gated metric (rather than
  #    gating on the best of 3 runs) means a single low run drags the value down
  #    instead of being masked by the two good runs — an intermittently-degraded
  #    host is caught, not hidden. We average busbw@8GB directly rather than
  #    picking a run by its across-size average and then reading that run's 8 GB
  #    row, so the metric we select on and the metric we gate on are the same.
  # Save the raw output of every run to /results unconditionally — including runs
  # that exit non-zero or produce no 8 GB row, since those are the interesting
  # failures. People read the actual nccl-tests tables rather than a synthetic
  # summary (matches dcgm-diag_raw.json / rvs.log: the upstream artifact survives).
  run_busbws=()   # busbw@8GB per run that produced an 8 GB row — the gated samples
  for i in 1 2 3; do
    run_file="/results/${SUITE}_run${i}.log"
    log "perf run $i/3"
    if ! run_nccl_perf > "$run_file" 2>&1; then
      log "perf run $i exited non-zero"
    fi
    b8="$(parse_busbw_8g "$run_file")"
    avg="$(parse_avg_busbw "$run_file")"
    log "  busbw@8GB: ${b8:-<none>}  avg busbw: ${avg:-<none>}"
    [ -n "$b8" ] && run_busbws+=("$b8")
  done
  # 3. Mean busbw@8GB across the runs that produced an 8 GB row — the gated value.
  # No usable run at all is a test failure, not an environment failure: it is
  # what a host with an uninitialized NVSwitch fabric looks like (every run
  # dies with 'system not yet initialized'). Record it as a not-ok point and
  # exit 0 so alltoall, teardown and tap-reporter still run and the caller
  # gets TAP naming the failure — this used to `die`, which halted the stack
  # on service_completed_successfully and left run.sh with nothing to report
  # but "failed to produce TAP output". Mirrors rccl-tests-amd.
  if [ "${#run_busbws[@]}" -gt 0 ]; then
    busbw_8g="$(printf '%s\n' "${run_busbws[@]}" | awk '{ s += $1; n++ } END { printf "%.2f", (n ? s / n : 0) }')"
    # -c: the array is interpolated into the failure message below, and a
    # pretty-printed one would drop newlines into a single-line TAP diagnostic.
    per_run_busbw="$(printf '%s\n' "${run_busbws[@]}" | jq -sc '.')"
  else
    busbw_8g="0"
    per_run_busbw="[]"
  fi

  # 4. NVLink transport check from the debug log.
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

  # Floor pass/fail point. Pass needs at least one usable run AND a mean at or
  # above the floor.
  pass_floor=true
  floor_msg=""
  if [ "${#run_busbws[@]}" -eq 0 ]; then
    pass_floor=false
    floor_msg="NCCL allreduce produced no parseable busbw@8GB in 3 runs — the collective could not complete"
  elif awk -v a="$busbw_8g" -v b="$NCCL_ALLREDUCE_FLOOR" 'BEGIN{exit !(a < b)}'; then
    pass_floor=false
    floor_msg="NCCL allreduce mean busbw@8GB is $busbw_8g GB/s (per run: $per_run_busbw), below the $NCCL_ALLREDUCE_FLOOR GB/s floor"
  fi

  # On failure prepend a human-readable message (convention: every not-ok
  # diagnostic starts with a `message` field). The performance fields are
  # preserved on pass too, since they're useful even when the floor was met.
  diag_floor="$(jq -n \
    --argjson mean_busbw_8g_GBps "$busbw_8g" \
    --argjson floor "$NCCL_ALLREDUCE_FLOOR" \
    --argjson per_run "$per_run_busbw" \
    --argjson pass_floor "$pass_floor" \
    --arg msg "$floor_msg" \
    '{ mean_busbw_8g_GBps: $mean_busbw_8g_GBps, floor_GBps: $floor, per_run_busbw_8g_GBps: $per_run }
     | if $pass_floor then . else { message: $msg } + . end')"

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
  # Prepend a human-readable message when the test failed (convention: every
  # not-ok diagnostic starts with a `message` field).
  if [ "$nvl_ok" = "false" ]; then
    diag_nvl_extra="$(echo "$diag_nvl_extra" | jq '{ message: "NCCL did not use full direct-P2P NVLink + NVLS multicast across all ranks — transport regression suspected" } + .')"
  fi

  tests="$(jq -n \
    --argjson pass_floor "$pass_floor" \
    --argjson nvl_ok "$nvl_ok" \
    --argjson diag_floor "$diag_floor" \
    --argjson diag_nvl_extra "$diag_nvl_extra" \
    --arg floor_name "NCCL allreduce mean busbw@8GB >= $NCCL_ALLREDUCE_FLOOR GB/s" '
    [
      { ok: $pass_floor, name: $floor_name,  diagnostic: $diag_floor },
      { ok: $nvl_ok,     name: "NCCL transport is NVLink (no PIX/SYS/PHB)", diagnostic: ($diag_nvl_extra | if (. | length)==0 then null else . end) }
    ]')"

  emit_tests_json "$OUT_JSON" "$tests"
  log "ok (mean busbw@8GB=$busbw_8g floor=$NCCL_ALLREDUCE_FLOOR per_run=$per_run_busbw pass=$pass_floor)"

else
  # alltoall: single perf run, pass = exit 0 (no SKU floor per plan).
  run_file="/tmp/nccl-${SUITE}.log"
  rc=0
  log "perf run (alltoall)"
  run_nccl_perf > "$run_file" 2>&1 || rc=$?
  cp "$run_file" "/results/${SUITE}_run.log" || true

  avg="$(parse_avg_busbw "$run_file")"

  pass=true
  [ "$rc" -eq 0 ] || pass=false

  # On failure prepend a human-readable `message` field (convention).
  diag="$(jq -n --arg avg "${avg:-}" --argjson rc "$rc" --argjson pass "$pass" '
    { exit_code: $rc, avg_busbw_GBps: $avg }
    | if $pass then . else { message: "NCCL alltoall_perf exited with code \($rc) — the collective could not complete" } + . end')"

  tests="$(jq -n --argjson pass "$pass" --argjson diag "$diag" '[
    { ok: $pass, name: "NCCL alltoall_perf exit code == 0", diagnostic: $diag }
  ]')"
  emit_tests_json "$OUT_JSON" "$tests"
  log "ok (exit=$rc)"
fi
