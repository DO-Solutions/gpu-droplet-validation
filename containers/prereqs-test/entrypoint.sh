#!/usr/bin/env bash
# Mock prereqs container for the test family.
# On SCENARIO=error it exits non-zero (no /results/prereqs.json), which halts
# the rest of the compose stack via depends_on: service_completed_successfully.
# Otherwise it writes a pass-shaped result JSON.
SUITE=prereqs
source /lib/result.sh

case "${SCENARIO:-}" in
  error)
    die "mock environment failure (SCENARIO=$SCENARIO RUN_ID=${RUN_ID:-<unset>})"
    ;;
esac

write_result_json prereqs /results/prereqs.json '{
  suite: $suite,
  tests: [
    { ok: true, name: "nvidia-smi responds (mock)",              diagnostic: null },
    { ok: true, name: "nvidia-fabricmanager running (mock)",     diagnostic: null },
    { ok: true, name: "docker NVIDIA runtime configured (mock)", diagnostic: null }
  ]
}'

log "ok (SCENARIO=${SCENARIO:-<unset>} RUN_ID=${RUN_ID:-<unset>})"
