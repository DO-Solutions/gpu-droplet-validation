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
# a SKU arm may override it before RVS_CONF is derived. Env-overridable so
# a one-off standalone run can select another level (e.g. RVS_LEVEL=5 for
# the long soak); the official run.sh/compose flow never sets it, so it
# stays 4 there.
RVS_LEVEL="${RVS_LEVEL:-4}"

case "$GPU_MODEL" in
  amd-mi325x)
    # Matched case-insensitively against amd-smi GPU name. The run log shows
    # "AMD Instinct Mi325X VF" on the VF/fabric host.
    EXPECTED_GPU_MODEL_REGEX="MI325X"
    # Enforced expected per-GPU VRAM (amd-smi static --vram size.value).
    EXPECTED_VRAM_MIB=261824
    # RCCL busbw@8GB floors (GB/s), best-of-3, in-place column. Calibrated
    # 2026-05-16 across three idle 8x MI325X VF hosts (147.182.158.107,
    # 146.190.255.172, 143.198.32.60): allreduce min-best 318.26, alltoall
    # min-best 301.67, run-to-run + cross-node spread <1%. Floors sit ~5-6%
    # below the min best run — clears noise on a healthy idle host while
    # catching a meaningfully degraded GPU/fabric.
    RCCL_ALLREDUCE_FLOOR=300
    RCCL_ALLTOALL_FLOOR=285
    ;;
  amd-mi350x)
    # MI350X (CDNA4, gfx950). Matched against the VF VBIOS name "AMD MI350X".
    EXPECTED_GPU_MODEL_REGEX="MI350X"
    # amd-smi static --vram size.value on the MI350X VF host (288 GB HBM3E).
    EXPECTED_VRAM_MIB=294592
    # RCCL busbw@8GB floors (GB/s), best-of-3, in-place column. Calibrated
    # 2026-05-30 on an idle 8x MI350X VF host (206.189.78.90,
    # jkeegan-sfo2-mi350x, ROCm 7.0.2): allreduce min-best 393.39, alltoall
    # min-best 349.10, run-to-run spread <0.2%. Floors sit ~5.5-6% below the
    # min best run, matching the MI325X margin. NOTE: single-host calibration
    # (the MI325X floors spanned three hosts) — run-to-run noise is covered
    # but cross-node spread is not yet measured; revisit if a second MI350X
    # host reads materially lower. MI350X is ~24%/16% faster than MI325X on
    # allreduce/alltoall, as expected from its higher Infinity Fabric BW —
    # AMD's published 304 GB/s acceptance number is the MI325X figure and does
    # not reflect MI350X.
    RCCL_ALLREDUCE_FLOOR=370
    RCCL_ALLTOALL_FLOOR=330
    ;;
  # RVS-one-off-only SKUs. These arms exist solely so the rvs entrypoint can
  # resolve RVS_CONF for a standalone, manual run (e.g. an examples/ pod at
  # level 5 on an MI300X node) — they are NOT calibrated for the full
  # run.sh/compose validation flow. EXPECTED_VRAM_MIB=0 disables the prereqs
  # VRAM gate, and no RCCL_*_FLOOR is set on purpose: a full flow on these
  # SKUs still fails fast at rccl-tests-amd (unset floor). amd-mi325x and
  # amd-mi350x above are the fully-calibrated validation SKUs.
  amd-mi300x) EXPECTED_GPU_MODEL_REGEX="MI300X"; EXPECTED_VRAM_MIB=0 ;;
  amd-mi355x) EXPECTED_GPU_MODEL_REGEX="MI355X"; EXPECTED_VRAM_MIB=0 ;;
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
