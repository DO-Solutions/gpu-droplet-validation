#!/usr/bin/env bash
# Mock setup container for --gpu-model test.
# No GPU interaction; writes a placeholder baseline so the artifact shape
# matches the real suite.
SUITE=setup
source /lib/result.sh

jq -n '{
  ecc_baseline: {},
  xid_baseline: [],
  mock: true
}' > /results/baseline.json

log "ok (baseline written)"
