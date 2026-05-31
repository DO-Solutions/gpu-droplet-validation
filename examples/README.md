# examples/

Standalone Kubernetes manifests you can `kubectl apply -f` directly — no
script, no repo checkout. There are two kinds here:

- **`full-suite-amd.yaml`** / **`full-suite-nvidia.yaml`** are the **whole
  validation suite** as a single self-contained Job — the same thing
  `run-k8s.sh` generates and applies, just checked in so a customer can validate
  a node by sending one YAML. Use these for a real pass/fail verdict. The AMD
  manifest is validated end-to-end on hardware; the NVIDIA one is shipped ready
  but **not yet run on a real GPU node** (see its header).
- **`rvs-mi350x-level5.yaml`** and **`rccl-allreduce-adhoc.yaml`** are **one-off
  diagnostics** for exercising GPU types or RVS levels we do not yet fully
  validate. They are **not** the calibrated path — the official flow is
  `amd-mi325x`/`amd-mi350x` at RVS level 4 only, and there are **no pass/fail
  floors** for the other SKUs. The signal there is the raw RVS `[RESULT]`
  stream / RCCL busbw table in the logs.

## `full-suite-amd.yaml` — the calibrated single-node run, no script needed

A complete single-node Job: the serial validation stages
(prereqs → setup → rvs → RCCL allreduce/alltoall → teardown) are
`initContainers` sharing an `emptyDir` `/results`, and `tap-reporter` is the
main container emitting the TAP v14 verdict — identical to the Docker Compose
path, only orchestrated as a Job. It is byte-for-byte what
`run-k8s.sh --gpu-model amd-mi350x --gpu-count 8 --target-nodes <node>
--print-manifest` produces (so the two paths never drift); applying it directly
is the no-script option when sending one file is easier than shipping the repo.

```bash
# Retarget first: set nodeSelector kubernetes.io/hostname, the NODE_ID env, and
# the metadata.name (all marked CHANGEME). For another AMD SKU, also change
# GPU_MODEL + the gpu count (env GPU_COUNT and resources.limits."amd.com/gpu").
kubectl apply -f examples/full-suite-amd.yaml
kubectl logs -f job/gdv-changeme-node -c tap-reporter   # TAP v14 — primary signal

# pull the full artifact set the compose flow would also produce:
POD=$(kubectl get pod -l job-name=gdv-changeme-node -o jsonpath='{.items[0].metadata.name}')
kubectl cp "$POD":/results ./results -c tap-reporter

kubectl delete -f examples/full-suite-amd.yaml
```

`amd-mi300x` · `amd-mi325x` · `amd-mi350x` · `amd-mi355x` all share this one
image set; per-SKU thresholds resolve inside the containers from `$GPU_MODEL`.
The header comment in the file documents every CHANGEME edit. The Pod tolerates
the `amd.com/gpu` GPU taint **by key** (`operator: Exists`) because DOKS sets it
with an empty value (`amd.com/gpu=:NoSchedule`). It requires the AMD GPU device
plugin on the node; if that is absent, regenerate with
`run-k8s.sh --raw-device-fallback` to hostPath-mount `/dev/kfd` + `/dev/dri`.

## `full-suite-nvidia.yaml` — the NVIDIA suite, no script needed (experimental)

The NVIDIA analogue of `full-suite-amd.yaml`: a complete single-node Job whose
stages are `prereqs → setup → dcgm-diag → NCCL allreduce/alltoall → teardown`,
again byte-for-byte what `run-k8s.sh --gpu-model nvidia-b300 ... --print-manifest`
emits. Requesting `nvidia.com/gpu` requires the **NVIDIA GPU operator** (or
k8s-device-plugin) on the node; there is no raw-device fallback (that path is
AMD-specific).

> ⚠ **Untested on hardware.** The k8s path is validated end-to-end on AMD
> MI350X, but no B300 was available to run the NVIDIA path. The manifest shape,
> tolerations, and dry-run validation are confirmed; the in-pod behaviour is
> not. It is shipped ready so it can be exercised — and fixed in place — the
> moment a B300 node exists.

```bash
# Retarget first (nodeSelector hostname, NODE_ID env, metadata.name — all CHANGEME).
kubectl apply -f examples/full-suite-nvidia.yaml
kubectl logs -f job/gdv-changeme-node -c tap-reporter   # TAP v14 — primary signal
kubectl delete -f examples/full-suite-nvidia.yaml
```

`nvidia-b300` is currently the only calibrated NVIDIA SKU; adding another is a
one-line case arm in `containers/_lib/nvidia_models.sh` (the one NVIDIA image
set serves every SKU — no manifest change).

