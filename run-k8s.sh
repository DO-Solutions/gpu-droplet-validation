#!/usr/bin/env bash
# Kubernetes entrypoint for the GPU droplet validation suite — the k8s analogue
# of run.sh. Same images, same /results TAP v14 contract; orchestration is one
# self-contained single-node Job per target node, generated as plain YAML and
# `kubectl apply`d (the "run.sh of Kubernetes" — no Helm, no release state).
#
# Shipped inside the release tarball alongside run.sh, the compose files,
# examples/, and a VERSION file.
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

REGISTRY="ghcr.io"
REPO_PREFIX="do-solutions/gpu-droplet-validation"
JOB_PREFIX="gdv"

GPU_MODEL="" GPU_COUNT="" NODE_ID="" REGION="" RUN_ID=""
RESULTS_DIR="" NAMESPACE="gpu-droplet-validation"
TARGET_NODES="" NODE_LABEL="" VERSION_FLAG="" IMAGE_PULL_SECRET=""
RVS_TIMEOUT="" GPU_RESOURCE_NAME="" JOB_TIMEOUT="2h"
PRINT_MANIFEST=0 RAW_DEVICE_FALLBACK=0
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
  --target-nodes a,b,c   explicit node list -> one Job per node
  --node-label k=v       resolve target nodes via this node label selector
  --version <v>          image version (default: sibling VERSION file or latest)
  --image-pull-secret <name>  existing docker-registry secret (private ghcr only)
  --gpu-resource <name>  device-plugin resource (default amd.com/gpu | nvidia.com/gpu)
  --rvs-timeout <secs>   RVS_TIMEOUT (amd only)
  --toleration k=v:Eff   extra toleration (repeatable)
  --raw-device-fallback  hostPath-mount /dev/kfd + /dev/dri into GPU stages
                         (use only if the device plugin does not inject them)
  --job-timeout <dur>    per-Job wait timeout (default 2h)
  --print-manifest       print the Job YAML for the single/first node and exit
                         (no cluster access; the standalone example is generated
                         from this)
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
    --target-nodes)       TARGET_NODES="$2"; shift 2 ;;
    --node-label)         NODE_LABEL="$2"; shift 2 ;;
    --version)            VERSION_FLAG="$2"; shift 2 ;;
    --image-pull-secret)  IMAGE_PULL_SECRET="$2"; shift 2 ;;
    --gpu-resource)       GPU_RESOURCE_NAME="$2"; shift 2 ;;
    --rvs-timeout)        RVS_TIMEOUT="$2"; shift 2 ;;
    --toleration)         EXTRA_TOL+=("$2"); shift 2 ;;
    --raw-device-fallback) RAW_DEVICE_FALLBACK=1; shift ;;
    --job-timeout)        JOB_TIMEOUT="$2"; shift 2 ;;
    --print-manifest)     PRINT_MANIFEST=1; shift ;;
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

# ---------- Resolve image version (mirror run.sh VERSION handling) ----------
if [ -n "$VERSION_FLAG" ]; then
  VERSION="$VERSION_FLAG"
elif [ -f "$SCRIPT_DIR/VERSION" ]; then
  VERSION="$(cat "$SCRIPT_DIR/VERSION")"
else
  VERSION="latest"
fi
# Mirror Kubernetes' own default: Always for a moving :latest, IfNotPresent for
# a pinned tag (so a stale cached :latest is never silently reused).
if [ "$VERSION" = latest ]; then PULL_POLICY="Always"; else PULL_POLICY="IfNotPresent"; fi

# ---------- Naming helpers (DNS-1123-safe) ----------
sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9-]/-/g; s/^-+//; s/-+$//' | cut -c1-40 | sed -E 's/-+$//'; }
job_name() { # $1=node (may be "")
  if [ -n "$1" ]; then printf '%s-%s' "$JOB_PREFIX" "$(sanitize "$1")"
  else printf '%s' "$JOB_PREFIX"; fi
}

image_ref() { printf '%s/%s/%s:%s' "$REGISTRY" "$REPO_PREFIX" "$1" "$VERSION"; }

