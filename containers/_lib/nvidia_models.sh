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
    #
    # Per-plugin wall-clock, measured 2026-05-15 on 8x B300 SXM6 AC
    # (driver 590.48.01, DCGM 4.5.3-1), each plugin run in isolation:
    #   software         ~30 s   (deployment check, always on)
    #   diagnostic        ~5 min  (capped: diagnostic.test_duration=300)
    #   memory            ~3 min  (187 s — exhaustive HBM walk, no duration knob)
    #   pcie             ~47 min  (2799 s — P2P bw/latency sweep, no duration knob)
    #   targeted_stress  ~10 min  (capped: targeted_stress.test_duration=600)
    #   targeted_power   ~10 min  (capped: targeted_power.test_duration=600)
    #
    # `pcie` alone is ~47 min and dominates everything else combined. We drop
    # it: the NCCL allreduce busbw floor + the NVLink-transport assertion in
    # the nccl-tests container exercise the GPU<->GPU fabric with the real
    # collective workload, which is strictly better signal than DCGM's
    # synthetic P2P sweep (same argument we use for not running nvbandwidth,
    # whose per-pair matrix DCGM 4.5.3 doesn't even expose in JSON).
    #
    # `memory` is kept — it's only ~3 min and is the one plugin that does an
    # exhaustive HBM allocate-and-walk, the most likely test to surface a
    # marginal HBM cell that the stress plugins miss.
    #
    # Result with pcie dropped: DCGM phase ~29 min, full suite ~36 min
    # (was ~77 min / ~84 min with pcie). Earlier "~34 min" claims were
    # measured against a list without pcie that never matched what shipped.
    DCGM_DIAG_TESTS="memory,diagnostic,targeted stress,targeted power"
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
