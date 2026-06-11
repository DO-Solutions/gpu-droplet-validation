# Development

Internals you don't need just to run the suite: how the repo is laid out, how
releases are cut and published, the out-of-band AMD base images, the
test-family run-id dispatch, and how to add a new GPU SKU.

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
  unified tarball (`run.sh` + `run-k8s.sh` + all `compose.*.yaml` + `k8s/`
  + `VERSION`) under one version tag, publishes to GitHub Releases.
- `run-k8s.sh` — Kubernetes entrypoint: generates one single-node Job manifest
  per target node and `kubectl apply`s it (no Helm), same images/results
  contract as compose. Shipped inside the release tarball alongside `run.sh`.
- `k8s/` — standalone `kubectl apply -f` manifests: the calibrated
  full-suite Job (`full-suite-amd.yaml`) plus one-off RVS/RCCL diagnostics.
  See [k8s-standalone.md](k8s-standalone.md).

Images are published to `ghcr.io/do-solutions/gpu-droplet-validation/<name>`
with both `:$VERSION` and `:latest` tags on every release.

## Adding a new GPU SKU

Adding a new NVIDIA SKU is a one-line `case` arm in
[`containers/_lib/nvidia_models.sh`](../containers/_lib/nvidia_models.sh).
Adding a new AMD SKU is one `case` arm in
[`containers/_lib/amd_models.sh`](../containers/_lib/amd_models.sh) **plus** one
vendored conf at `containers/rvs/conf/<gpu-model>/rvs_level_<N>.conf` — nothing
else (no compose or image changes; the same five AMD containers serve every AMD
SKU). The conf directory name **is** the `--gpu-model` value, so
`amd_models.sh` resolves it with no extra mapping.

Other `nvidia-*` and `amd-*` SKUs are not yet implemented in the full flow.
The remaining AMD SKUs (`amd-mi300x`, `amd-mi355x`) ship vendored RVS confs but
have no calibrated RCCL pass/fail floors, so the full `run.sh` flow still fails
fast at `rccl-tests-amd` for them — see [k8s-standalone.md](k8s-standalone.md) for the
one-off RVS path on those SKUs.

## Test-family run-id dispatch

The `test` family is a mock CPU-only stack for integration-testing the harness
itself — no GPU required, so it runs anywhere:

```bash
# release tarball
sudo ./run.sh --gpu-model test --gpu-count 8 \
  --node-id my-droplet --region mkc1 --run-id pass-001

# Kubernetes — validates the k8s path itself on any cluster
./run-k8s.sh --gpu-model test --gpu-count 8 --run-id pass-ci-001
```

For `--gpu-model test`, the prefix of `--run-id` selects the scenario:

| Prefix    | Behavior                                                                    |
| --------- | --------------------------------------------------------------------------- |
| `pass-*`  | TAP v14 with all test points `ok`. Exit 0.                                  |
| `fail-*`  | TAP v14 with at least one `not ok` and a YAML diagnostic. Exit 1.           |
| `error-*` | Prereqs container exits non-zero, no TAP. Script writes stderr. Exit 255.  |

Exit code is derived from `tap_exit` (written by the tap-reporter) when TAP
was produced; `255` is reserved for "the suite could not run at all."

Anything else is treated as `pass-*`.

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

Two prebuilt base images underpin the AMD stack and are **not rebuilt per
release** (they are slow to compile and published out-of-band):
`ghcr.io/do-solutions/rvs-base` (compiled ROCm Validation Suite + ROCm
runtime + amd-smi) and `ghcr.io/do-solutions/rccl-tests` (compiled
rccl-tests). All per-release AMD images `FROM` one of these. `rvs-base` is
built for both `gfx942` (CDNA3: MI300X/MI325X) and `gfx950` (CDNA4:
MI350X/MI355X).

Rebuild them only when the pinned ROCm version changes or the upstream tool
needs a bump. Neither requires an AMD GPU to build — only the ROCm SDK — so
they run on any Docker + buildx host (CI, laptop, build box):

```bash
# ghcr.io/do-solutions/rvs-base:rocm<ver>   (compiled RVS + ROCm + amd-smi)
scripts/build-rvs-base.sh           # --dry-run to preview

# ghcr.io/do-solutions/rccl-tests:rocm<ver> (compiled rccl-tests)
scripts/build-rccl-tests-base.sh    # --dry-run to preview
```

Pinned versions live in each script's header (currently ROCm 7.2.1 — the
production default, required for the MI350X RVS fp4/fp6/bf6 microscaling
actions). After rebuilding, bump the `FROM` tag in the affected
`containers/{rvs,prereqs-amd,setup-amd,teardown-amd,rccl-tests-amd}`
Dockerfiles, then cut a normal release.
