# Base image is upstream NVIDIA's nccl-tests, mirrored into the do-solutions
# ghcr org as-is — NOT built by this repo (no Dockerfile/build script exists
# for it; it is excluded from scripts/release.sh by design). The tag is
# upstream's own scheme: <cuda>-devel-ubuntu<ver>-nccl<ver>-<n>-<gitsha>.
# To refresh: docker pull the desired tag from upstream nvidia/nccl-tests,
# then re-push to ghcr.io/do-solutions/nccl-tests (same out-of-band pattern
# as scripts/build-rccl-tests-base.sh on the AMD side).
FROM ghcr.io/do-solutions/nccl-tests:13.1.1-devel-ubuntu24.04-nccl2.29.7-1-7112046
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash jq ca-certificates procps \
 && rm -rf /var/lib/apt/lists/*
COPY containers/_lib/result.sh /lib/result.sh
COPY containers/_lib/nvidia_models.sh /lib/nvidia_models.sh
COPY containers/nccl-tests-nvidia/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
