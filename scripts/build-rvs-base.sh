#!/usr/bin/env bash
# Build & push the prebuilt rvs-base image:
#   ghcr.io/do-solutions/rvs-base:rocm<ROCM_VER>
#
# OUT-OF-BAND and INFREQUENT. The RVS binary is slow to compile, so it is
# baked into this base image once and the per-release amd-* images just
# FROM it. This is NOT run by scripts/release.sh — run it only when the
# pinned ROCm version changes or RVS itself needs a bump.
#
# No AMD GPU is required to build this — compiling RVS only needs the ROCm
# SDK. Runs anywhere with Docker + buildx (CI, laptop, any build host); it
# is NOT tied to the GPU test host.
#
# Pin ROCM_VER to the target droplet's ROCm. The MI325X run log shows
# ROCm 7.0.2 / amdgpu 6.14.14; RVS links rocBLAS/hipBLASLt so the image
# ROCm must be <= the host-driver-supported level. The ROCm version is
# baked into the published tag.
#
# Usage:
#   scripts/build-rvs-base.sh                 # defaults below
#   scripts/build-rvs-base.sh --dry-run
#   ROCM_VER=7.0.2 scripts/build-rvs-base.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Pinned versions. ROCM_VER drives both the rocm/dev-ubuntu base tag and the
# published rvs-base tag; RVS_REF is the exact RVS commit to compile.
ROCM_VER="${ROCM_VER:-7.0.2}"
ROCM_IMAGE_TAG="${ROCM_IMAGE_TAG:-${ROCM_VER}-complete}"
# Pinned to RVS 1.5.37 (git describe v1.5.0-37-g44c0022b), the version
# proven on the MI325X host: runs the vendored level-4 conf in ~5 min, all
# PASS (incl. xGMI/PBQT + IET), emits the summary table the parser needs.
# NOT `develop` (RVS 3.x: dropped pbqt, hangs on pqt on VF hosts) and NOT
# the rocm-${ROCM_VER} tag (old 1.2.0, no summary table).
RVS_REF="${RVS_REF:-44c0022bbb8f14d060c0a11f36abbeee49b85d04}"
IMAGE="ghcr.io/do-solutions/rvs-base:rocm${ROCM_VER}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { printf '[build-rvs-base] %s\n' "$*" >&2; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] %s\n' "$*" >&2; else eval "$@"; fi
}

log "image:       $IMAGE"
log "rocm tag:    rocm/dev-ubuntu-24.04:${ROCM_IMAGE_TAG}"
log "rvs ref:     ${RVS_REF}"
log "dry-run:     $DRY_RUN"

run "docker buildx build \
  --platform linux/amd64 \
  -f 'containers/rvs-base/Dockerfile' \
  --build-arg ROCM_VERSION='${ROCM_IMAGE_TAG}' \
  --build-arg RVS_REF='${RVS_REF}' \
  -t '${IMAGE}' \
  --push \
  '${REPO_ROOT}'"

# `rvs --version` needs no GPU and the Dockerfile already runs it at build
# time; re-verify the pushed image here as a publish gate.
run "docker run --rm '${IMAGE}' rvs --version"
log "done: ${IMAGE}"