# ---------- stage_list <gpu-model> ----------
# The model -> ordered-stage mapping (was the chart's gdv.stageList): the single
# seam that keeps one path for AMD/NVIDIA/test. Sets:
#   STAGE_GPU            1 if GPU stages (device-plugin resource + securityContext)
#   STAGE_GPU_RESOURCE   device-plugin resource name (e.g. amd.com/gpu)
#   STAGE_GPU_TAINT_KEY  taint key to tolerate (e.g. amd.com/gpu); "" = none
#   STAGE_MAIN           image name for the main (tap-reporter) container
#   STAGE_INIT[]         ordered initContainers: "name image [ENVK=ENVV ...]"
STAGE_GPU=0 STAGE_GPU_RESOURCE="" STAGE_GPU_TAINT_KEY="" STAGE_MAIN="tap-reporter"
declare -a STAGE_INIT=()
stage_list() {
  STAGE_MAIN="tap-reporter"; STAGE_INIT=()
  case "$1" in
    amd-*)
      STAGE_GPU=1
      STAGE_GPU_RESOURCE="${GPU_RESOURCE_NAME:-amd.com/gpu}"
      STAGE_GPU_TAINT_KEY="amd.com/gpu"
      STAGE_INIT=(
        "prereqs prereqs-amd"
        "setup setup-amd"
        "rvs rvs RVS_TIMEOUT=$RVS_TIMEOUT"
        "rccl-allreduce rccl-tests-amd RCCL_TEST=allreduce"
        "rccl-alltoall rccl-tests-amd RCCL_TEST=alltoall"
        "teardown teardown-amd"
      ) ;;
    nvidia-*)
      STAGE_GPU=1
      STAGE_GPU_RESOURCE="${GPU_RESOURCE_NAME:-nvidia.com/gpu}"
      STAGE_GPU_TAINT_KEY="nvidia.com/gpu"
      STAGE_INIT=(
        "prereqs prereqs-nvidia"
        "setup setup-nvidia"
        "dcgm-diag dcgm-diag"
        "nccl-allreduce nccl-tests-nvidia NCCL_TEST=allreduce"
        "nccl-alltoall nccl-tests-nvidia NCCL_TEST=alltoall"
        "teardown teardown-nvidia"
      ) ;;
    test)
      STAGE_GPU=0
      STAGE_GPU_RESOURCE="" STAGE_GPU_TAINT_KEY=""
      STAGE_INIT=(
        "prereqs prereqs-test"
        "setup setup-test"
        "mock-test mock-test"
        "teardown teardown-test"
      ) ;;
    *) die "unsupported gpu-model: $1" ;;
  esac
}

# ---------- render_job <node> ----------
# Print a complete single-node Job manifest to stdout. Empty node => no
# nodeSelector (scheduled to any node tolerating the taints).
emit_common_env() { # $1=node $2=runId ; entries indented 12 spaces
  local node="$1" runId="$2" nid="${NODE_ID:-$1}"
  cat <<EOF
            - name: RUN_ID
              value: "${runId}"
            - name: GPU_MODEL
              value: "${GPU_MODEL}"
            - name: GPU_COUNT
              value: "${GPU_COUNT}"
            - name: NODE_ID
              value: "${nid}"
            - name: REGION
              value: "${REGION}"
EOF
}

