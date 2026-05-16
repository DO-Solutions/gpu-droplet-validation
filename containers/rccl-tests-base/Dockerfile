# Prebuilt base image carrying compiled rccl-tests (AMD's nccl-tests
# equivalent) on top of the ROCm runtime. Built once and pushed by
# scripts/build-rccl-tests-base.sh; containers/rccl-tests-amd FROMs it so
# the perf binaries are not recompiled per release (mirrors the external
# nccl-tests base-image pattern used by nccl-tests-nvidia).
#
# No AMD GPU is required to build — only the ROCm SDK + RCCL.
# RCCL_TESTS_REF is pinned to an exact commit, not a branch. ROCm/rccl-tests
# migrated its default branch: the old stable line is now `develop_deprecated`
# and the new `develop` HEAD faults with a GPU memory access fault on
# gfx942/MI325X. 40b1b17 (develop_deprecated, "Migration complete", describes
# as therock-7.11-2-g40b1b17) is the build proven on MI325X bare-metal and
# in-container. Bump only after validating a newer ref on real MI325X hardware.
ARG ROCM_VERSION=7.0.2-complete
ARG RCCL_TESTS_REF=40b1b17901370a7880d4a56854b5361c89f8d324

FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION} AS builder
ARG RCCL_TESTS_REF
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git cmake make g++ ca-certificates \
      rccl rccl-dev libopenmpi-dev openmpi-bin \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# Fetch the exact commit (GitHub serves arbitrary SHAs to `git fetch`), so the
# pin is immune to branch renames/force-pushes upstream.
RUN git init rccl-tests \
 && cd rccl-tests \
 && git remote add origin https://github.com/ROCm/rccl-tests.git \
 && git fetch --depth 1 origin "${RCCL_TESTS_REF}" \
 && git checkout --detach FETCH_HEAD
WORKDIR /src/rccl-tests
RUN make MPI=1 MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
         HIP_HOME=/opt/rocm RCCL_HOME=/opt/rocm -j"$(nproc)"

FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION} AS runtime
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      rccl libopenmpi3 openmpi-bin ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/rccl-tests/build /rccl-tests/build
ENV PATH=/rccl-tests/build:/opt/rocm/bin:${PATH}
