# gpu-droplet-validation

Entrypoint + container stack for the GPU droplet validation PoC. Cloud-init
(or a human) extracts a release tarball onto a Droplet, runs `run.sh`, and
gets TAP v14 on stdout plus artifacts in `./results` (override with
`--results-dir <path>`).

## Families

| `--gpu-model` | Status                                                     |
| ------------- | ---------------------------------------------------------- |
| `test`        | Mock CPU-only stack used for integration testing           |

Real `nvidia` and `amd` suites are not yet implemented.

## Bootstrap (cloud-init / Auto-ahoy / manual)

```bash
curl -fsSL \
  "https://github.com/DO-Solutions/gpu-droplet-validation/releases/latest/download/gpu-droplet-validation-latest.tgz" \
  | tar -xz
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
tags, runs the stack, and forwards TAP to stdout. Errors go to stderr.

Artifacts (per-suite JSON, debug output, `metadata.json`, `output.tap`) land
in `./results` by default — that is, `results/` relative to the caller's
working directory. Pass `--results-dir <path>` to redirect; relative paths
are resolved against the caller's pwd. Containers always see it mounted as
`/results` internally, so the same override flows through compose.

## Test-family run-id dispatch

For `--gpu-model test`, the prefix of `--run-id` selects the scenario:

| Prefix    | Behavior                                                                      |
| --------- | ----------------------------------------------------------------------------- |
| `pass-*`  | TAP v14 with all test points `ok`. Exit 0.                                    |
| `fail-*`  | TAP v14 with at least one `not ok` and a YAML diagnostic. Exit 0.             |
| `error-*` | Prereqs container exits non-zero, no TAP. Script writes stderr. Exit non-0.   |

The pass/fail signal for individual tests lives in the TAP stream; `run.sh`
exits 0 whenever the suite produced TAP output. Non-zero exit is reserved
for "the suite could not run at all."

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

     