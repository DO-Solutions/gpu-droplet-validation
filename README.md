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
| `amd-mi325x`   | Real MI325X stack: prereqs + setup + `rvs -c <conf>` (level 4) + RCCL allreduce/alltoall + post-health |
| `amd-mi350x`   | Real MI350X stack: prereqs + setup + `rvs -c <conf>` (level 4) + RCCL allreduce/alltoall + post-health |

Other `nvidia-*` and `amd-*` SKUs are not yet implemented in the full flow.
Adding a new NVIDIA SKU is a one-line `case` arm in
`containers/_lib/nvidia_models.sh`. Adding a new AMD SKU is one `case` arm
in `containers/_lib/amd_models.sh` **plus** one vendored conf at
`containers/rvs/conf/<gpu-model>/rvs_level_<N>.conf` — nothing else (no
compose or image changes; the same five AMD containers serve every AMD SKU).

### RVS standalone (one-off)

Separate from the full flow above, the `rvs` container can run RVS by
itself for AMD GPU types we do not yet fully validate. The vendored conf
tree ships **levels 4 and 5** for **MI300X, MI325X, MI350X, MI355X**
(mirrored verbatim from upstream
`ROCmValidationSuite/rvs/conf/<MODEL>/levels/`):

| `GPU_MODEL`   | level 4 (default) | level 5 (long soak, hours) |
| ------------- | :---------------: | :------------------------: |
| `amd-mi300x`  | ✔ | ✔ |
| `amd-mi325x`  | ✔ | ✔ |
| `amd-mi350x`  | ✔ | ✔ |
| `amd-mi355x`  | ✔ | ✔ |

Select with `GPU_MODEL` + `RVS_LEVEL` (default `4`); `rvs-base` is built
for both `gfx942` (CDNA3: MI300X/MI325X) and `gfx950` (CDNA4:
MI350X/MI355X). This is **one-off only** — the official `run.sh`/compose
flow is calibrated for **`amd-mi325x` and `amd-mi350x` (level 4)**, while the
remaining SKUs (`amd-mi300x`, `amd-mi355x`) have no calibrated pass/fail
floors (the RVS log is the signal). Running the full flow on an uncalibrated
SKU still fails fast at `rccl-tests-amd` (unset floor). See
[`examples/`](examples/) for a ready-to-run Kubernetes manifest (level 5 on
an MI350X node).

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

### amd-mi350x example

```bash
curl -fsSL \
  "https://github.com/DO-Solutions/gpu-droplet-validation/releases/latest/download/gpu-droplet-validation-latest.tgz" \
  | tar --no-same-owner -xz
sudo ./run.sh \
  --gpu-model amd-mi350x \
  --gpu-count 8 \
  --node-id   my-mi350x-droplet \
  --region    mkc1 \
  --run-id    mi350x-001
```

`amd-mi350x` rides the same five AMD containers and device-passthrough path
as `amd-mi325x` (no container toolkit); only the calibrated floors differ
(288 GB HBM3E VRAM gate, higher RCCL busbw floors — MI350X is ~24%/16%
faster than MI325X on allreduce/alltoall). MI350X (CDNA4, `gfx950`) runs the
`rvs-base`/`rccl-tests` images built for that arch.

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
  unified tarball (`run.sh` + all `compose.*.yaml` + `VERSION`) under one
  version tag, publishes to GitHub Releases.

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

Pinned versions live in each script's header (currently ROCm 7.2.1 — the
production default, required for the MI350X RVS fp4/fp6/bf6 microscaling
actions). After rebuilding, bump the `FROM` tag in the
affected `containers/{rvs,prereqs-amd,setup-amd,teardown-amd,rccl-tests-amd}`
Dockerfiles, then cut a normal release.

     