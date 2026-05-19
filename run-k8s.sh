#!/usr/bin/env bash
# Kubernetes entrypoint for the GPU droplet validation suite — the k8s analogue
# of run.sh. Same images, same /results TAP v14 contract; orchestration is one
# self-contained single-node Job per target node (Helm chart), not compose.
#
# Shipped inside the release tarball alongside run.sh, the compose files, the
# Helm chart (helm/), and a VERSION file.
#
# Contract (per node, aggregated across nodes):
#   stdout  -> TAP v14 from each node's tap-reporter
#   stderr  -> a per-node summary; a single error line iff a node could not run
#   results -> ./results/<node>/output.tap (+ diagnostics) per node
#
# Exit codes (worst-of across all targeted nodes):
#   0    every node ran and every TAP point was ok
#   1    every node ran; at least one node had a not-ok TAP point
#   255  at least one node could not run (hard prereqs/rvs fail, unschedulable,
#        pull failure, timeout) — no usable TAP from that node
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GPU_MODEL="" GPU_COUNT="" NODE_ID="" REGION="" RUN_ID=""
RESULTS_DIR="" NAMESPACE="gpu-droplet-validation" RELEASE="gdv"
TARGET_NODES="" NODE_LABEL="" VERSION_FLAG="" IMAGE_PULL_SECRET=""
RVS_TIMEOUT="" CHART_DIR="" JOB_TIMEOUT="2h" CLEANUP=0
declare -a EXTRA_TOL=()

die() { printf '%s\n' "$*" >&2; exit 255; }
log() { printf '[run-k8s] %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: run-k8s.sh --gpu-model <model> --gpu-count <n> [options]

  --gpu-model <m>        test | amd-* | nvidia-*            (required)
  --gpu-count <n>        GPUs per node                       (required)
  --node-id <id>         NODE_ID env (default: the node name)
  --region <r>           REGION env
  --run-id <id>          base RUN_ID (per-node "-<node>" suffix appended)
  --results-dir <path>   where to write per-node results (default ./results)
  --namespace <ns>       k8s namespace (default gpu-droplet-validation)
  --release-name <name>  helm release name (default gdv)
  --target-nodes a,b,c   explicit node list -> one Job per node
  --node-label k=v       resolve target nodes via this node label selector
  --version <v>          image.version (default: sibling VERSION file or latest)
  --image-pull-secret <name>  existing docker-registry secret (private ghcr only)
  --rvs-timeout <secs>   RVS_TIMEOUT (amd only)
  --toleration k=v:Eff   extra toleration (repeatable)
  --chart-dir <path>     Helm chart dir (default: auto-detected)
  --job-timeout <dur>    per-Job wait timeout (default 2h)
  --cleanup              helm uninstall after results are collected
  -h | --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --gpu-model)          GPU_MODEL="$2"; shift 2 ;;
    --gpu-count)          GPU_COUNT="$2"; shift 2 ;;
    --node-id)            NODE_ID="$2"; shift 2 ;;
    --region)             REGION="$2"; shift 2 ;;
    --run-id)             RUN_ID="$2"; shift 2 ;;
    --results-dir)        RESULTS_DIR="$2"; shift 2 ;;
    --namespace)          NAMESPACE="$2"; shift 2 ;;
    --release-name)       RELEASE="$2"; shift 2 ;;
    --target-nodes)       TARGET_NODES="$2"; shift 2 ;;
    --node-label)         NODE_LABEL="$2"; shift 2 ;;
    --version)            VERSION_FLAG="$2"; shift 2 ;;
    --image-pull-secret)  IMAGE_PULL_SECRET="$2"; shift 2 ;;
    --rvs-timeout)        RVS_TIMEOUT="$2"; shift 2 ;;
    --toleration)         EXTRA_TOL+=("$2"); shift 2 ;;
    --chart-dir)          CHART_DIR="$2"; shift 2 ;;
    --job-timeout)        JOB_TIMEOUT="$2"; shift 2 ;;
    --cleanup)            CLEANUP=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    usage; die "unknown flag: $1" ;;
  esac
done

[ -n "$GPU_MODEL" ] || { usage; die "--gpu-model is required"; }
[ -n "$GPU_COUNT" ] || { usage; die "--gpu-count is required"; }
case "$GPU_MODEL" in
  test|nvidia-*|amd-*) ;;
  *) die "unsupported --gpu-model value: $GPU_MODEL" ;;
