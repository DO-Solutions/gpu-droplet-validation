#!/usr/bin/env bash
# Per-SKU thresholds for the amd-* family.
# Sourced from every amd-* container entrypoint after /lib/result.sh.
# Reads $GPU_MODEL (exported by run.sh) and exports the threshold variables
# the entrypoints consume. Unknown SKUs cause prereqs to halt the stack.
#
# Adding a new AMD SKU is a purely additive change: add one case arm here
# plus drop in one vendored conf at
# containers/rvs/conf/<gpu-model>/rvs_level_<N>.conf. No compose/image
# changes — the same five AMD containers serve every AMD SKU.

: "${GPU_MODEL:?GPU_MODEL is not set; run.sh must export it}"

# Level of the vendored RVS conf to run. Shared default across AMD SKUs;
# a SKU arm may override it before RVS_CONF is derived.
RVS_LEVEL=4

case "$GPU_MODEL" in
  amd-mi325x)
    # Matched case-insensitively against amd-smi GPU name. The run log shows
    # "AMD Instinct Mi325X VF" on the VF/fabric host.
    EXPECTED_GPU_MODEL_REGEX="MI325X"
    # Calibration TODO: derive from amd-smi on a known-good host. Until then
    # prereqs records VRAM but does not fail on it (VF reporting differs and
    # would false-negative). 0 = "not yet calibrated; treat as informational".
    EXPECTED_VRAM_MIB=0
    # RCCL busbw@8GB floors (GB/s), best-of-3, in-place column. Calibrated
    # 2026-05-16 across three idle 8x MI325X VF hosts (147.182.158.107,
    # 146.190.255.172, 143.198.32.60): allreduce min-best 318.26, alltoall
    # min-best 301.67, run-to-run + cross-node spread <1%. Floors sit ~5-6%
    # below the min best run — clears noise on a healthy idle host while
    # catching a meaningfully degraded GPU/fabric.
    RCCL_ALLREDUCE_FLOOR=300
    RCCL_ALLTOALL_FLOOR=285
    ;;
  # Future SKUs are a pure additive change — add an arm here and a vendored
  # containers/rvs/conf/<gpu-model>/rvs_level_4.conf. e.g.:
  #   amd-mi350x) EXPECTED_GPU_MODEL_REGEX="MI350X"; EXPECTED_VRAM_MIB=0 ;;
  #   amd-mi355x) EXPECTED_GPU_MODEL_REGEX="MI355X"; EXPECTED_VRAM_MIB=0 ;;
  *)
    printf '[amd_models] unsupported GPU_MODEL: %s\n' "$GPU_MODEL" >&2
    exit 1
    ;;
esac

# Conf path is derived from $GPU_MODEL so no per-SKU path is ever hardcoded;
# the directory name == the --gpu-model value. The rvs container ships the
# entire vendored conf tree, so this resolves inside the image with no
# dependency on any external ROCm clone at runtime.
RVS_CONF="/rvs/conf/${GPU_MODEL}/rvs_level_${RVS_LEVEL}.conf"

export EXPECTED_GPU_MODEL_REGEX EXPECTED_VRAM_MIB RVS_LEVEL RVS_CONF \
       RCCL_ALLREDUCE_FLOOR RCCL_ALLTOALL_FLOOR
