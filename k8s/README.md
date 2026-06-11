# k8s/

Standalone Kubernetes manifests you can `kubectl apply -f` directly — no
script, no repo checkout. Send a customer one file and they can validate a node.

| Manifest | What it is |
| --- | --- |
| [`full-suite-amd.yaml`](full-suite-amd.yaml) | Full AMD validation suite as one self-contained Job (prereqs → setup → rvs → RCCL → teardown). Byte-for-byte what `run-k8s.sh --gpu-model amd-mi350x … --print-manifest` emits. Calibrated pass/fail verdict. |
| [`full-suite-nvidia.yaml`](full-suite-nvidia.yaml) | NVIDIA counterpart (`nvidia-b300`): prereqs → setup → dcgm-diag → NCCL → teardown. |
| [`rvs-mi350x-level5.yaml`](rvs-mi350x-level5.yaml) | One-off RVS diagnostic Pod (any AMD SKU / level via `GPU_MODEL` + `RVS_LEVEL`). Not the calibrated path — no pass/fail floors. |
| [`rccl-allreduce-adhoc.yaml`](rccl-allreduce-adhoc.yaml) | One-off RCCL allreduce Pod (runs the binary directly, no floor gate). |
| [`dcgm-b300-adhoc.yaml`](dcgm-b300-adhoc.yaml) | One-off DCGM diag Pod (`nvidia-b300`): runs just the dcgm-diag stage standalone. |
| [`nccl-allreduce-adhoc.yaml`](nccl-allreduce-adhoc.yaml) | One-off NCCL allreduce Pod (runs the binary directly, no floor gate). |

Each file's header comment documents the `CHANGEME` edits (nodeSelector
hostname, `NODE_ID`, `metadata.name`, SKU/GPU count). For the full how-to —
applying, retargeting, collecting `/results`, level 4 vs 5, and which SKUs are
calibrated — see [`../docs/k8s-standalone.md`](../docs/k8s-standalone.md).
