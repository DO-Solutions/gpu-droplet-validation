#!/usr/bin/env bash
# Build every container + package every family's tarball under a single
# version tag, then publish to ghcr.io + GitHub Releases.
#
# One release == all artifacts in lockstep. No per-family partial releases.
#
# Usage:
#   scripts/release.sh                 # auto version: v1.YYYYMMDD.HHMMSS
#   scripts/release.sh --version vX    # explicit version
#   scripts/release.sh --dry-run       # print what would happen, no push/tag
#
# Prereqs:
#   - gh CLI authenticated against github.com (gh auth status)
#   - docker + buildx
#   - GITHUB_TOKEN (or gh token) with write:packages for ghcr.io login
#   - run from the repo root
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="ghcr.io/do-solutions/gpu-droplet-validation"
GH_OWNER="DO-Solutions"
GH_REPO="gpu-droplet-validation"
GH_SLUG="$GH_OWNER/$GH_REPO"

# image name (under $REGISTRY) -> build-context dockerfile path
# Keep tap-reporter flat (vendor-agnostic); everything else <family>-<role>.
IMAGES=(
  "tap-reporter:containers/tap-reporter/Dockerfile"
  "prereqs-test:containers/prereqs-test/Dockerfile"
  "setup-test:containers/setup-test/Dockerfile"
  "mock-test:containers/mock-test/Dockerfile"
  "teardown-test:containers/teardown-test/Dockerfile"
  "prereqs-nvidia:containers/prereqs-nvidia/Dockerfile"
  "setup-nvidia:containers/setup-nvidia/Dockerfile"
  "dcgm-diag:containers/dcgm-diag/Dockerfile"
  "nccl-tests-nvidia:containers/nccl-tests-nvidia/Dockerfile"
  "teardown-nvidia:containers/teardown-nvidia/Dockerfile"
  # amd-* family. NOTE: rvs-base and rccl-tests base images are deliberately
  # NOT here — they are slow to build and published out-of-band by
  # scripts/build-rvs-base.sh / scripts/build-rccl-tests-base.sh, not per
  # release. compose.amd.yaml is auto-picked up by the compose.*.yaml glob.
  "prereqs-amd:containers/prereqs-amd/Dockerfile"
  "setup-amd:containers/setup-amd/Dockerfile"
  "rvs:containers/rvs/Dockerfile"
  "rccl-tests-amd:containers/rccl-tests-amd/Dockerfile"
  "teardown-amd:containers/teardown-amd/Dockerfile"
)

VERSION=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '1,30p' "$0" >&2
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$VERSION" ]; then
  VERSION="v1.$(date -u +%Y%m%d.%H%M%S)"
fi

log() { printf '[release] %s\n' "$*" >&2; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*" >&2
  else
    eval "$@"
  fi
}

log "version: $VERSION"
log "dry-run: $DRY_RUN"

# ---------- 1. Auth checks ----------
if [ "$DRY_RUN" -eq 0 ]; then
  gh auth status >/dev/null || { echo "gh not authenticated" >&2; exit 1; }

  : "${GITHUB_TOKEN:=$(gh auth token)}"
  export GITHUB_TOKEN
  GH_USER="$(gh api user -q .login)"
  log "docker login ghcr.io as $GH_USER"
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GH_USER" --password-stdin >/dev/null
fi

# ---------- 2. Build + push every image ----------
for spec in "${IMAGES[@]}"; do
  name="${spec%%:*}"
  dockerfile="${spec#*:}"
  ref_ver="$REGISTRY/$name:$VERSION"
  ref_lat="$REGISTRY/$name:latest"
  log "build+push: $name ($dockerfile) -> $ref_ver + :latest"
  run "docker buildx build \
    --platform linux/amd64 \
    -f '$dockerfile' \
    -t '$ref_ver' \
    -t '$ref_lat' \
    --push \
    '$REPO_ROOT'"
done

