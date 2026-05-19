# gpu-droplet-validation

Entrypoint + container stack for the GPU droplet validation PoC. Cloud-init
(or a human) extracts a release tarball onto a Droplet, runs `run.sh`, and
gets TAP v14 on stdout plus artifacts in `./results` (override with
`--results-dir <path>`).

## Families

| `--gpu-model`  | Status                                                       |
| -------------- | ------------------------------------------------------------ |
| `test`         | Mock CPU-only stack used for integration testing             |
| `nvidia-b300`  | Real B300 SXM6 stack: prereqs + setup + `dcgmi diag -r 3` + NCCL allreduce/alltoall + post-health |
| `amd-mi325x`   | Real MI325X stack: prereqs + setup + `rvs -c <conf> -d 3` (level 4) + RCCL allreduce/alltoall + post-health |

Other `nvidia-*` and `amd-*` SKUs are not yet implemented. Adding a new
NVIDIA SKU is a one-line `case` arm in `containers/_lib/nvidia_models.sh`.
Adding a new AMD SKU is one `case` arm in
`containers/_lib/amd_models.sh` **plus** one vendored conf at
`containers/rvs/conf/<gpu-model>/rvs_level_4.conf` — nothing else (no
compose or image changes; the same five AMD containers serve every AMD SKU).

See [TESTS.md](TESTS.md) for the per-SKU breakdown of every TAP point —
threshold, pass/fail criterion, and what an `ok` vs `not ok` result
actually means for triage.

### nvidia-b300 example

```bash
curl -fsSL \
  "https://github.com/DO-Solutions/gpu-droplet-validation/releases/latest/download/gpu-droplet-validation-latest.tgz" \
  | tar --no-same-owner -xz
sudo ./run.sh \
  --gpu-model nvidia-b300 \
  --gpu-count 8 \
  --node-id   my-b300-droplet \
  --region    mkc1 \
  --run-id    b300-001
```

`run.sh` installs `nvidia-container-toolkit` from NVIDIA's apt repo if
missing (it does **not** run `nvidia-ctk runtime configure` or restart
docker — compose uses the `deploy.resources` device path, which goes through
the same OCI prestart hook as `docker run --gpus all`).

### amd-mi325x example

```bash
curl -fsSL \
  "https://github.com/DO-Solutions/gpu-droplet-validation/releases/latest/download/gpu-droplet-validation-latest.tgz" \
  | tar --no-same-owner -xz
sudo ./run.sh \
  --gpu-model amd-mi325x \
  --gpu-count 8 \
  --node-id   my-mi325x-droplet \
  --region    mkc1 \
  --run-id    mi325x-001
```

The AMD path needs **no** container toolkit — `run.sh` is a no-op for
`amd-*` (ROCm GPU access is plain `/dev/kfd` + `/dev/dri` device
passthrough wired in `compose.amd.yaml`, unlike
`nvidia-container-toolkit`).

Two prebuilt base images underpin the AMD stack and are **not rebuilt per
release** (they are slow to compile and published out-of-band by
`scripts/build-rvs-base.sh` and `scripts/build-rccl-tests-base.sh`):
`ghcr.io/do-solutions/rvs-base` (compiled ROCm Validation Suite + ROCm
runtime + amd-smi) and `ghcr.io/do-solutions/rccl-tests` (compiled
rccl-tests). All per-release AMD images `FROM` one of these.

## Bootstrap (cloud-init / manual)

```bash
curl -fsSL \
  "https://github.com/DO-Solutions/gpu-droplet-validation/releases/latest/download/gpu-droplet-validation-latest.tgz" \
  | tar --no-same-owner -xz
sudo ./run.sh \
  --gpu-model test \
  --gpu-count 8 \
  --node-id   my-droplet \
  --region    mkc1 \
  --run-id    pass-001
```

The tarball ships `run.sh` plus every `compose.*.yaml`; `run.sh` selects the
right compose stack from `--gpu-model`.

To pin to a specific release, replace `latest/download` with
`download/v1.YYYYMMDD.HHMMSS` and `-latest.tgz` with
`-v1.YYYYMMDD.HHMMSS.tgz`.

`run.sh` installs Docker + compose plugin if missing (idempotent), exports
`VERSION` from the tarball's `VERSION` file so compose resolves pinned image
tags, runs the stack, and forwards TAP to stdout.

### stdout / stderr / exit-code contract

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

## Test-family run-id dispatch

For `--gpu-model test`, the prefix of `--run-id` selects the scenario:

| Prefix    | Behavior                                                                    |
| --------- | --------------------------------------------------------------------------- |
| `pass-*`  | TAP v14 with all test points `ok`. Exit 0.                                  |
| `fail-*`  | TAP v14 with at least one `not ok` and a YAML diagnostic. Exit 1.           |
| `error-*` | Prereqs container exits non-zero, no TAP. Script writes stderr. Exit 255.  |

Exit code is derived from `tap_exit` (written by the tap-reporter) when TAP
was produced; `255` is reserved for "the suite could not run at all."

Anything else is treated as `pass-*`.

## Kubernetes path

