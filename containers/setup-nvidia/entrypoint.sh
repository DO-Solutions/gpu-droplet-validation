#!/usr/bin/env bash
# Real setup for the nvidia-* family.
# - Captures ECC + Xid baselines used by teardown to compute deltas.
# - Enables persistence mode (nvidia-smi -pm 1). No clock locking.
SUITE=setup
source /lib/result.sh
source /lib/nvidia_models.sh

# Persistence mode keeps the driver loaded across nvidia-smi invocations and
# reduces first-CUDA-call latency. Idempotent.
if ! nvidia-smi -pm 1 >/tmp/pm.log 2>&1; then
  cat /tmp/pm.log >&2
  die "failed to enable persistence mode"
fi

# ECC baseline: per-GPU corrected/uncorrected volatile counters.
# Output is a JSON array indexed by GPU.
ecc_baseline="$(nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total \
  --format=csv,noheader,nounits 2>/dev/null \
  | awk -F',' 'BEGIN{print "["} NR>1{print ","} {gsub(/ /,""); printf "{\"index\":%s,\"corrected\":%s,\"uncorrected\":%s}", $1, $2, $3} END{print "]"}')"

# Xid baseline: any current Xid lines in dmesg (count + the lines themselves).
xid_lines="$(dmesg -T 2>/dev/null | grep -i 'NVRM: Xid' || true)"
xid_count="$(printf '%s\n' "$xid_lines" | grep -c . || true)"

jq -n \
  --argjson ecc "$ecc_baseline" \
  --arg xid "$xid_lines" \
  --argjson xid_count "$xid_count" \
  --arg gpu_model "$GPU_MODEL" \
  '{
    gpu_model: $gpu_model,
    persistence_mode: true,
    ecc_baseline: $ecc,
    xid_baseline: { count: $xid_count, lines: ($xid | split("\n") | map(select(length>0))) }
  }' > /results/baseline.json

log "ok (persistence on, baseline written)"
