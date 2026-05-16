#!/usr/bin/env bash
# Run RVS (ROCmValidationSuite) with the vendored per-SKU conf and translate
# its text log into our result schema. Always preserves /results/rvs.log
# (like dcgm-diag_raw.json) so the upstream artifact survives parser drift.
#
# RVS replaces `dcgmi diag` for the amd-* family: the vendored level-4 conf
# runs babel(HBM), pebb(PCIe), pbqt(xGMI), mem, gst(compute) and iet(power).
# RVS does no collective comms — that is rccl-tests downstream.
SUITE=rvs
source /lib/result.sh
source /lib/amd_models.sh

RAW=/results/rvs.log
OUT=/results/rvs.json

# Fail fast with an actionable message if this SKU has no vendored conf.
# RVS_CONF is derived from $GPU_MODEL in amd_models.sh, and the entire conf
# tree is baked into this image — a miss here means the SKU arm was added
# without dropping in containers/rvs/conf/$GPU_MODEL/.
if [ ! -f "$RVS_CONF" ]; then
  die "no vendored RVS conf for $GPU_MODEL at $RVS_CONF — add containers/rvs/conf/$GPU_MODEL/rvs_level_${RVS_LEVEL}.conf"
fi

# Capture RVS *stdout* (NOT `-l <file>`): the end-of-run summary table the
# parser keys on is printed to stdout, while `-l` writes only the structured
# [RESULT] stream (no table). stdout carries the per-action [RESULT] pass
# lines and the final summary table — exactly what parse.sh needs.
#
# Debug level: -d 1 (NOT -d 3). The [RESULT] stream and the summary table
# are emitted at every debug level, but RVS 3.x's mem module at -d 3 floods
# stdout with per-block [INFO] lines ("Test2 on reading: 128/128 blocks")
# — observed to produce a >2 GB log and stall the run for hours on the
# 8x256 GB MI325X. -d 1 keeps results+table and runs in minutes.
# Bounded wall-clock: a validation suite must never hang indefinitely. RVS
# can hang forever on a host where an action can't make progress — observed
# on SR-IOV VF boxes where the xGMI peer test (pqt/xgmi_d2d_bandwidth) has
# no peer access and never returns (a 30 s test ran >45 min). timeout turns
# that into a deterministic `not ok` so rccl/teardown/tap still run and
# report. Generous default (covers a healthy full level-4 run); override
# with RVS_TIMEOUT if a SKU legitimately needs longer.
RVS_TIMEOUT="${RVS_TIMEOUT:-1800}"
log "running: timeout ${RVS_TIMEOUT}s rvs -c $RVS_CONF -d 1"
rvs_rc=0
timeout --signal=TERM --kill-after=30 "$RVS_TIMEOUT" \
  rvs -c "$RVS_CONF" -d 1 > "$RAW" 2>&1 || rvs_rc=$?
log "rvs exit=$rvs_rc"

# timeout(1) exits 124 (TERM) or 137 (128+KILL) when it had to kill rvs.
if [ "$rvs_rc" -eq 124 ] || [ "$rvs_rc" -eq 137 ]; then
  stuck="$(grep -aE 'Action name :' "$RAW" 2>/dev/null | tail -1 \
            | sed -E 's/.*Action name :[[:space:]]*//' | tr -d '\r' || true)"
  log "rvs exceeded ${RVS_TIMEOUT}s and was killed (stuck action: ${stuck:-unknown})"
  jq -n --arg suite "$SUITE" --arg stuck "${stuck:-unknown}" --argjson t "$RVS_TIMEOUT" '{
    suite: $suite,
    tests: [
      { ok: false, name: "rvs completed within its time budget", directive: null,
        diagnostic: { message: "RVS exceeded its \($t)s time budget and was killed (last action started: \"\($stuck)\"). On SR-IOV VF hosts the xGMI peer test (pqt) has no peer access and hangs.",
                      timeout_seconds: $t, hung_action: $stuck, raw: "/results/rvs.log" } },
      { ok: false, name: "rvs produced a summary table", directive: null,
        diagnostic: { message: "no RVS summary table — the run was killed on timeout before it could complete", raw: "/results/rvs.log" } }
    ]
  }' > "$OUT"
  log "ok (timeout path; results: $OUT, raw: $RAW)"
  exit 0
fi

if ! /parse.sh "$RAW" "$rvs_rc" > "$OUT" 2>/tmp/parse.err; then
  log "parser failed: $(cat /tmp/parse.err)"
  jq -n --arg suite "$SUITE" --arg err "$(cat /tmp/parse.err)" '{
    suite: $suite,
    tests: [{
      ok: false,
      name: "rvs log parsed",
      directive: null,
      diagnostic: {
        message: "rvs parser (parse.sh) failed on the raw rvs log",
        error: $err,
        raw: "/results/rvs.log"
      }
    }]
  }' > "$OUT"
fi

log "ok (results: $OUT, raw: $RAW)"
