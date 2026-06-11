# gpu-droplet-validation

Entrypoint + container stack for GPU droplet validation. Cloud-init
(or a human) extracts a release tarball onto a Droplet, runs `run.sh`, and
gets TAP v14 on stdout plus artifacts in `./results` (override with
`--results-dir <path>`). The same images and `/results` TAP v14 contract also
run on Kubernetes via `run-k8s.sh` or via custom manifest.

## Supported families

| `--gpu-model`  | What it runs                                                       |
| -------------- | ------------------------------------------------------------ |
| `test`         | Mock CPU-only stack used for integration testing (see [docs/development.md](docs/development.md#test-family-run-id-dispatch)) |
| `nvidia-b300`  | prereqs + setup + `dcgmi diag -r 3` + NCCL allreduce/alltoall + post-health |
| `amd-mi325x`   | prereqs + setup + `rvs -c <conf>` (level 4) + RCCL allreduce/alltoall + post-health |
| `amd-mi350x`   | prereqs + setup + `rvs -c <conf>` (level 4) + RCCL allreduce/alltoall + post-health |

Per-SKU TAP point breakdown — every threshold, pass/fail criterion, and what an
`ok` vs `not ok` means for triage — is in [docs/test-suite.md](docs/test-suite.md).
Other `nvidia-*` / `amd-*` SKUs are not yet calibrated in the full flow; adding
one, or running an uncalibrated AMD SKU as a one-off, is covered in
[docs/development.md](docs/development.md) and [docs/k8s-standalone.md](docs/k8s-standalone.md).

## Running it — release tarball

Download and extract the latest release, then run `run.sh` for your SKU:

```bash
curl -fsSL \
  "https://github.com/DO-Solutions/gpu-droplet-validation/releases/latest/download/gpu-droplet-validation-latest.tgz" \
  | tar --no-same-owner -xz

sudo ./run.sh --gpu-model nvidia-b300 --gpu-count 8 \
  --node-id my-b300-droplet --region mkc1 --run-id b300-001
```

Swap `--gpu-model` for `amd-mi325x` or `amd-mi350x` to validate those SKUs; the
invocation is otherwise identical. To pin to a specific release, replace
`latest/download` with `download/v1.YYYYMMDD.HHMMSS` and `-latest.tgz` with
`-v1.YYYYMMDD.HHMMSS.tgz`.

What `run.sh` does under the hood — compose stack selection, Docker/toolkit
install, and the per-vendor GPU access path — is in
[docs/how-it-works.md](docs/how-it-works.md).

## Running it — Kubernetes

The suite runs on Kubernetes using the **same images, entrypoints and
`/results` TAP v14 contract** — only the orchestration differs. `run-k8s.sh`
generates one self-contained single-node Job per target node and `kubectl
apply`s it (no Helm); "multi-node" means *N independent single-node Jobs* run
concurrently, with no cross-node coordination. See
[docs/how-it-works.md](docs/how-it-works.md) for the Job structure.

```bash
curl -fsSL \
  "https://github.com/DO-Solutions/gpu-droplet-validation/releases/latest/download/gpu-droplet-validation-latest.tgz" \
  | tar --no-same-owner -xz

# one node
./run-k8s.sh --gpu-model nvidia-b300 --gpu-count 8 \
  --region mkc1 --run-id b300-001 --target-nodes b300-a

# several nodes at once (independent single-node runs)
./run-k8s.sh --gpu-model nvidia-b300 --gpu-count 8 --target-nodes b300-a,b300-b,b300-c

# every node matching a label
./run-k8s.sh --gpu-model nvidia-b300 --gpu-count 8 --node-label nvidia.com/gpu.present=true
```

`run-k8s.sh` fans out one Job per target node, collects each node's TAP from its
`tap-reporter` logs, and preserves the same exit contract aggregated across
nodes: `0` all nodes ran and all ok, `1` some node had a `not ok` point, `255` a
node could not run. Per-node TAP lands in `results/<node>/output.tap`.

GPUs are requested via device-plugin resources (`amd.com/gpu` / `nvidia.com/gpu`);
DOKS installs the GPU device plugins by default, so GPU nodes already advertise
these resources. The Pod tolerates the model's GPU taint **by key**
(`operator: Exists`) — DOKS taints GPU nodes `amd.com/gpu=:NoSchedule` with an
*empty* value, which an `Equal`/`value` toleration would never match — plus the
cordoned-node taint so a cordoned suspect node can still be validated; add
org-specific taints with `--toleration`. ghcr packages are public, so no image
pull secret is needed (`--image-pull-secret` is an optional escape hatch).

### Without the script — one standalone manifest

`run-k8s.sh` is only a generator; the Job it produces is plain YAML.
[`k8s/full-suite-amd.yaml`](k8s/full-suite-amd.yaml) (and its NVIDIA counterpart
[`k8s/full-suite-nvidia.yaml`](k8s/full-suite-nvidia.yaml)) is that exact
manifest checked in, byte-for-byte what `run-k8s.sh ... --print-manifest` emits,
so a customer can validate a node with one `kubectl apply -f` — no script, no
repo checkout. Edit the marked `nodeSelector` hostname / `NODE_ID` / `GPU_MODEL`,
then:

```bash
kubectl apply -f k8s/full-suite-amd.yaml
kubectl logs -f job/gdv-<node> -c tap-reporter   # TAP v14 — primary signal
```

The full walkthrough — retargeting, collecting `/results`, plus the one-off
diagnostic manifests (AMD RVS/RCCL, NVIDIA DCGM/NCCL) — is in
[docs/k8s-standalone.md](docs/k8s-standalone.md).

## stdout / stderr / exit-code contract

- **stdout**: TAP v14 from the tap-reporter, only when the suite ran. If the
  TAP stream contains any `not ok` test points, at least one hardware check
  did not pass. Empty stdout means the suite did not run at all. YAML
  diagnostic blocks (the `---` / `...` indented payload following a test
  point) are emitted **only for `not ok` points** — passing points render as
  a single line. Per-suite JSON in the results dir always contains the full
  diagnostic regardless, for postmortems.
- **stderr**: silent on a successful or failed run. A single error line is
  written **only** when the suite could not run at all (missing prereqs,
  Docker / compose / image-pull failure, bad flags). Any stderr output is
  the signal that the environment is broken; the pass/fail determination
  from stdout is irrelevant in that case.
- **Exit codes**:
  - `0` — suite ran and every TAP test point was `ok`.
  - `1` — suite ran and at least one TAP test point was `not ok`.
  - `255` — suite could not run.

Diagnostic chatter (apt installs, Docker setup, full `docker compose up`
output) is written to `run.log` inside the results dir, never to stderr.

Artifacts (per-suite JSON, debug output, `metadata.json`, `output.tap`,
`tap_exit`, `run.log`) land in `./results` by default — that is, `results/`
relative to the caller's working directory. Pass `--results-dir <path>` to
redirect; relative paths are resolved against the caller's pwd. Containers
always see it mounted as `/results` internally, so the same override flows
through compose.

## More

- [docs/how-it-works.md](docs/how-it-works.md) — what `run.sh`/`run-k8s.sh` do
  under the hood and the per-vendor GPU access path.
- [docs/test-suite.md](docs/test-suite.md) — per-SKU TAP point reference.
- [docs/k8s-standalone.md](docs/k8s-standalone.md) — standalone `kubectl apply` manifests
  and one-off diagnostics (AMD RVS/RCCL, NVIDIA DCGM/NCCL).
- [docs/development.md](docs/development.md) — repo layout, releasing, out-of-band
  base images, test-family run-id dispatch, adding a SKU.