esac
[ -n "$RUN_ID" ] || RUN_ID="auto-$(date -u +%Y%m%dT%H%M%SZ)"
[ -n "$RESULTS_DIR" ] || RESULTS_DIR="$PWD/results"
case "$RESULTS_DIR" in /*) ;; *) RESULTS_DIR="$PWD/$RESULTS_DIR" ;; esac
mkdir -p "$RESULTS_DIR"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v helm    >/dev/null 2>&1 || die "helm not found in PATH"
command -v jq      >/dev/null 2>&1 || die "jq not found in PATH"

# ---------- Resolve chart dir ----------
if [ -z "$CHART_DIR" ]; then
  for cand in \
    "$SCRIPT_DIR/helm/gpu-droplet-validation" \
    "$SCRIPT_DIR/../deploy/helm/gpu-droplet-validation" \
    "$SCRIPT_DIR/deploy/helm/gpu-droplet-validation"; do
    [ -f "$cand/Chart.yaml" ] && { CHART_DIR="$cand"; break; }
  done
fi
[ -n "$CHART_DIR" ] && [ -f "$CHART_DIR/Chart.yaml" ] || die "Helm chart not found (looked next to run-k8s.sh and under deploy/); pass --chart-dir"

# ---------- Resolve image version (mirror run.sh VERSION handling) ----------
if [ -n "$VERSION_FLAG" ]; then
  VERSION="$VERSION_FLAG"
elif [ -f "$SCRIPT_DIR/VERSION" ]; then
  VERSION="$(cat "$SCRIPT_DIR/VERSION")"
else
  VERSION="latest"
fi
log "chart=$CHART_DIR image.version=$VERSION"

# ---------- Resolve target node set ----------
declare -a NODES=()
if [ -n "$TARGET_NODES" ]; then
  IFS=',' read -r -a NODES <<< "$TARGET_NODES"
elif [ -n "$NODE_LABEL" ]; then
  mapfile -t NODES < <(kubectl get nodes -l "$NODE_LABEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  [ "${#NODES[@]}" -gt 0 ] || die "no nodes match label selector: $NODE_LABEL"
  log "resolved ${#NODES[@]} node(s) from label $NODE_LABEL: ${NODES[*]}"
fi
# Empty NODES => a single Job scheduled by the chart's nodeSelector ("" sentinel).
[ "${#NODES[@]}" -gt 0 ] || NODES=("")

sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9-]/-/g; s/^-+//; s/-+$//' | cut -c1-40 | sed -E 's/-+$//'; }
job_name() { # $1=node ; mirrors gdv.jobName
  if [ -n "$1" ]; then printf '%s-gdv-%s' "$RELEASE" "$(sanitize "$1")"
  else printf '%s-gdv' "$RELEASE"; fi
}

# ---------- Pre-flight: GPU allocatable vs requested (explicit nodes only) ----
if [ "$GPU_MODEL" != "test" ]; then
  case "$GPU_MODEL" in amd-*) RES="amd.com/gpu" ;; nvidia-*) RES="nvidia.com/gpu" ;; esac
  for n in "${NODES[@]}"; do
    [ -n "$n" ] || continue
    alloc="$(kubectl get node "$n" -o jsonpath="{.status.allocatable.${RES//./\\.}}" 2>/dev/null || true)"
    if [ -z "$alloc" ]; then
      log "WARN node $n: no '$RES' allocatable reported — device plugin installed? Pod may stay Pending."
    elif [ "${alloc%%[!0-9]*}" -lt "$GPU_COUNT" ] 2>/dev/null; then
      log "WARN node $n: allocatable $RES=$alloc < requested $GPU_COUNT — Job will stay Pending (→ 255)."
    fi
  done
fi

# ---------- Build extra-tolerations values file ----------
TOL_VALUES=""
if [ "${#EXTRA_TOL[@]}" -gt 0 ]; then
  TOL_VALUES="$(mktemp)"
  trap 'rm -f "$TOL_VALUES"' EXIT
  {
    echo "tolerations:"
    echo "  extra:"
    for t in "${EXTRA_TOL[@]}"; do
      key="${t%%=*}"; rest="${t#*=}"; val="${rest%%:*}"; eff="${rest#*:}"
      printf '  - key: %q\n    operator: Equal\n    value: %q\n    effect: %q\n' \
        "$key" "$val" "$eff"
    done
  } > "$TOL_VALUES"
fi

# ---------- helm upgrade --install ----------
declare -a HELM_ARGS=(
  upgrade --install "$RELEASE" "$CHART_DIR"
  --namespace "$NAMESPACE" --create-namespace
  --set "image.version=$VERSION"
  --set "gpuModel=$GPU_MODEL"
  --set "gpuCount=$GPU_COUNT"
  --set-string "runId=$RUN_ID"
  --set-string "nodeId=$NODE_ID"
  --set-string "region=$REGION"
  --set-string "rvsTimeout=$RVS_TIMEOUT"
)
if [ -n "$TARGET_NODES" ]; then
  HELM_ARGS+=(--set "targetNodes={$TARGET_NODES}")
elif [ -n "$NODE_LABEL" ]; then
  HELM_ARGS+=(--set "targetNodes={$(IFS=,; echo "${NODES[*]}")}")
fi
[ -n "$IMAGE_PULL_SECRET" ] && HELM_ARGS+=(--set "imagePullSecret.name=$IMAGE_PULL_SECRET")
[ -n "$TOL_VALUES" ] && HELM_ARGS+=(-f "$TOL_VALUES")

log "helm upgrade --install $RELEASE (ns=$NAMESPACE, nodes=${NODES[*]:-<selector>})"
helm "${HELM_ARGS[@]}" >&2

# ---------- Per-suite TAP order (mirrors tap-reporter.sh SUITE_FILES) --------
SUITE_FILES=(prereqs.json gpu-health.json nvlink.json gemm-compute.json \
  dcgm-diag.json nccl-allreduce.json nccl-alltoall.json rvs.json \
  rccl-allreduce.json rccl-alltoall.json p2p-bandwidth.json mock-test.json \
  post-health.json)

worst=0   # 0 < 1 < 255
bump() { case "$1" in 255) worst=255 ;; 1) [ "$worst" = 0 ] && worst=1 ;; esac; }

for n in "${NODES[@]}"; do
  jn="$(job_name "$n")"
  label="${n:-selector}"
  out="$RESULTS_DIR/$label"
  mkdir -p "$out"
  log "node=$label job=$jn — waiting (timeout $JOB_TIMEOUT)"

  # Race completion vs failure. `kubectl wait` returns 0 on the matched cond.
  if kubectl -n "$NAMESPACE" wait --for=condition=complete \
       --timeout="$JOB_TIMEOUT" "job/$jn" >/dev/null 2>&1; then
    state=complete
  elif kubectl -n "$NAMESPACE" get "job/$jn" \
         -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' \
         2>/dev/null | grep -q True; then
    state=failed
  else
    state=timeout
  fi

  if [ "$state" = complete ]; then
    # tap-reporter tees the full TAP v14 doc to stdout -> pod logs.
    if kubectl -n "$NAMESPACE" logs "job/$jn" -c tap-reporter \
         > "$out/output.tap" 2>/dev/null && [ -s "$out/output.tap" ]; then
      cat "$out/output.tap"
      if grep -qE '^not ok ' "$out/output.tap"; then
        echo 1 > "$out/tap_exit"; log "node=$label: ran, some NOT OK (exit 1)"; bump 1
      else
        echo 0 > "$out/tap_exit"; log "node=$label: ran, all ok (exit 0)"
      fi
    else
      log "node=$label: Job complete but no TAP from tap-reporter (exit 255)"
      echo 255 > "$out/tap_exit"; bump 255
    fi
  else
    # Hard-fail / unschedulable / timeout: tap-reporter never ran. Capture the
    # failing init container's diagnostics and synthesize a 255 signal.
    log "node=$label: Job $state — suite could not run (exit 255)"
    pod="$(kubectl -n "$NAMESPACE" get pod -l job-name="$jn" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fail_c="$(kubectl -n "$NAMESPACE" get pod -l job-name="$jn" -o jsonpath='{range .items[0].status.initContainerStatuses[*]}{.name}{" "}{.state.terminated.exitCode}{"\n"}{end}' 2>/dev/null \
      | awk '$2!="" && $2!="0"{print $1; exit}')"
    {
      echo "TAP version 14"
      echo "1..1"
      echo "not ok 1 - ${GPU_MODEL} | suite could not run on node ${label} (${state})"
      echo "  ---"
      echo "  message: \"Job $state; failing stage: ${fail_c:-unknown}. tap-reporter never ran.\""
      echo "  node: \"$label\""
      echo "  ..."
    } | tee "$out/output.tap"
    if [ -n "$pod" ] && [ -n "$fail_c" ]; then
      kubectl -n "$NAMESPACE" logs "$pod" -c "$fail_c" \
        > "$out/${fail_c}.log" 2>/dev/null || true
    fi
    echo 255 > "$out/tap_exit"; bump 255
  fi
done

# ---------- Summary ----------
log "----- summary -----"
for n in "${NODES[@]}"; do
  label="${n:-selector}"
  rc="$(cat "$RESULTS_DIR/$label/tap_exit" 2>/dev/null || echo '?')"
  case "$rc" in
    0) verdict="PASS" ;; 1) verdict="FAIL (not ok points)" ;;
    255) verdict="COULD NOT RUN" ;; *) verdict="UNKNOWN" ;;
  esac
  log "  $label: $verdict (exit $rc)"
done

if [ "$CLEANUP" = 1 ]; then
  log "helm uninstall $RELEASE"
  helm uninstall "$RELEASE" --namespace "$NAMESPACE" >&2 || true
fi

case "$worst" in 0) exit 0 ;; 1) exit 1 ;; *) exit 255 ;; esac
