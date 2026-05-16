# Prebuilt base image carrying compiled rccl-tests (AMD's nccl-tests
# equivalent) on top of the ROCm runtime. Built once and pushed by
# scripts/build-rccl-tests-base.sh; containers/rccl-tests-amd FROMs it so
# the perf binaries are not recompiled per release (mirrors the external
# nccl-tests base-image pattern used by nccl-tests-nvidia).
#
# No AMD GPU is required to build — only the ROCm SDK + RCCL.
ARG ROCM_VERSION=7.0.2-complete
ARG RCCL_TESTS_BRANCH=develop

FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION} AS builder
ARG RCCL_TESTS_BRANCH
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git cmake make g++ ca-certificates \
      rccl rccl-dev libopenmpi-dev openmpi-bin \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 --branch "${RCCL_TESTS_BRANCH}" \
      https://github.com/ROCm/rccl-tests.git
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
