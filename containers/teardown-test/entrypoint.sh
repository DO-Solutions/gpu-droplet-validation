#!/usr/bin/env bash
# Mock teardown container for --gpu-model test.
# Writes post-health.json with entries that the tap-reporter turns into a
# subtest. Shape matches the real teardown output (ECC/Xid deltas, thermal,
# row remap) so the TAP structure is representative.
SUITE=teardown
source /lib/result.sh

write_result_json post-health /results/post-health.json '{
  suite: $suite,
  tests: [
    { ok: true, name: "No new correctable ECC errors (mock)",   diagnostic: null },
    { ok: true, name: "No new uncorrectable ECC errors (mock)", diagnostic: null },
    { ok: true, name: "No new Xid errors in dmesg (mock)",      diagnostic: null },
    { ok: true, name: "No thermal throttling observed (mock)",  diagnostic: null },
    { ok: true, name: "Row remap status clean (mock)",          diagnostic: null }
  ]
}'

log "ok (post-health written)"
