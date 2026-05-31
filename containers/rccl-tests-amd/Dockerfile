# FROM the prebuilt rccl-tests base image. rccl-tests is built once and
# pushed by scripts/build-rccl-tests-base.sh (mirrors the nccl-tests-nvidia
# base-image pattern); it is not rebuilt during a normal release. Keep the
# tag's ROCm/RCCL versions in sync with the target droplet (see that script's
# header for the pinned versions).
FROM ghcr.io/do-solutions/rccl-tests:rocm7.2.1
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash jq ca-certificates procps \
 && rm -rf /var/lib/apt/lists/*
COPY containers/_lib/result.sh /lib/result.sh
COPY containers/_lib/amd_models.sh /lib/amd_models.sh
COPY containers/rccl-tests-amd/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
