FROM nvidia/cuda:12.8.1-base-ubuntu24.04

# Install DCGM (datacenter-gpu-manager-4) from NVIDIA's CUDA apt repo, which is
# already configured in the CUDA base image. The -cuda-all variant ships
# plugins for cuda11/cuda12/cuda13; DCGM picks the right plugin dir at runtime
# based on the host driver's reported CUDA capability. The earlier -cuda12
# variant fails on B300 hosts (driver 590 / CUDA 13) with
#   "Cannot load plugins. Unable to change to the plugin dir
#    '/usr/libexec/datacenter-gpu-manager-4/plugins/cuda13/'"
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash jq ca-certificates libnuma1 datacenter-gpu-manager-4-cuda-all \
 && rm -rf /var/lib/apt/lists/*

# libnuma1: required by DCGM's PCIe / NVBandwidth plugins. Without it, dcgmi
# reports the plugin as failed with
#   "The libnuma library cannot be found. Install the libnuma1 package
#    to resolve this issue."
# and the overall dcgmi exit code is 226 even when every other plugin passes.

COPY containers/_lib/result.sh /lib/result.sh
COPY containers/_lib/nvidia_models.sh /lib/nvidia_models.sh
COPY containers/dcgm-diag/entrypoint.sh /entrypoint.sh
COPY containers/dcgm-diag/parse.jq /parse.jq
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
