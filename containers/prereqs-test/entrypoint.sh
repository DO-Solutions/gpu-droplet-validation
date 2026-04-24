#!/usr/bin/env bash
# Mock prereqs container for --gpu-model test.
# On RUN_ID=error-* it exits non-zero (no /results/prereqs.json), which halts
# the rest of the compose stack via depends_on: service_completed_successfully.
# Otherwise it writes a pass-shaped result JSON.
SUITE=prereqs
source /lib/result.sh

case "${RUN_ID:-}" in
  error-*)
    die "mock environment failure (RUN_ID=$RUN_ID)"
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

log "ok (RUN_ID=${RUN_ID:-<unset>})"
