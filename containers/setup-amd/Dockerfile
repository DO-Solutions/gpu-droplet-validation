# FROM rvs-base for the ROCm stack + amd-smi used to snapshot ECC/RAS state.
FROM ghcr.io/do-solutions/rvs-base:rocm7.2.1
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY containers/_lib/result.sh /lib/result.sh
COPY containers/_lib/amd_models.sh /lib/amd_models.sh
COPY containers/setup-amd/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
