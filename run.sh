#!/usr/bin/env bash
# Droplet GPU validation entrypoint.
#
# Shipped inside the release tarball alongside the compose files and a
# VERSION file. Installs any missing prerequisites idempotently, runs the
# compose stack for the selected --gpu-model, and forwards TAP v14 to stdout.
#
# Contract:
#   stdout       -> TAP v14 from the tap-reporter container (only on a real run)
#   stderr       -> descriptive error message if the suite cannot run
#   results dir  -> JSON per suite, debug artifacts, metadata.json, output.tap
#                   (defaults to ./results relative to the caller's pwd,
#                   override with --results-dir)
#
# Exit codes:
#   0     suite ran and produced TAP (pass or fail — signal is in TAP stream)
#   != 0  suite could not run (stderr populated)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR=""

GPU_MODEL=""
GPU_COUNT=""
NODE_ID=""
REGION=""
RUN_ID=""

log() { printf '[run.sh] %s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: run.sh --gpu-model <model> --gpu-count <n> [--node-id <id>] [--region <r>] [--run-id <id>] [--results-dir <path>]
EOF
}

# ---------- 1. Parse flags ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu-model)   GPU_MODEL="$2";    shift 2 ;;
    --gpu-count)   GPU_COUNT="$2";    shift 2 ;;
    --node-id)     NODE_ID="$2";      shift 2 ;;
    --region)      REGION="$2";       shift 2 ;;
    --run-id)      RUN_ID="$2";       shift 2 ;;
    --results-dir) RESULTS_DIR="$2";  shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage; die "unknown flag: $1" ;;
  esac
done

[ -n "$GPU_MODEL" ] || { usage; die "--gpu-model is required"; }
[ -n "$GPU_COUNT" ] || { usage; die "--gpu-count is required"; }
[ -n "$RUN_ID" ] || RUN_ID="auto-$(date -u +%Y%m%dT%H%M%SZ)"
[ -n "$RESULTS_DIR" ] || RESULTS_DIR="$PWD/results"
# Docker bind mounts require absolute paths; resolve before creating.
case "$RESULTS_DIR" in /*) ;; *) RESULTS_DIR="$PWD/$RESULTS_DIR" ;; esac

# ---------- 2. Idempotent prerequisites ----------
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run.sh must run as root (needs to install packages and talk to Docker)"
  fi
}

APT_UPDATED=0
apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    log "apt-get update"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    APT_UPDATED=1
  fi
}

ensure_pkg() {
  local bin="$1"; shift
  if ! command -v "$bin" >/dev/null 2>&1; then
    apt_update_once
    log "installing: $*"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi
  log "installing Docker Engine + compose plugin from docker.com apt repo"
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -s /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" \
    > /etc/apt/sources.list.d/docker.list
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_docker_running() {
  if ! systemctl is-active --quiet docker; then
    log "starting docker"
    systemctl enable --now docker
  fi
}

need_root
ensure_pkg curl curl
ensure_pkg jq jq
ensure_docker
ensure_docker_running

# ---------- 3. Select compose file (sibling of this script) ----------
case "$GPU_MODEL" in
  test) COMPOSE_FILE="$SCRIPT_DIR/compose.test.yaml" ;;
  *)    die "unsupported --gpu-model value: $GPU_MODEL" ;;
esac
[ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE"

# Load pinned image version from the tarball's sibling VERSION file (if any).
# When missing (e.g. running from a checkout), compose falls back to :latest.
if [ -f "$SCRIPT_DIR/VERSION" ]; then
  VERSION="$(cat "$SCRIPT_DIR/VERSION")"
  export VERSION
  log "using VERSION=$VERSION"
else
  log "no VERSION file next to run.sh — compose will resolve images as :latest"
fi

# ---------- 4. Prepare results dir and metadata.json ----------
mkdir -p "$RESULTS_DIR"
chmod 0777 "$RESULTS_DIR"  # containers run as their own uid; simplest for a PoC.
rm -f "$RESULTS_DIR/output.tap" "$RESULTS_DIR/tap_exit"

jq -n \
  --arg gpu_model "$GPU_MODEL" \
  --arg gpu_count "$GPU_COUNT" \
  --arg node_id   "$NODE_ID" \
  --arg region    "$REGION" \
  --arg run_id    "$RUN_ID" \
  --arg version   "${VERSION:-}" \
  --arg hostname  "$(hostname)" \
  --arg kernel    "$(uname -r)" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    gpu_model:$gpu_model, gpu_count:$gpu_count, node_id:$node_id,
    region:$region, run_id:$run_id, version:$version,
    hostname:$hostname, kernel:$kernel, timestamp:$timestamp
  }' > "$RESULTS_DIR/metadata.json"

# ---------- 5. Run the compose stack ----------
# Export env the compose file consumes. RUN_ID drives in-container scenario
# dispatch for the test flow. RESULTS_DIR is the host-side bind-mount path
# (containers still see it as /results internally).
export RUN_ID GPU_MODEL GPU_COUNT NODE_ID REGION RESULTS_DIR

log "docker compose up (run-id=$RUN_ID gpu-model=$GPU_MODEL results-dir=$RESULTS_DIR compose=$COMPOSE_FILE)"
compose_rc=0
# Services are serialized via depends_on/service_completed_successfully, so
# an upstream failure already prevents downstream containers from starting
# — no need for --abort-on-container-exit (which prints a confusing
# "Aborting on container exit..." banner even on a clean run).
docker compose -f "$COMPOSE_FILE" up \
  --pull=always \
  >&2 || compose_rc=$?
# Regardless of compose_rc, remove stopped containers so repeat runs are clean.
docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true

# ---------- 6. Forward TAP to stdout ----------
# Exit-code semantics: the script exits 0 whenever the suite ran and produced
# TAP output, regardless of whether individual test points were ok or not ok.
# The pass/fail signal for individual tests lives in the TAP stream itself.
# Non-zero exit is reserved for the case where the suite could not run at all
# (prereqs / compose / image pull failure) — the caller distinguishes pass vs
# fail via TAP, and error via stderr + non-zero exit.
if [ -s "$RESULTS_DIR/output.tap" ]; then
  cat "$RESULTS_DIR/output.tap"
  exit 0
fi

# No TAP output means the suite could not run (prereqs / compose / pull failure).
echo "validation suite failed to produce TAP output (docker compose exit=$compose_rc). See Droplet logs and /results for detail." >&2
exit "${compose_rc:-1}"
