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
