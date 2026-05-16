#!/usr/bin/env bash
# Build & push the prebuilt rccl-tests base image:
#   ghcr.io/do-solutions/rccl-tests:rocm<ROCM_VER>
#
# OUT-OF-BAND and INFREQUENT — mirrors the external nccl-tests base-image
# pattern. NOT run by scripts/release.sh; run only when the pinned
# ROCm/RCCL versions change. No AMD GPU required to build.
#
# Pinned versions (keep in sync with the target droplet's ROCm — MI325X
# run log: ROCm 7.0.2 / amdgpu 6.14.14):
#   ROCM_VER          7.0.2   (rocm/dev-ubuntu-24.04:<ROCM_VER>-complete)
#   RCCL_TESTS_BRANCH develop (ROCm/rccl-tests; pin to a tag once one tracks
#                              the target ROCm)
# The ROCm version is baked into the published tag.
#
# Usage:
#   scripts/build-rccl-tests-base.sh
#   scripts/build-rccl-tests-base.sh --dry-run
#   ROCM_VER=7.0.2 RCCL_TESTS_BRANCH=develop scripts/build-rccl-tests-base.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ROCM_VER="${ROCM_VER:-7.0.2}"
ROCM_IMAGE_TAG="${ROCM_IMAGE_TAG:-${ROCM_VER}-complete}"
RCCL_TESTS_BRANCH="${RCCL_TESTS_BRANCH:-develop}"
IMAGE="ghcr.io/do-solutions/rccl-tests:rocm${ROCM_VER}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { printf '[build-rccl-tests-base] %s\n' "$*" >&2; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] %s\n' "$*" >&2; else eval "$@"; fi
}

log "image:       $IMAGE"
log "rocm tag:    rocm/dev-ubuntu-24.04:${ROCM_IMAGE_TAG}"
log "rccl-tests:  ${RCCL_TESTS_BRANCH}"
log "dry-run:     $DRY_RUN"

run "docker buildx build \
  --platform linux/amd64 \
  -f 'containers/rccl-tests-base/Dockerfile' \
  --build-arg ROCM_VERSION='${ROCM_IMAGE_TAG}' \
  --build-arg RCCL_TESTS_BRANCH='${RCCL_TESTS_BRANCH}' \
  -t '${IMAGE}' \
  --push \
  '${REPO_ROOT}'"

run "docker run --rm '${IMAGE}' sh -c 'ls -1 /rccl-tests/build/all_reduce_perf /rccl-tests/build/alltoall_perf'"
log "done: ${IMAGE}"
