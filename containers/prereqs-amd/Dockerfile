# FROM rvs-base: it already carries the full ROCm stack + amd-smi, so prereqs
# can probe the GPUs with the same toolchain the rest of the AMD suite uses.
FROM ghcr.io/do-solutions/rvs-base:rocm7.0.2
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY containers/_lib/result.sh /lib/result.sh
COPY containers/_lib/amd_models.sh /lib/amd_models.sh
COPY containers/prereqs-amd/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
