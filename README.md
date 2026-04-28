# gpu-droplet-validation

Entrypoint + container stack for the GPU droplet validation PoC. Cloud-init
(or a human) extracts a release tarball onto a Droplet, runs `run.sh`, and
gets TAP v14 on stdout plus artifacts in `./results` (override with
`--results-dir <path>`).

## Families

| `--gpu-model` | Status                                                                |
| ------------- | --------------------------------------------------------------------- |
| `test-pass`   | Mock CPU-only stack, all-pass scenario (integration testing)          |
| `test-fail`   | Mock CPU-only stack, fail scenario (TAP `not ok` + diagnostic)        |
| `test-error`  | Mock CPU-only stack, prereqs-error scenario (no TAP, exit 255)        |

Real `nvidia` and `amd` suites are not yet implemented.

The test family is split into three distinct `--gpu-model` values rather
than a single `test` value with run-id-prefix dispatch. This keeps caller
integration trivial — auto-ahoy and similar systems only have to pass a
literal flag value, never parse a substring of `--run-id`. `--run-id`
itself is treated purely as a free-form trace ID by all gpu-models.

## Bootstrap (cloud-init / Auto-ahoy / manual)

```bash
curl -fsSL \
  "https://github.com/DO-Solutions/gpu-droplet-validation/releases/latest/download/gpu-droplet-validation-latest.tgz" \
  | tar -xz
sudo ./run.sh \
  --gpu-model test-pass \
  --gpu-count 8 \
  --node-id   my-droplet \
  --region    mkc1 \
  --run-id    my-trace-001
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
  did not pass. Empty stdout means the suite did not run at all.
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

## Test-family scenario dispatch

The scenario is selected by the `--gpu-model` value itself — `--run-id` is
not parsed by any container. Auto-ahoy (and any other caller) only needs to
pass a literal `--gpu-model` value:

| `--gpu-model` | Behavior                                                                    |
| ------------- | --------------------------------------------------------------------------- |
| `test-pass`   | TAP v14 with all test points `ok`. Exit 0.                                  |
| `test-fail`   | TAP v14 with at least one `not ok` and a YAML diagnostic. Exit 1.           |
| `test-error`  | Prereqs container exits non-zero, no TAP. Script writes stderr. Exit 255.  |

Exit code is derived from `tap_exit` (written by the tap-reporter) when TAP
was produced; `255` is reserved for "the suite could not run at all."

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

     