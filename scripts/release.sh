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

versioned_tarball="$DIST_DIR/gpu-droplet-validation-$VERSION.tgz"
latest_tarball="$DIST_DIR/gpu-droplet-validation-latest.tgz"

log "pack: $versioned_tarball (compose files: ${#compose_files[@]})"
tar czf "$versioned_tarball" -C "$staging" .
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
  '$versioned_tarball'"

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
  '$latest_tarball'"

log "done: $VERSION"
