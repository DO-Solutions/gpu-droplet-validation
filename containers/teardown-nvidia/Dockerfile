FROM nvidia/cuda:12.8.1-base-ubuntu24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash jq ca-certificates util-linux \
 && rm -rf /var/lib/apt/lists/*
COPY containers/_lib/result.sh /lib/result.sh
COPY containers/_lib/nvidia_models.sh /lib/nvidia_models.sh
COPY containers/teardown-nvidia/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
