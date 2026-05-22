# examples/

One-off, manual ways to drive the validation containers **outside** the
official `run.sh` / compose flow. These are for exercising GPU types or RVS
levels we do not yet fully validate. They are **not** the calibrated
validation path — the official flow is `amd-mi325x` at RVS level 4 only,
and there are **no pass/fail floors** for the other SKUs. The signal here is
the raw RVS `[RESULT]` stream and end-of-run summary table in the logs.

## `rvs-mi350x-level5.yaml` — RVS level-5 soak on one MI350X node

A standalone Kubernetes Pod that runs the `rvs` container's vendored
`rvs_level_5.conf` for MI350X. Modeled on `scratch/rccl.yaml`.

```bash
kubectl apply -f examples/rvs-mi350x-level5.yaml
kubectl wait --for=condition=Ready pod/rvs-mi350x-level5 --timeout=5m
kubectl logs -f pod/rvs-mi350x-level5            # primary signal (RVS tees to stdout)

# optional — pull the artifacts the full flow's parser would consume:
kubectl cp rvs-mi350x-level5:/results/rvs.json ./rvs.json
kubectl cp rvs-mi350x-level5:/results/rvs.log  ./rvs.log

kubectl delete -f examples/rvs-mi350x-level5.yaml
```

Before applying, set **`nodeSelector.kubernetes.io/hostname`** and the
**`NODE_ID`** env to your actual MI350X node.

### Retargeting to another SKU / level

The one manifest covers every vendored combination — edit two env vars:

| env | values |
|-----|--------|
| `GPU_MODEL` | `amd-mi300x` · `amd-mi325x` · `amd-mi350x` · `amd-mi355x` |
| `RVS_LEVEL` | `4` (default, ~minutes) · `5` (long soak, hours) |

The image vendors `containers/rvs/conf/<GPU_MODEL>/rvs_level_<RVS_LEVEL>.conf`;
`amd_models.sh` resolves it from these two vars.

### Level 4 vs level 5

Level 5 is a long-duration soak of the same actions, not new ones:

- Most actions: ~10 s → ~900 s (≈90×).
- PCIe / xGMI bandwidth: ~30 s → ~900 s.
- `power-stress` (IET): ~60 s → ~3600 s.
- Iterations scale up too (e.g. babel `num_iter` 100 → 10000, `memtest`
  count 1 → 20).

So a full level-5 run takes **hours**. The manifest sets
`RVS_TIMEOUT=43200` (12 h) — the entrypoint's default 1800 s would kill a
level-5 run almost immediately. Lower it for a deliberately partial soak.

### Why this is one-off only

`amd-mi300x/350x/355x` have RVS-only arms in
`containers/_lib/amd_models.sh`: they resolve `RVS_CONF` but set no RCCL
floors and disable the VRAM gate, so the full `run.sh` flow still fails fast
for them. Only `amd-mi325x` (level 4) is calibrated end to end. The vendored
confs are mirrored verbatim from upstream
`ROCmValidationSuite/rvs/conf/<MODEL>/levels/`.
