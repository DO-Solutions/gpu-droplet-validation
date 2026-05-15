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
    # DCGM plugin selection + per-plugin duration caps.
    # Why not `-r 3`:
    #   * Full `-r 3` on 8x B300 takes ~83 min — the targeted_stress and
    #     targeted_power plugins use long-mode durations (~20 min each) and
    #     nvbandwidth's full pair-wise sweep adds ~20 min.
    #   * nvbandwidth's per-pair matrix is NOT exposed via JSON in DCGM 4.5.3
    #     (only roll-up Pass/Fail) AND it passed cleanly on a real B300 box
    #     that NCCL allreduce flagged as 42% below the 810 GB/s floor — so
    #     it adds time without diagnostic value our NCCL containers don't
    #     already give us better.
    # Result: ~34 min for the DCGM phase, ~40 min full suite.
    DCGM_DIAG_TESTS="memory,diagnostic,pcie,targeted stress,targeted power"
    DCGM_DIAG_PARAMS="diagnostic.test_duration=300;targeted_stress.test_duration=600;targeted_power.test_duration=600"
    ;;
  *)
    printf '[nvidia_models] unsupported GPU_MODEL: %s\n' "$GPU_MODEL" >&2
    exit 1
    ;;
esac

export EXPECTED_GPU_MODEL_REGEX EXPECTED_MEM_MIB EXPECTED_LINKS_PER_GPU \
       EXPECTED_LINK_SPEED NCCL_ALLREDUCE_FLOOR \
       DCGM_DIAG_TESTS DCGM_DIAG_PARAMS
