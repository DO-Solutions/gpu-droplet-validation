# RVS suite container. FROM the prebuilt rvs-base image, which already
# carries the compiled ROCm Validation Suite + the full ROCm runtime
# (HIP/HSA/rocBLAS/hipBLASLt) + amd-smi. The RVS binary is slow to compile,
# so it is built once into rvs-base by scripts/build-rvs-base.sh and never
# rebuilt during a normal release. Keep the ROCm version tag in sync with
# the target droplet's ROCm (MI325X run log: ROCm 7.0.2 / amdgpu 6.14.14).
FROM ghcr.io/do-solutions/rvs-base:rocm7.2.1

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY containers/_lib/result.sh /lib/result.sh
COPY containers/_lib/amd_models.sh /lib/amd_models.sh
COPY containers/rvs/entrypoint.sh /entrypoint.sh
COPY containers/rvs/parse.sh /parse.sh
# Vendor the ENTIRE per-SKU conf tree so every current and future AMD SKU's
# conf ships in this one image; amd_models.sh resolves the right one from
# $GPU_MODEL (directory name == --gpu-model value). No runtime dependency
# on any external ROCm clone.
COPY containers/rvs/conf/ /rvs/conf/
RUN chmod +x /entrypoint.sh /parse.sh
ENTRYPOINT ["/entrypoint.sh"]
