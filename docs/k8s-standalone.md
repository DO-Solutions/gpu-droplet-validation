# Standalone & one-off runs

The standalone Kubernetes manifests in [`../k8s/`](../k8s/) let you
`kubectl apply -f` directly — no script, no repo checkout. There are two kinds:

- **Full-suite Jobs** (`full-suite-amd.yaml` / `full-suite-nvidia.yaml`) — the
  **whole validation suite** as a single self-contained Job, identical to what
  `run-k8s.sh` generates, checked in so a customer can validate a node by
  sending one YAML. Use these for a real pass/fail verdict.
- **One-off diagnostics** — a single stage run by itself, no validation chain,
  no pass/fail floor. They split along the same line for both vendors:
  - The **collective-perf** Pods (`rccl-allreduce-adhoc.yaml` /
    `nccl-allreduce-adhoc.yaml`) run the RCCL/NCCL binary **directly** (the image
    entrypoint is overridden), so there is no floor and no `GPU_MODEL` coupling —
    they work on any SKU. The signal is the per-size busbw table + the
    `Avg bus bandwidth` line in the logs. This is the easy "do the GPUs / fabric
    work at all" check.
  - The **SKU-specific** Pods (`rvs-mi350x-level5.yaml` / `dcgm-b300-adhoc.yaml`)
    run RVS or DCGM via the image entrypoint, which needs `GPU_MODEL` to pick the
    right conf / plugin set. The signal is the raw RVS `[RESULT]` stream / `dcgmi
    diag` table in the logs.

For the per-TAP-point reference (thresholds, what `ok` vs `not ok` means), see
[test-suite.md](test-suite.md).

## `full-suite-amd.yaml` — calibrated single-node run, no script needed

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
kubectl apply -f k8s/full-suite-amd.yaml
kubectl logs -f job/gdv-changeme-node -c tap-reporter   # TAP v14 — primary signal

# pull the full artifact set the compose flow would also produce:
POD=$(kubectl get pod -l job-name=gdv-changeme-node -o jsonpath='{.items[0].metadata.name}')
kubectl cp "$POD":/results ./results -c tap-reporter

kubectl delete -f k8s/full-suite-amd.yaml
```

`amd-mi300x` · `amd-mi325x` · `amd-mi350x` · `amd-mi355x` all share this one
image set; per-SKU thresholds resolve inside the containers from `$GPU_MODEL`.
The header comment in the file documents every CHANGEME edit. The Pod tolerates
the `amd.com/gpu` GPU taint **by key** (`operator: Exists`) because DOKS sets it
with an empty value (`amd.com/gpu=:NoSchedule`). It requires the AMD GPU device
plugin on the node; if that is absent, regenerate with
`run-k8s.sh --raw-device-fallback` to hostPath-mount `/dev/kfd` + `/dev/dri`.

## `full-suite-nvidia.yaml` — the NVIDIA suite, no script needed

The NVIDIA analogue of `full-suite-amd.yaml`: a complete single-node Job whose
stages are `prereqs → setup → dcgm-diag → NCCL allreduce/alltoall → teardown`,
again byte-for-byte what `run-k8s.sh --gpu-model nvidia-b300 ... --print-manifest`
emits. Requesting `nvidia.com/gpu` requires the **NVIDIA GPU device plugin**
on the node (installed by default on DOKS GPU nodes); there is no raw-device
fallback (that path is AMD-specific).

```bash
# Retarget first (nodeSelector hostname, NODE_ID env, metadata.name — all CHANGEME).
kubectl apply -f k8s/full-suite-nvidia.yaml
kubectl logs -f job/gdv-changeme-node -c tap-reporter   # TAP v14 — primary signal
kubectl delete -f k8s/full-suite-nvidia.yaml
```

`nvidia-b300` is currently the only calibrated NVIDIA SKU; adding another is a
one-line case arm in [`../containers/_lib/nvidia_models.sh`](../containers/_lib/nvidia_models.sh)
(the one NVIDIA image set serves every SKU — no manifest change).

## RVS standalone (one-off)

Separate from the full flow, the `rvs` container can run RVS by itself for AMD
GPU types we do not yet fully validate. The vendored conf tree ships **levels 4
and 5** for **MI300X, MI325X, MI350X, MI355X** (mirrored verbatim from upstream
`ROCmValidationSuite/rvs/conf/<MODEL>/levels/`):

| `GPU_MODEL`   | level 4 (default) | level 5 (long soak, hours) |
| ------------- | :---------------: | :------------------------: |
| `amd-mi300x`  | ✔ | ✔ |
| `amd-mi325x`  | ✔ | ✔ |
| `amd-mi350x`  | ✔ | ✔ |
| `amd-mi355x`  | ✔ | ✔ |

Select with `GPU_MODEL` + `RVS_LEVEL` (default `4`); `rvs-base` is built for
both `gfx942` (CDNA3: MI300X/MI325X) and `gfx950` (CDNA4: MI350X/MI355X). This
is **one-off only** — the official `run.sh`/compose flow is calibrated for
**`amd-mi325x` and `amd-mi350x` (level 4)**, while the remaining SKUs
(`amd-mi300x`, `amd-mi355x`) have no calibrated pass/fail floors (the RVS log is
the signal). Running the full flow on an uncalibrated SKU still fails fast at
`rccl-tests-amd` (unset floor).

### `rvs-mi350x-level5.yaml` — RVS level-5 soak on one MI350X node

A standalone Kubernetes Pod that runs the `rvs` container's vendored
`rvs_level_5.conf` for MI350X.

```bash
kubectl apply -f k8s/rvs-mi350x-level5.yaml
kubectl wait --for=condition=Ready pod/rvs-mi350x-level5 --timeout=5m
kubectl logs -f pod/rvs-mi350x-level5            # primary signal (RVS tees to stdout)

