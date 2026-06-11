# How it works

The runtime mechanics behind the two run paths — what the entrypoints do and how
each vendor's GPUs are reached. None of this is needed just to run the suite; see
the [README](../README.md) for that.

## `run.sh` (release tarball)

The tarball ships `run.sh` plus every `compose.*.yaml`. `run.sh`:

- selects the right compose stack from `--gpu-model`;
- installs Docker + the compose plugin if missing (idempotent);
- exports `VERSION` from the tarball's `VERSION` file so compose resolves the
  pinned image tags (falling back to `latest` when unset);
- runs the stack and forwards TAP v14 to stdout.

## NVIDIA GPU access

`run.sh` installs `nvidia-container-toolkit` from NVIDIA's apt repo if missing.
It does **not** run `nvidia-ctk runtime configure` or restart docker — compose
uses the `deploy.resources` device path, which goes through the same OCI
prestart hook as `docker run --gpus all`.

## AMD GPU access

The AMD path needs **no** container toolkit; `run.sh` is a no-op for `amd-*`.
ROCm GPU access is plain `/dev/kfd` + `/dev/dri` device passthrough, wired in
`compose.amd.yaml`.

`amd-mi350x` rides the same five AMD containers as `amd-mi325x`; only the
calibrated floors differ (288 GB HBM3E VRAM gate, higher RCCL busbw floors). The
AMD stack `FROM`s two prebuilt base images published out-of-band — see
[development.md](development.md#out-of-band-base-images-infrequent-amd-only).

## On Kubernetes

`run-k8s.sh` runs the **same images, entrypoints and `/results` TAP v14
contract** as compose — only the orchestration differs. Each targeted node gets
one self-contained **single-node Job**: the serial stages
(prereqs → setup → rvs/dcgm → collectives → teardown) are sequential
`initContainers` sharing an `emptyDir` `/results`, and `tap-reporter` is the
main container. "Multi-node" means *N independent single-node Jobs* run
concurrently — there is no cross-node coordination and no Helm chart;
`run-k8s.sh` generates each Job's YAML and `kubectl apply`s it (the "run.sh of
Kubernetes").
