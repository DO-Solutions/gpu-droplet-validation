#!/usr/bin/env bash
# Run `dcgmi diag -r <level>` and translate its JSON into our result schema.
# Always emits /results/dcgm-diag_raw.json (even on parse failure) so the
# upstream artifact survives schema drift.
SUITE=dcgm-diag
source /lib/result.sh
source /lib/nvidia_models.sh

RAW=/results/dcgm-diag_raw.json
OUT=/results/dcgm-diag.json

# Start a local hostengine the dcgmi client can talk to. The DCGM container
# image ships nv-hostengine; -b binds to 127.0.0.1 to avoid leaking the API
# port outside the container.
log "starting nv-hostengine on 127.0.0.1"
nv-hostengine -b 127.0.0.1 >/tmp/nvhe.log 2>&1 || die "failed to launch nv-hostengine"

# Wait for the hostengine to accept queries. Up to ~20s; dcgmi discovery is
# the canonical readiness probe.
ready=0
for _ in $(seq 1 40); do
  if dcgmi discovery -l >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
[ "$ready" -eq 1 ] || die "nv-hostengine did not become ready"

log "running: dcgmi diag -r \"${DCGM_DIAG_TESTS}\" -p \"${DCGM_DIAG_PARAMS}\" -j"
diag_rc=0
dcgmi diag \
  -r "${DCGM_DIAG_TESTS}" \
  -p "${DCGM_DIAG_PARAMS}" \
  -j > "$RAW" 2>/tmp/diag.err || diag_rc=$?
log "dcgmi diag exit=$diag_rc"

# Translate. Defensive: parse.jq tolerates schema drift and falls back to a
# single failing test point if the structure is unrecognized.
if ! jq -f /parse.jq --arg suite "$SUITE" --argjson rc "$diag_rc" "$RAW" > "$OUT" 2>/tmp/parse.err; then
  log "parser failed: $(cat /tmp/parse.err)"
  jq -n --arg suite "$SUITE" --arg err "$(cat /tmp/parse.err)" '{
    suite: $suite,
    tests: [{
      ok: false,
      name: "dcgmi diag JSON parsed",
      diagnostic: { error: $err, raw: "/results/dcgm-diag_raw.json" }
    }]
  }' > "$OUT"
fi

log "ok (results: $OUT, raw: $RAW)"