# optional — pull the artifacts the full flow's parser would consume:
kubectl cp rvs-mi350x-level5:/results/rvs.json ./rvs.json
kubectl cp rvs-mi350x-level5:/results/rvs.log  ./rvs.log

kubectl delete -f k8s/rvs-mi350x-level5.yaml
```

Before applying, set **`nodeSelector.kubernetes.io/hostname`** and the
**`NODE_ID`** env to your actual MI350X node.

#### Retargeting to another SKU / level

The one manifest covers every vendored combination — edit two env vars:

| env | values |
|-----|--------|
| `GPU_MODEL` | `amd-mi300x` · `amd-mi325x` · `amd-mi350x` · `amd-mi355x` |
| `RVS_LEVEL` | `4` (default, ~minutes) · `5` (long soak, hours) |

The image vendors `containers/rvs/conf/<GPU_MODEL>/rvs_level_<RVS_LEVEL>.conf`;
`amd_models.sh` resolves it from these two vars.

#### Level 4 vs level 5

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
confirm a node's GPUs / fabric / config work at all.

```bash
kubectl apply -f k8s/rccl-allreduce-adhoc.yaml
kubectl wait --for=condition=Ready pod/rccl-allreduce-adhoc --timeout=5m
kubectl logs -f pod/rccl-allreduce-adhoc         # primary signal (perf table on stdout)

kubectl delete -f k8s/rccl-allreduce-adhoc.yaml
```

Before applying, set **`nodeSelector.kubernetes.io/hostname`** and the
**`NODE_ID`** env to your actual node.

### Diagnostic only — no floor gate

Because the manifest runs the binary directly, it **bypasses the
`rccl-tests-amd` entrypoint**: there is no `amd_models.sh`, no `GPU_MODEL`, and
**no pass/fail floor**. The signal is the per-size busbw table and the
`Avg bus bandwidth` line in the logs. For a calibrated pass/fail run, use the
full `run.sh` / compose flow on `amd-mi325x`, where the entrypoint gates
mean-of-3 busbw@8GB against `RCCL_ALLREDUCE_FLOOR=300` GB/s
([`../containers/_lib/amd_models.sh`](../containers/_lib/amd_models.sh)).

### Retargeting

- **alltoall** instead of allreduce: change the command's binary to
  `/rccl-tests/build/alltoall_perf` (same flags).
- **different GPU count**: change *both* the command's `-g N` and
  `resources.limits.amd.com/gpu` to `N` — they must match.

The flags mirror exactly what the suite's entrypoint runs:
`-b 32K -e 8G -f 2 -g 8 -w 5 -n 20`.

### Why this is one-off only

`amd-mi300x/350x/355x` have RVS-only arms in
[`../containers/_lib/amd_models.sh`](../containers/_lib/amd_models.sh): they
resolve `RVS_CONF` but set no RCCL floors and disable the VRAM gate, so the full
`run.sh` flow still fails fast for them. Only `amd-mi325x` (level 4) is
calibrated end to end. The vendored confs are mirrored verbatim from upstream
`ROCmValidationSuite/rvs/conf/<MODEL>/levels/`.

## `dcgm-b300-adhoc.yaml` — diagnostic DCGM diag on one NVIDIA node

A standalone Kubernetes Pod that runs the `dcgm-diag` image's **default
entrypoint** on one node — the NVIDIA analogue of `rvs-mi350x-level5.yaml`,
running just the DCGM stage in isolation instead of the full
`prereqs → setup → dcgm-diag → NCCL → teardown` chain.

```bash
kubectl apply -f k8s/dcgm-b300-adhoc.yaml
kubectl wait --for=condition=Ready pod/dcgm-b300-adhoc --timeout=5m
kubectl logs -f pod/dcgm-b300-adhoc              # primary signal (dcgmi diag on stdout)