render_job() { # $1=node (may be "")
  local node="$1" jn runId label
  jn="$(job_name "$node")"
  if [ -n "$node" ]; then runId="${RUN_ID}-$(sanitize "$node")"; else runId="$RUN_ID"; fi
  label="${node:-selector}"

  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${jn}
  labels:
    app.kubernetes.io/name: gpu-droplet-validation
    app.kubernetes.io/instance: ${JOB_PREFIX}
    app.kubernetes.io/managed-by: run-k8s.sh
    gdv/gpu-model: "${GPU_MODEL}"
    gdv/node: "${label}"
spec:
  backoffLimit: 0                 # exit 1 is a valid result; never retry
  ttlSecondsAfterFinished: 3600   # window for run-k8s.sh to collect /results
  activeDeadlineSeconds: 7200     # whole-suite wall-clock guard
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gpu-droplet-validation
        app.kubernetes.io/instance: ${JOB_PREFIX}
        gdv/node: "${label}"
    spec:
      restartPolicy: Never
EOF
  [ "$STAGE_GPU" = 1 ] && echo "      hostIPC: true   # RCCL single-node shared-memory transport"
  if [ -n "$IMAGE_PULL_SECRET" ]; then
    printf '      imagePullSecrets:\n        - name: %s\n' "$IMAGE_PULL_SECRET"
  fi
  if [ -n "$node" ]; then
    printf '      nodeSelector:\n        kubernetes.io/hostname: %s\n' "$node"
  fi

  # Tolerations: match the GPU taint BY KEY (operator: Exists) — DOKS sets the
  # taint with an empty value (amd.com/gpu=:NoSchedule), so Equal/value would
  # never match. Plus the cordoned-node taint, plus any --toleration extras.
  echo "      tolerations:"
  if [ "$STAGE_GPU" = 1 ] && [ -n "$STAGE_GPU_TAINT_KEY" ]; then
    printf '        - key: %s\n          operator: Exists\n          effect: NoSchedule\n' "$STAGE_GPU_TAINT_KEY"
  fi
  printf '        - key: node.kubernetes.io/unschedulable\n          operator: Exists\n          effect: NoSchedule\n'
  local t key rest val eff
  for t in "${EXTRA_TOL[@]}"; do
    key="${t%%=*}"; rest="${t#*=}"; val="${rest%%:*}"; eff="${rest#*:}"
    printf '        - key: %s\n          operator: Equal\n          value: "%s"\n          effect: %s\n' \
      "$key" "$val" "$eff"
  done

  echo "      volumes:"
  echo "        - name: results"
  echo "          emptyDir: {}"
  if [ "$STAGE_GPU" = 1 ] && [ "$RAW_DEVICE_FALLBACK" = 1 ]; then
    cat <<'EOF'
        - name: dev-kfd
          hostPath:
            path: /dev/kfd
            type: CharDevice
        - name: dev-dri
          hostPath:
            path: /dev/dri
            type: Directory
EOF
  fi

  echo "      initContainers:"
  local spec name img envs e k v
  for spec in "${STAGE_INIT[@]}"; do
    # split "name image [ENVK=ENVV ...]" -> name, img, remaining env tokens
    name="${spec%% *}"; rest="${spec#* }"
    img="${rest%% *}"
    if [ "$rest" = "$img" ]; then envs=""; else envs="${rest#* }"; fi
    printf '        - name: %s\n' "$name"
    printf '          image: %s\n' "$(image_ref "$img")"
    printf '          imagePullPolicy: %s\n' "$PULL_POLICY"
    if [ "$STAGE_GPU" = 1 ]; then
      cat <<'EOF'
          securityContext:
            privileged: true
            capabilities:
              add: ["SYS_PTRACE"]
            seccompProfile:
              type: Unconfined
EOF
    fi
    echo "          env:"
    emit_common_env "$node" "$runId"
    if [ -n "$envs" ]; then
      for e in $envs; do
        k="${e%%=*}"; v="${e#*=}"
        printf '            - name: %s\n              value: "%s"\n' "$k" "$v"
      done
    fi
    if [ "$STAGE_GPU" = 1 ]; then
      printf '          resources:\n            limits:\n              "%s": %s\n' \
        "$STAGE_GPU_RESOURCE" "$GPU_COUNT"
    fi
    echo "          volumeMounts:"
    echo "            - name: results"
    echo "              mountPath: /results"
    if [ "$STAGE_GPU" = 1 ] && [ "$RAW_DEVICE_FALLBACK" = 1 ]; then
      cat <<'EOF'
            - name: dev-kfd
              mountPath: /dev/kfd
            - name: dev-dri
              mountPath: /dev/dri
EOF
    fi
  done

  cat <<EOF
      containers:
        - name: tap-reporter
          image: $(image_ref "$STAGE_MAIN")
          imagePullPolicy: ${PULL_POLICY}
          env:
EOF
  emit_common_env "$node" "$runId"
  echo "          volumeMounts:"
  echo "            - name: results"
  echo "              mountPath: /results"
}

stage_list "$GPU_MODEL"

# ---------- --print-manifest: emit one node's Job and exit (offline) ----------
if [ "$PRINT_MANIFEST" = 1 ]; then
  first=""
  [ -n "$TARGET_NODES" ] && first="${TARGET_NODES%%,*}"
  render_job "$first"
  exit 0
fi

[ -n "$RESULTS_DIR" ] || RESULTS_DIR="$PWD/results"
case "$RESULTS_DIR" in /*) ;; *) RESULTS_DIR="$PWD/$RESULTS_DIR" ;; esac
mkdir -p "$RESULTS_DIR"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"

log "image.version=$VERSION pullPolicy=$PULL_POLICY"

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
# Empty NODES => a single Job scheduled by tolerations only ("" sentinel).
[ "${#NODES[@]}" -gt 0 ] || NODES=("")

# ---------- Pre-flight: GPU allocatable vs requested (explicit nodes only) ----
if [ "$STAGE_GPU" = 1 ]; then
  RES="$STAGE_GPU_RESOURCE"
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

# ---------- Ensure namespace, then generate + apply one Job per node ----------
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || \
  kubectl create namespace "$NAMESPACE" >&2
for n in "${NODES[@]}"; do
  jn="$(job_name "$n")"
  log "apply job=$jn (ns=$NAMESPACE, node=${n:-<any tolerated>})"
  render_job "$n" | kubectl -n "$NAMESPACE" apply -f - >&2
done

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

case "$worst" in 0) exit 0 ;; 1) exit 1 ;; *) exit 255 ;; esac
