# Prebuilt base image carrying a compiled ROCm Validation Suite + the full
# ROCm runtime + amd-smi. Built once and pushed by
# scripts/build-rvs-base.sh; the per-release rvs/prereqs-amd/setup-amd/
# teardown-amd images all FROM this so the slow RVS compile happens rarely.
#
# No AMD GPU is required to BUILD this — compiling RVS only needs the ROCm
# SDK + headers. A GPU is only needed at test runtime.
#
# RVS_REF is pinned to the EXACT commit of RVS 1.5.37
# (git describe: v1.5.0-37-g44c0022b) — the version proven on the MI325X
# host: it runs the vendored MI325X level-4 conf in ~5 min, all PASS
# (incl. xGMI/PBQT and IET), and emits the end-of-run summary table the
# parser keys on. This is also the version of the vendored scratch sample.
# Do NOT use `develop` (RVS 3.x) — it dropped pbqt, hangs on the xGMI
# (pqt) action on SR-IOV VF hosts, and floods stdout from the mem module.
ARG ROCM_VERSION=7.0.2-complete
ARG RVS_REF=44c0022bbb8f14d060c0a11f36abbeee49b85d04

# ---------- builder: compile RVS against the ROCm SDK ----------
FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION} AS builder
ARG RVS_REF
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git cmake make g++ pkg-config ca-certificates \
      libpci-dev libyaml-cpp-dev \
      rocblas hipblaslt amd-smi-lib \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# Full clone (NOT --depth 1) then checkout the pinned commit: RVS derives
# its version from `git describe` against the tags, so the history/tags
# must be present (a shallow clone yields a bogus version fallback).
RUN git clone https://github.com/ROCm/ROCmValidationSuite.git rvs \
 && git -C rvs checkout "${RVS_REF}"
WORKDIR /src/rvs

# RVS's CMake assumes the *legacy* ROCm directory layout (HIP_INC_DIR
# /opt/rocm/hip, hipcc at hip/bin, ancient libhip_hcc.so, rocm_smi under
# /opt/rocm/rocm_smi, bare rocblas.h in /opt/rocm/include). ROCm 7.x ships
# none of those paths; recreate the legacy tree with symlinks so every
# module configures and builds. Safe: the base image has none of these
# paths, so nothing is clobbered.
RUN ln -sfn /opt/rocm /opt/rocm/hip \
 && ln -sfn /opt/rocm /opt/rocm/rocm_smi \
 && ln -sf  libamdhip64.so /opt/rocm/lib/libhip_hcc.so \
 && ln -sf  rocblas/rocblas.h     /opt/rocm/include/rocblas.h \
 && ln -sf  rocblas/internal      /opt/rocm/include/internal \
 && ln -sf  hipblaslt/hipblaslt.h /opt/rocm/include/hipblaslt.h

# edp is not used by the mi325x level-4 conf and has historically shipped
# with a broken POST_BUILD; drop it if present (no-op if absent).
RUN sed -i '/add_subdirectory(edp.so)/d' /src/rvs/CMakeLists.txt

# -DGPU_TARGETS="gfx942;gfx950": both Instinct archs this base serves.
# gfx942 = CDNA3 (MI300X / MI325X — the full-validation SKU); gfx950 =
# CDNA4 (MI350X / MI355X — RVS one-off only). RVS 1.5.x uses the modern
# GPU_TARGETS cache var (confirmed from the host's working CMakeCache);
# without the matching arch the babel/mem/gst HIP kernels have no code
# object and every compute/memory action dies at runtime with "invalid
# device function". Keep both arches built so one rvs-base serves every
# AMD SKU (mi325x flow is unaffected — gfx942 still present).
# -DRVS_BUILD_TESTS=OFF: skip the bundled googletest (not needed for the
# `rvs` runtime; old gtest fails under the image GCC).
# CPATH: belt-and-braces include fallback alongside the header symlinks.
ENV CPATH=/opt/rocm/include/rocblas:/opt/rocm/include/hipblaslt:/opt/rocm/include
RUN cmake -B build \
      -DROCM_PATH=/opt/rocm \
      -DCMAKE_INSTALL_PREFIX=/opt/rocm \
      -DCPACK_PACKAGING_INSTALL_PREFIX=/opt/rocm \
      -DGPU_TARGETS="gfx942;gfx950" \
      -DRVS_BUILD_TESTS=OFF \
 && make -C build -j"$(nproc)" \
 && (cd build && make package)

# ---------- runtime: ROCm runtime + the built RVS .deb ----------
FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION} AS runtime
ENV DEBIAN_FRONTEND=noninteractive
COPY --from=builder /src/rvs/build/rocm-validation-suite*.deb /tmp/rvs.deb
# Install the locally-built .deb via apt (not `dpkg -i`) so apt resolves the
# package's declared dependencies automatically — the RVS .deb depends on
# libyaml-cpp-dev / libpci-dev, which `dpkg -i` would not pull.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      rocblas hipblaslt amd-smi-lib ca-certificates \
      /tmp/rvs.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/rvs.deb
# RVS 1.5.x installs the binary at /opt/rocm/bin/rvs and its module .so's
# under /opt/rocm/lib/rvs/ (libpbqt/libgst/libbabel/...). rvs resolves
# modules via its installed .rvsmodules.config; keep both on PATH/loader
# path so the binary runs and the modules link at runtime.
ENV PATH=/opt/rocm/bin:${PATH}
ENV LD_LIBRARY_PATH=/opt/rocm/lib/rvs:/opt/rocm/lib:${LD_LIBRARY_PATH}
# Sanity: `rvs --version` needs no GPU. Build fails loudly if RVS is broken.
RUN rvs --version
