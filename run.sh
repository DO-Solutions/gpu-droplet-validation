#!/usr/bin/env bash
# Droplet GPU validation entrypoint.
#
# Shipped inside the release tarball alongside the compose files and a
# VERSION file. Installs any missing prerequisites idempotently, runs the
# compose stack for the selected --gpu-model, and forwards TAP v14 to stdout.
#
# Contract:
#   stdout       -> TAP v14 from the tap-reporter container (only on a real run)
#   stderr       -> a single error line iff the suite could not run at all
#   results dir  -> JSON per suite, debug artifacts, metadata.json, output.tap,
#                   run.log (all script + compose diagnostics)
#                   (defaults to ./results relative to the caller's pwd,
#                   override with --results-dir)
#
# Exit codes:
#   0    suite ran and all TAP test points were ok
#   1    suite ran and at least one TAP test point was not ok
#   255  suite could not run (prereqs / compose / pull failure, bad flags)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR=""
LOG_FILE=""

GPU_MODEL=""
GPU_COUNT=""
NODE_ID=""
REGION=""
RUN_ID=""

# log() appends to $LOG_FILE once it's set up; before that (during flag
# parsing) it falls back to stderr so usage/die output still surfaces.
log() {
  if [ -n "$LOG_FILE" ]; then
    printf '[run.sh] %s\n' "$*" >> "$LOG_FILE"
  else
    printf '[run.sh] %s\n' "$*" >&2
  fi
}
die() { printf '%s\n' "$*" >&2; exit 255; }

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

# Validate --gpu-model before creating any state on disk so a bad flag
# doesn't leave behind a stray results dir.
#
# The test family ships three gpu-model values (test-pass / test-fail /
# test-error) so callers like auto-ahoy can pick a scenario by passing a
# literal flag value — no run-id-prefix parsing required. SCENARIO is
# derived here and exported below for the container stack to dispatch on.
SCENARIO=""
case "$GPU_MODEL" in
  test-pass)  COMPOSE_FILE="$SCRIPT_DIR/compose.test.yaml"; SCENARIO="pass" ;;
  test-fail)  COMPOSE_FILE="$SCRIPT_DIR/compose.test.yaml"; SCENARIO="fail" ;;
  test-error) COMPOSE_FILE="$SCRIPT_DIR/compose.test.yaml"; SCENARIO="error" ;;
  *)          die "unsupported --gpu-model value: $GPU_MODEL" ;;
esac
[ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE"

# Create the results dir up front so $LOG_FILE exists before any log() call
# fires (apt installs, docker setup, etc.). Containers in the compose stack
# all run as root, so 0755 is sufficient — no need for world-writable.
mkdir -p "$RESULTS_DIR"
chmod 0755 "$RESULTS_DIR"
LOG_FILE="$RESULTS_DIR/run.log"
: > "$LOG_FILE"
rm -f "$RESULTS_DIR/output.tap" "$RESULTS_DIR/tap_exit"

# ---------- 2. Idempotent prerequisites ----------
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run.sh must run as root (needs to install packages and talk to Docker)"
  fi
}

# Suppress needrestart's "Restarting services..." chatter that some Ubuntu
# images print from dpkg postinst hooks; without this it leaks past -qq.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

APT_UPDATED=0
apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    log "apt-get update"
    apt-get update -qq >>"$LOG_FILE" 2>&1
    APT_UPDATED=1
  fi
}

ensure_pkg() {
  local bin="$1"; shift
  if ! command -v "$bin" >/dev/null 2>&1; then
    apt_update_once
    log "installing: $*"
    apt-get install -y -qq "$@" >>"$LOG_FILE" 2>&1
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi
  log "installing Docker Engine + compose plugin from docker.com apt repo"
  apt_update_once
  apt-get install -y -qq ca-certificates curl gnupg >>"$LOG_FILE" 2>&1
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -s /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>>"$LOG_FILE"
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq >>"$LOG_FILE" 2>&1
  apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    >>"$LOG_FILE" 2>&1
}

ensure_docker_running() {
  if ! systemctl is-active --quiet docker; then
    log "starting docker"
    systemctl enable --now docker >>"$LOG_FILE" 2>&1
  fi
}

need_root
ensure_pkg curl curl
ensure_pkg jq jq
ensure_docker
ensure_docker_running

# ---------- 3. Resolve VERSION (compose file already selected up-front) ----------
# Load pinned image version from the tarball's sibling VERSION file (if any).
# When missing (e.g. running from a checkout), compose falls back to :latest.
if [ -f "$SCRIPT_DIR/VERSION" ]; then
  VERSION="$(cat "$SCRIPT_DIR/VERSION")"
  export VERSION
  log "using VERSION=$VERSION"
else
  log "no VERSION file next to run.sh — compose will resolve images as :latest"
fi

# ---------- 4. Write metadata.json ----------
# Results dir was created up top so the log file is available before any
# log() calls; here we just emit metadata.

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
# Export env the compose file consumes. SCENARIO drives in-container scenario
# dispatch for the test flow (derived from --gpu-model above). RUN_ID stays a
# free-form trace ID. RESULTS_DIR is the host-side bind-mount path (containers
# still see it as /results internally).
export RUN_ID GPU_MODEL GPU_COUNT NODE_ID REGION RESULTS_DIR SCENARIO

log "docker compose up (run-id=$RUN_ID gpu-model=$GPU_MODEL scenario=$SCENARIO results-dir=$RESULTS_DIR compose=$COMPOSE_FILE)"
compose_rc=0
# Services are serialized via depends_on/service_completed_successfully, so
# an upstream failure already prevents downstream containers from starting
# — no need for --abort-on-container-exit (which prints a confusing
# "Aborting on container exit..." banner even on a clean run).
# Compose chatter goes to the log file; stderr is reserved for "couldn't run".
docker compose -f "$COMPOSE_FILE" up \
  --pull=always \
  >>"$LOG_FILE" 2>&1 || compose_rc=$?
# Regardless of compose_rc, remove stopped containers so repeat runs are clean.
docker compose -f "$COMPOSE_FILE" down --remove-orphans >>"$LOG_FILE" 2>&1 || true

# ---------- 6. Forward TAP to stdout, derive exit code ----------
# Exit-code semantics:
#   0   -> suite ran and tap_exit reports all test points ok
#   1   -> suite ran and tap_exit reports at least one not ok
#   255 -> suite could not run (no output.tap or no tap_exit signal)
if [ -s "$RESULTS_DIR/output.tap" ] && [ -f "$RESULTS_DIR/tap_exit" ]; then
  cat "$RESULTS_DIR/output.tap"
  tap_rc="$(cat "$RESULTS_DIR/tap_exit")"
  case "$tap_rc" in
    0) exit 0 ;;
    *) exit 1 ;;
  esac
fi

# No TAP output means the suite could not run (prereqs / compose / pull failure).
echo "validation suite failed to produce TAP output (docker compose exit=$compose_rc). See $LOG_FILE for detail." >&2
exit 255
