# Prebuilt base image carrying a compiled ROCm Validation Suite + the full
# ROCm runtime + amd-smi. Built once and pushed by
# scripts/build-rvs-base.sh; the per-release rvs/prereqs-amd/setup-amd/
# teardown-amd images all FROM this so the slow RVS compile happens rarely.
#
# No AMD GPU is required to BUILD this — compiling RVS only needs the ROCm
# SDK + headers. A GPU is only needed at test runtime.
#
# ROCM_VERSION is the rocm/dev-ubuntu image tag (e.g. "7.0.2-complete") and
# RVS_BRANCH is the ROCmValidationSuite release branch matching that ROCm
# (e.g. "rocm-7.0.2"). Both are passed by scripts/build-rvs-base.sh.
# RVS_BRANCH must be a ref whose RVS emits the end-of-run summary table
# (the parser's source of truth). That is an RVS >= ~1.5 feature: the
# ROCm-release tags (e.g. rocm-7.0.2) ship the OLD 1.2.0-era RVS which has
# NO summary table, so `develop` is used instead (RVS 1.5.x — matches the
# vendored scratch sample, version 1.5.37, which runs fine on ROCm 7.0.2).
ARG ROCM_VERSION=7.0.2-complete
ARG RVS_BRANCH=develop

# ---------- builder: compile RVS against the ROCm SDK ----------
FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION} AS builder
ARG RVS_BRANCH
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git cmake make g++ pkg-config ca-certificates \
      libpci-dev libyaml-cpp-dev \
      rocblas hipblaslt amd-smi-lib \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# Full clone (NOT --depth 1): RVS derives its version from `git describe`
# against the latest tag, so a shallow clone yields a bogus 1.2.0 fallback.
RUN git clone --branch "${RVS_BRANCH}" \
      https://github.com/ROCm/ROCmValidationSuite.git rvs
WORKDIR /src/rvs
# RVS develop's CMake hardcodes the *legacy* ROCm directory layout through
# non-cache set()s that -D cannot override, and per-module CMake silently
# RETURN()s a module out of the build (no error, just missing .so at
# runtime: "could not load .so '.../libbabel.so'") when a path is wrong:
#   - set(HIP_INC_DIR /opt/rocm/hip)        (babel) + hipcc at hip/bin/hipcc
#   - HIP_HCC_LIB "hip_hcc"  -> wants /opt/rocm/lib/libhip_hcc.so
#       (ancient name; modern HIP runtime is libamdhip64.so)
#   - ROCM_SMI_{INC,LIB}_DIR = /opt/rocm/rocm_smi/{include,lib}
#   - ROCBLAS_INC_DIR = /opt/rocm/include  -> wants bare rocblas.h there
# ROCm 7.x ships none of those paths. Recreate the legacy tree with
# symlinks so EVERY module (babel/gst/iet/mem/pbqt/pebb/...) configures and
# builds. These are safe: the base image has no /opt/rocm/{hip,rocm_smi},
# no /opt/rocm/include/{internal,rocblas.h,hipblaslt.h}, no libhip_hcc.so.
RUN ln -sfn /opt/rocm /opt/rocm/hip \
 && ln -sfn /opt/rocm /opt/rocm/rocm_smi \
 && ln -sf  libamdhip64.so /opt/rocm/lib/libhip_hcc.so \
 && ln -sf  rocblas/rocblas.h     /opt/rocm/include/rocblas.h \
 && ln -sf  rocblas/internal      /opt/rocm/include/internal \
 && ln -sf  hipblaslt/hipblaslt.h /opt/rocm/include/hipblaslt.h

# Drop the `edp` module: develop ships it broken (its POST_BUILD does
# `cd .../edp.so/rocm_edp_helper` but that dir is absent from the tree and
# it is NOT a git submodule, so the build dies at ~97%). There is no CMake
# toggle for it, and the mi325x level-4 conf does not use edp — excise its
# add_subdirectory so the build completes with every module we actually run.
RUN sed -i '/add_subdirectory(edp.so)/d' /src/rvs/CMakeLists.txt

# RVS's HIP modules (babel/gst/iet/mem) hardcode HCC_CXX_FLAGS with
# --amdgpu-target=gfx803/gfx900/gfx906/gfx908 only. The MI325X is gfx942
# (CDNA3, MI300/MI325), so without it the kernels have NO matching code
# object and every compute/memory action dies at runtime with
# "Error: invalid device function" (rvs exits 98, no summary table).
# Append gfx942 to every module's target list before configuring.
RUN grep -rl 'amdgpu-target=gfx908' /src/rvs --include=CMakeLists.txt \
    | xargs -r sed -i 's/--amdgpu-target=gfx908/--amdgpu-target=gfx908 --amdgpu-target=gfx942/g'

# -DRVS_BUILD_TESTS=OFF: skip RVS's bundled googletest (not needed for the
# `rvs` runtime; the vendored old gtest fails under the image GCC with
# -Werror=maybe-uninitialized in gtest-death-test.cc).
# CPATH (honored by gcc and the clang-based hipcc) is a belt-and-braces
# include fallback alongside the rocblas/hipblaslt header symlinks above.
ENV CPATH=/opt/rocm/include/rocblas:/opt/rocm/include/hipblaslt:/opt/rocm/include
RUN cmake -B build \
      -DROCM_PATH=/opt/rocm \
      -DCMAKE_INSTALL_PREFIX=/opt/rocm \
      -DCPACK_PACKAGING_INSTALL_PREFIX=/opt/rocm \
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
# RVS 3.x (develop) installs the binary + its module .so's under
# /opt/rocm/rvs/ (NOT /opt/rocm/bin). Put that on PATH and the loader path
# so `rvs` runs and finds libpebb/libgpup/... at runtime.
ENV PATH=/opt/rocm/rvs:/opt/rocm/bin:${PATH}
ENV LD_LIBRARY_PATH=/opt/rocm/rvs:/opt/rocm/lib:${LD_LIBRARY_PATH}
# Sanity: `rvs --version` needs no GPU. Build fails loudly if RVS is broken.
RUN rvs --version