## `rvs-mi350x-level5.yaml` — RVS level-5 soak on one MI350X node

A standalone Kubernetes Pod that runs the `rvs` container's vendored
`rvs_level_5.conf` for MI350X. Modeled on `scratch/rccl.yaml`.

```bash
kubectl apply -f examples/rvs-mi350x-level5.yaml
kubectl wait --for=condition=Ready pod/rvs-mi350x-level5 --timeout=5m
kubectl logs -f pod/rvs-mi350x-level5            # primary signal (RVS tees to stdout)

# optional — pull the artifacts the full flow's parser would consume:
kubectl cp rvs-mi350x-level5:/results/rvs.json ./rvs.json
kubectl cp rvs-mi350x-level5:/results/rvs.log  ./rvs.log

kubectl delete -f examples/rvs-mi350x-level5.yaml
```

Before applying, set **`nodeSelector.kubernetes.io/hostname`** and the
**`NODE_ID`** env to your actual MI350X node.

### Retargeting to another SKU / level

The one manifest covers every vendored combination — edit two env vars:

| env | values |
|-----|--------|
| `GPU_MODEL` | `amd-mi300x` · `amd-mi325x` · `amd-mi350x` · `amd-mi355x` |
| `RVS_LEVEL` | `4` (default, ~minutes) · `5` (long soak, hours) |

The image vendors `containers/rvs/conf/<GPU_MODEL>/rvs_level_<RVS_LEVEL>.conf`;
`amd_models.sh` resolves it from these two vars.

### Level 4 vs level 5

Level 5 is a long-duration soak of the same actions, not new ones:

- Most actions: ~10 s → ~900 s (≈90×).
- PCIe / xGMI bandwidth: ~30 s → ~900 s.
- `power-stress` (IET): ~60 s → ~3600 s.
- Iterations scale up too (e.g. babel `num_iter` 100 → 10000, `memtest`
  count 1 → 20).

So a full level-5 run takes **hours**. The manifest sets
`RVS_TIMEOUT=43200` (12 h) — the entrypoint's default 1800 s would kill a
level-5 run almost immediately. Lower it for a deliberately partial soak.

## `rccl-allreduce-adhoc.yaml` — diagnostic RCCL allreduce on one node

A standalone Kubernetes Pod that runs the `rccl-tests-amd` image's
`all_reduce_perf` binary **directly** (overriding the image entrypoint) to
confirm a node's GPUs / fabric / config work at all. Modeled on
`scratch/rccl.yaml`.

```bash
kubectl apply -f examples/rccl-allreduce-adhoc.yaml
kubectl wait --for=condition=Ready pod/rccl-allreduce-adhoc --timeout=5m
kubectl logs -f pod/rccl-allreduce-adhoc         # primary signal (perf table on stdout)

kubectl delete -f examples/rccl-allreduce-adhoc.yaml
```

Before applying, set **`nodeSelector.kubernetes.io/hostname`** and the
**`NODE_ID`** env to your actual node.

### Diagnostic only — no floor gate

Because the manifest runs the binary directly, it **bypasses the
`rccl-tests-amd` entrypoint**: there is no `amd_models.sh`, no `GPU_MODEL`, and
**no pass/fail floor**. The signal is the per-size busbw table and the
`Avg bus bandwidth` line in the logs. For a calibrated pass/fail run, use the
full `run.sh` / compose flow on `amd-mi325x`, where the entrypoint gates
best-of-3 busbw@8GB against `RCCL_ALLREDUCE_FLOOR=300` GB/s
(`containers/_lib/amd_models.sh`).

### Retargeting

- **alltoall** instead of allreduce: change the command's binary to
  `/rccl-tests/build/alltoall_perf` (same flags).
- **different GPU count**: change *both* the command's `-g N` and
  `resources.limits.amd.com/gpu` to `N` — they must match.

The flags mirror exactly what the suite's entrypoint runs:
`-b 32K -e 8G -f 2 -g 8 -w 5 -n 20`.

### Why this is one-off only

`amd-mi300x/350x/355x` have RVS-only arms in
`containers/_lib/amd_models.sh`: they resolve `RVS_CONF` but set no RCCL
floors and disable the VRAM gate, so the full `run.sh` flow still fails fast
for them. Only `amd-mi325x` (level 4) is calibrated end to end. The vendored
confs are mirrored verbatim from upstream
`ROCmValidationSuite/rvs/conf/<MODEL>/levels/`.