# optional — pull the artifacts the full flow's parser would consume:
kubectl cp dcgm-b300-adhoc:/results/dcgm-diag.json     ./dcgm-diag.json      # parsed
kubectl cp dcgm-b300-adhoc:/results/dcgm-diag_raw.json ./dcgm-diag_raw.json  # verbatim dcgmi -j

kubectl delete -f k8s/dcgm-b300-adhoc.yaml
```

Before applying, set **`nodeSelector.kubernetes.io/hostname`** and the
**`NODE_ID`** env to your actual node.

### Fixed plugin set — no level knob

`GPU_MODEL=nvidia-b300` is **required**: the entrypoint sources
[`../containers/_lib/nvidia_models.sh`](../containers/_lib/nvidia_models.sh),
which exits on an unset/unknown SKU **and** fixes the plugin selection plus
per-plugin duration caps. Unlike RVS there is no `RVS_LEVEL`-style knob. The run
is `dcgmi diag -r "memory,diagnostic,targeted stress,targeted power"` with the
`diagnostic`/`targeted_stress`/`targeted_power` duration caps, plus the always-on
`software` deployment check — **~29 min on 8× B300**. This is the same diag the
full suite runs, just standalone (it launches its own `nv-hostengine`). For the
per-point thresholds and what each plugin's `not ok` means, see the `nvidia-b300`
section of [test-suite.md](test-suite.md).

### GPU access

Via the **`nvidia.com/gpu` device plugin only** (installed by default on DOKS
GPU nodes). Unlike the AMD one-offs there is **no raw-device (`/dev/kfd`)
fallback** — the NVIDIA runtime injects the devices.

## `nccl-allreduce-adhoc.yaml` — diagnostic NCCL allreduce on one NVIDIA node

A standalone Kubernetes Pod that runs the `nccl-tests-nvidia` image's
`all_reduce_perf` binary **directly** (overriding the image entrypoint) to
confirm a node's GPUs / NVLink fabric / config work at all. The NVIDIA analogue
of `rccl-allreduce-adhoc.yaml` — same strategy, same purpose.

```bash
kubectl apply -f k8s/nccl-allreduce-adhoc.yaml
kubectl wait --for=condition=Ready pod/nccl-allreduce-adhoc --timeout=5m
kubectl logs -f pod/nccl-allreduce-adhoc         # primary signal (perf table on stdout)

kubectl delete -f k8s/nccl-allreduce-adhoc.yaml
```

Before applying, set **`nodeSelector.kubernetes.io/hostname`** and the
**`NODE_ID`** env to your actual node.

### Diagnostic only — no floor gate

Because the manifest runs the binary directly, it **bypasses the
`nccl-tests-nvidia` entrypoint**: there is no `nvidia_models.sh`, no `GPU_MODEL`,
and **no pass/fail floor** — so it runs on any NVIDIA SKU, not just calibrated
ones. The signal is the per-size busbw table and the `Avg bus bandwidth` line in
the logs. For a calibrated pass/fail run (mean-of-3 busbw@8GB gated against
`NCCL_ALLREDUCE_FLOOR=810` GB/s plus the NVLink-transport assertion), use the
full `run.sh` / compose flow on `nvidia-b300`
([`../containers/_lib/nvidia_models.sh`](../containers/_lib/nvidia_models.sh)).

### Retargeting

- **alltoall** instead of allreduce: change the command's binary to
  `/opt/nccl-tests/build/alltoall_perf` (same flags).
- **different GPU count**: change *both* the command's `-g N` and
  `resources.limits.nvidia.com/gpu` to `N` — they must match.

The flags mirror exactly what the suite's entrypoint runs:
`-b 32K -e 8G -f 2 -g 8 -w 5 -n 20`. `hostIPC: true` is required (NCCL
single-node shared-memory transport), and GPU access is via the `nvidia.com/gpu`
device plugin only (no raw-device fallback — that path is AMD-specific).

### Binary path stability

The path `/opt/nccl-tests/build/` is fixed by the pinned `nccl-tests` image
(`ghcr.io/do-solutions/nccl-tests`, an upstream `nvidia/nccl-tests` mirror); it
only moves on a deliberate base-image refresh. If a future image relocates the
binary, drop the `command:` override to fall back to the entrypoint's `find_bin`
(which then also re-applies the floor).
