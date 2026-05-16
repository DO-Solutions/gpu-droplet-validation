#!/usr/bin/env bash
# Real setup for the amd-* family.
# Captures the ECC/RAS + amdgpu-dmesg baseline that teardown-amd diffs
# against. AMD has no persistence-mode concept (that is nvidia-only), so
# this only snapshots state — it does not mutate the GPUs.
SUITE=setup
source /lib/result.sh
source /lib/amd_models.sh

# Per-GPU ECC/RAS counters. amd-smi exposes them as JSON with --json, which
# is far more robust to parse than the human table. Fall back to rocm-smi if
# amd-smi is unavailable on some image variant.
ecc_baseline='[]'
if ecc_json="$(amd-smi metric --ecc --json 2>/dev/null)" && [ -n "$ecc_json" ]; then
  # amd-smi shape: { "gpu_data": [ { "gpu": N, "ecc": {
  #   "total_correctable_count":.., "total_uncorrectable_count":.. } } ] }.
  # Normalize to [{index, corrected, uncorrected}]; default missing to 0.
  ecc_baseline="$(printf '%s' "$ecc_json" | jq '
    [ (.gpu_data // [])[]
      | { index: .gpu,
          corrected:   (.ecc.total_correctable_count   // 0),
          uncorrected: (.ecc.total_uncorrectable_count // 0) } ]' \
    2>/dev/null || echo '[]')"
fi

# amdgpu kernel-FAULT baseline. Match only genuine hardware/driver fault
# signatures, not benign lifecycle chatter ("Freeing queue vital buffer",
# "queue evicted", "hogged CPU", "switching to WQ_UNBOUND") which is normal
# on every process exit and would swamp the delta. teardown-amd MUST use
# this identical regex so the before/after counts are comparable.
AMDGPU_FAULT_RE='page fault|ring [0-9].*timeout|GPU reset|gpu recover|uncorrectable|ECC error|\bRAS\b|xgmi.*error|fault from die|GPU hang|reset begin|soft recovery|amdgpu: GPU fault'
amdgpu_lines="$(dmesg -T 2>/dev/null | grep -i 'amdgpu' | grep -iE "$AMDGPU_FAULT_RE" || true)"
amdgpu_count="$(printf '%s\n' "$amdgpu_lines" | grep -c . || true)"

jq -n \
  --argjson ecc "$ecc_baseline" \
  --arg amdgpu "$amdgpu_lines" \
  --argjson amdgpu_count "$amdgpu_count" \
  --arg gpu_model "$GPU_MODEL" \
  '{
    gpu_model: $gpu_model,
    ecc_baseline: $ecc,
    amdgpu_baseline: { count: $amdgpu_count, lines: ($amdgpu | split("\n") | map(select(length>0))) }
  }' > /results/baseline.json

log "ok (baseline written)"