# ---------- 3. Package unified tarball ----------
DIST_DIR="$REPO_ROOT/dist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

shopt -s nullglob
compose_files=( "$REPO_ROOT"/compose.*.yaml )
shopt -u nullglob
[ "${#compose_files[@]}" -gt 0 ] || { echo "no compose.*.yaml files found at repo root" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp "$REPO_ROOT/run.sh" "$staging/run.sh"
for compose in "${compose_files[@]}"; do
  cp "$compose" "$staging/$(basename "$compose")"
done
printf '%s\n' "$VERSION" > "$staging/VERSION"
chmod +x "$staging/run.sh"

# k8s path ships alongside compose in the SAME tarball: the wrapper, the Helm
# chart, and the same VERSION file the wrapper reads to pin image.version.
# Compose staging above is unchanged.
cp "$REPO_ROOT/scripts/run-k8s.sh" "$staging/run-k8s.sh"
chmod +x "$staging/run-k8s.sh"
cp -r "$REPO_ROOT/deploy/helm/gpu-droplet-validation" "$staging/helm"
# Pin the packaged chart's image version to this release (checkout dev stays
# 'latest'); run-k8s.sh's sibling VERSION file is the authoritative override.
sed -i -E "s|^(  version: ).*$|\1$VERSION|" "$staging/helm/values.yaml"

versioned_tarball="$DIST_DIR/gpu-droplet-validation-$VERSION.tgz"
latest_tarball="$DIST_DIR/gpu-droplet-validation-latest.tgz"

# Optional standalone Helm chart artifact (for `helm install` straight from a
# release asset). Skipped if helm is unavailable on the release host.
chart_pkg=""
if command -v helm >/dev/null 2>&1; then
  helm package "$staging/helm" --destination "$DIST_DIR" \
    --app-version "$VERSION" >&2 || true
  chart_pkg="$(ls -1 "$DIST_DIR"/gpu-droplet-validation-*.tgz 2>/dev/null \
    | grep -v "gpu-droplet-validation-$VERSION.tgz" \
    | grep -v 'gpu-droplet-validation-latest.tgz' | head -n1 || true)"
  [ -n "$chart_pkg" ] && log "helm chart packaged: $chart_pkg"
else
  log "helm not found — skipping standalone chart artifact (chart still ships inside the tarball)"
fi

log "pack: $versioned_tarball (compose files: ${#compose_files[@]})"
# --owner=0 --group=0 --numeric-owner: force every entry (including the
# leading "./") to record root ownership in the archive. Without this, the
# build host's UID/GID (e.g. 1000) leaks into the tarball and chown's the
# extraction dir to that UID when the user extracts as root.
tar --owner=0 --group=0 --numeric-owner \
  -czf "$versioned_tarball" -C "$staging" .
cp "$versioned_tarball" "$latest_tarball"
rm -rf "$staging"
trap - EXIT

log "dist contents:"
ls -la "$DIST_DIR" >&2

# ---------- 4. Immutable versioned release ----------
log "gh release create $VERSION"
run "gh release create '$VERSION' \
  --repo '$GH_SLUG' \
  --title '$VERSION' \
  --notes 'Automated release $VERSION — all containers and the unified tarball built together.' \
  '$versioned_tarball' ${chart_pkg:+\"$chart_pkg\"}"

# ---------- 5. Rolling 'latest' release ----------
# GitHub does not allow re-uploading assets to an existing release under the
# same name without --clobber, and the latest tag itself needs to move. The
# simplest durable pattern is to delete+recreate the 'latest' release each
# time.
log "refreshing 'latest' release"
run "gh release delete latest --repo '$GH_SLUG' --cleanup-tag -y || true"
run "gh release create latest \
  --repo '$GH_SLUG' \
  --title 'latest' \
  --notes 'Rolling latest ($VERSION). Prefer versioned releases for pinning.' \
  '$latest_tarball' ${chart_pkg:+\"$chart_pkg\"}"

log "done: $VERSION"
