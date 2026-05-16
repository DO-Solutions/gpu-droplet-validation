# FROM rvs-base for the ROCm stack + amd-smi used to diff post-test state.
FROM ghcr.io/do-solutions/rvs-base:rocm7.0.2
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash jq ca-certificates util-linux \
 && rm -rf /var/lib/apt/lists/*
COPY containers/_lib/result.sh /lib/result.sh
COPY containers/_lib/amd_models.sh /lib/amd_models.sh
COPY containers/teardown-amd/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