The suite also runs on Kubernetes using the **same images, entrypoints and
`/results` TAP v14 contract** — only the orchestration differs. Each targeted
node gets one self-contained **single-node Job**: the serial stages
(prereqs → setup → rvs/dcgm → collectives → teardown) are sequential
`initContainers` sharing an `emptyDir` `/results`, and `tap-reporter` is the
main container. "Multi-node" means *N independent single-node Jobs* run
concurrently — there is no cross-node coordination.

GPUs are requested via device-plugin resources (`amd.com/gpu` /
`nvidia.com/gpu`), so the **AMD GPU device plugin** (or NVIDIA GPU operator)
must already be installed on the GPU nodes. The Pod tolerates the model's GPU
taint (`amd.com/gpu=true:NoSchedule` etc.) and the cordoned-node taint
(`node.kubernetes.io/unschedulable`) so a suspect node that has been cordoned
can still be validated; add org-specific taints with `--toleration`.

```bash
curl -fsSL \
  "https://github.com/DO-Solutions/gpu-droplet-validation/releases/latest/download/gpu-droplet-validation-latest.tgz" \
  | tar --no-same-owner -xz

# one node
./run-k8s.sh --gpu-model amd-mi325x --gpu-count 8 \
  --region mkc1 --run-id mi325x-001 --target-nodes mi325x-a

# several nodes at once (independent single-node runs)
./run-k8s.sh --gpu-model amd-mi325x --gpu-count 8 --target-nodes mi325x-a,mi325x-b,mi325x-c

# every node matching a label
./run-k8s.sh --gpu-model amd-mi325x --gpu-count 8 --node-label gpu.amd.com/present=true

# CPU-only mock — validates the k8s path itself on any cluster
./run-k8s.sh --gpu-model test --gpu-count 8 --run-id pass-ci-001
```

`run-k8s.sh` preserves run.sh's exit contract aggregated across nodes: `0`
all nodes ran and all ok, `1` some node had a `not ok` point, `255` a node
could not run. Per-node TAP lands in `results/<node>/output.tap`. The Helm
chart lives at `helm/` in the tarball (source: `deploy/helm/gpu-droplet-validation/`).

If the AMD GPU device plugin does not inject `/dev/kfd` + `/dev/dri` (the
`prereqs-amd` check hard-fails), set `--set rawDeviceFallback=true` (or the
chart value) to hostPath-mount the device nodes exactly like compose. Verify
device-plugin sufficiency first with a one-off `amd.com/gpu`-only pod:
`ls -l /dev/kfd /dev/dri && amd-smi list`.

ghcr packages are public, so no image pull secret is needed; `imagePullSecret`
is an optional, default-off escape hatch only if they are ever made private.

## Layout

- `run.sh` — entrypoint, shipped inside the release tarball.
- `compose.<family>.yaml` — compose stack per family. Image tags use
  `${VERSION:-latest}` so the pinned version from the tarball is used when
  available and `latest` otherwise.
- `containers/<role>-<family>/` — per-family container image sources.
- `containers/tap-reporter/` — shared, vendor-agnostic TAP v14 reporter.
- `containers/_lib/result.sh` — shell helpers (`log`, `die`,
  `write_result_json`) sourced by each entrypoint.
- `scripts/release.sh` — builds + pushes every image and packages a single
  unified tarball (`run.sh` + `run-k8s.sh` + all `compose.*.yaml` + `helm/` +
  `VERSION`) under one version tag, publishes to GitHub Releases.
- `scripts/run-k8s.sh` — Kubernetes entrypoint (Helm chart driver), shipped
  inside the release tarball alongside `run.sh`.
- `deploy/helm/gpu-droplet-validation/` — Helm chart for the k8s path; one
  single-node Job per target node, same images/results contract as compose.

Images are published to `ghcr.io/do-solutions/gpu-droplet-validation/<name>`
with both `:$VERSION` and `:latest` tags on every release.

## Releasing

```bash
# Automated: v1.YYYYMMDD.HHMMSS with everything tagged + uploaded in lockstep.
scripts/release.sh

# Dry-run (prints planned commands, no push):
scripts/release.sh --dry-run

# Explicit version:
scripts/release.sh --version v1.20260424.120000
```

One release builds and publishes every container and a single unified
tarball together; there is no partial per-family release.

### Out-of-band base images (infrequent, AMD only)

The AMD stack depends on two prebuilt base images that are **not** part of
the normal release because the RVS / rccl-tests compiles are slow. Rebuild
them only when the pinned ROCm version changes or the upstream tool needs a
bump. Neither requires an AMD GPU to build — only the ROCm SDK — so they
run on any Docker + buildx host (CI, laptop, build box):

```bash
# ghcr.io/do-solutions/rvs-base:rocm<ver>   (compiled RVS + ROCm + amd-smi)
scripts/build-rvs-base.sh           # --dry-run to preview

# ghcr.io/do-solutions/rccl-tests:rocm<ver> (compiled rccl-tests)
scripts/build-rccl-tests-base.sh    # --dry-run to preview
```

Pinned versions live in each script's header (currently ROCm 7.0.2 to
match the MI325X droplet). After rebuilding, bump the `FROM` tag in the
affected `containers/{rvs,prereqs-amd,setup-amd,teardown-amd,rccl-tests-amd}`
Dockerfiles, then cut a normal release.

     