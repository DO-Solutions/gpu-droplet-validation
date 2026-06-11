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

# In the compose flow /results is a bind mount, but a standalone one-off run
# (k8s/, scratch/) has no volume — ensure the dir exists so the tee to
# $RAW and the $OUT write land somewhere instead of dying with
# "No such file or directory".
mkdir -p "$(dirname "$RAW")"

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
# tee, not `> $RAW`: the run streams to *both* this container's stdout and
# $RAW. The file is what parse.sh / full validation consumes; stdout is the
# live signal for a one-off standalone run (`kubectl logs -f`). Both always
# happen — each use case just reads whichever it needs.
#
# Invoke exactly as proven on the MI325X host: `rvs -c <conf>` with NO
# `-d` flag. RVS 1.5.37 at default verbosity emits the [RESULT] stream and
# the end-of-run summary table the parser needs, and the full level-4 conf
# completes in ~5 min. (A `-d` debug level only adds [INFO] spam — at -d 3
# the mem module floods stdout into multi-GB logs and stalls for hours.)
#
# Bounded wall-clock as pure safety: a validation suite must never hang
# indefinitely. A healthy run finishes well inside the budget; if some
# action wedges on a bad host, timeout turns it into a deterministic
# `not ok` so rccl/teardown/tap still run and report. Override RVS_TIMEOUT
# if a SKU legitimately needs longer.
RVS_TIMEOUT="${RVS_TIMEOUT:-1800}"
log "running: timeout ${RVS_TIMEOUT}s rvs -c $RVS_CONF"
# tee to stdout + $RAW. PIPESTATUS[0] is timeout(1)'s exit (NOT tee's), so
# the 124/137 timeout-kill detection below and the rvs_rc handed to
# parse.sh stay exactly as before. (No `set -o pipefail`/`set -e` here, so
# tee's own rc is irrelevant — it writes to a plain file and never fails in
# practice.)
timeout --signal=TERM --kill-after=30 "$RVS_TIMEOUT" \
  rvs -c "$RVS_CONF" 2>&1 | tee "$RAW"
rvs_rc=${PIPESTATUS[0]}
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
        diagnostic: { message: "RVS exceeded its \($t)s time budget and was killed while running action \"\($stuck)\" (a healthy MI325X level-4 run completes in ~5 min).",
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
