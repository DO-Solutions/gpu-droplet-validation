#!/usr/bin/env bash
# Per-SKU thresholds for the nvidia-* family.
# Sourced from every nvidia-* container entrypoint after /lib/result.sh.
# Reads $GPU_MODEL (exported by run.sh) and exports the threshold variables
# the entrypoints consume. Unknown SKUs cause prereqs to halt the stack.
#
# Adding a new SKU = adding one case arm here. No compose/image changes.

: "${GPU_MODEL:?GPU_MODEL is not set; run.sh must export it}"

case "$GPU_MODEL" in
  nvidia-b300)
    EXPECTED_GPU_MODEL_REGEX="B300"
    EXPECTED_MEM_MIB=275040
    EXPECTED_LINKS_PER_GPU=18
    EXPECTED_LINK_SPEED="53.125 GB/s"
    NCCL_ALLREDUCE_FLOOR=810
    DCGM_DIAG_LEVEL=3
    ;;
  *)
    printf '[nvidia_models] unsupported GPU_MODEL: %s\n' "$GPU_MODEL" >&2
    exit 1
    ;;
esac

export EXPECTED_GPU_MODEL_REGEX EXPECTED_MEM_MIB EXPECTED_LINKS_PER_GPU \
       EXPECTED_LINK_SPEED NCCL_ALLREDUCE_FLOOR DCGM_DIAG_LEVEL
