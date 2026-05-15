# Tests

Per-SKU breakdown of every TAP point emitted by `run.sh`: what each test
checks, what threshold or criterion decides pass/fail, and what `ok` vs
`not ok` actually means in practice.

YAML diagnostic blocks under each TAP point only render on `not ok` —
passing points are a single line. The full per-test diagnostic (including
data attached to passing points) is always preserved in
`results/<suite>.json` for postmortems.

## `--gpu-model nvidia-b300`

Thresholds and expected values come from
[`containers/_lib/nvidia_models.sh`](containers/_lib/nvidia_models.sh).
A clean run emits 21 TAP points across five suites in the order below.

### prereqs (6 points) — `containers/prereqs-nvidia/entrypoint.sh`

A failure in this suite halts the compose stack via `depends_on:
service_completed_successfully`; no downstream suite runs.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `nvidia-smi responds` | `nvidia-smi --query-gpu=name,memory.total` exits 0 and prints something | Driver not loaded, container can't see the runtime, or hardware fault before validation could start. |
| `NVIDIA runtime exposes /dev/nvidia*` | `/dev/nvidia0` or `/dev/nvidiactl` exists inside the container | `nvidia-container-toolkit` didn't inject device nodes; the compose stack would never see the GPUs even if the host can. |
| `nvidia-fabricmanager state (...)` | `nvidia-smi -q` reports Fabric `State` of `Completed` or `InProgress` (or no Fabric block at all on non-NVSwitch SKUs — treated as pass) | NVSwitch fabric did not finish initializing. NVLink traffic across the switch would fall back or fail; subsequent NCCL bandwidth checks would be invalid. |
| `GPU count == 8` | Number of rows from `nvidia-smi --query-gpu=name` equals `--gpu-count` | One or more GPUs missing from the PCIe topology, or `--gpu-count` was wrong for this droplet shape. |
| `All GPUs match model regex /B300/` | Each GPU `name` from `nvidia-smi` matches the regex `B300` | Wrong SKU was provisioned, or a card was swapped. Floors and thresholds below are calibrated for B300 and would not apply. |
| `All GPUs report 275040 MiB memory` | Each GPU's `memory.total` equals 275040 MiB | A GPU has degraded memory visibility — often a sign of failed self-test, partial RMA, or wrong SKU. |

### dcgm-diag (7 points) — `containers/dcgm-diag/`

Runs `dcgmi diag -r "memory,diagnostic,pcie,targeted stress,targeted
power" -p "diagnostic.test_duration=300;targeted_stress.test_duration=600;targeted_power.test_duration=600"`.
The `software` plugin runs unconditionally as a deployment check. Total
DCGM phase ≈ 34 min on 8x B300.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `dcgmi diag exit code == 0` | The `dcgmi diag` process exited 0 | DCGM itself reported overall failure. Belt-and-suspenders: even if per-plugin parsing somehow silently passes, this point still flips on any dcgmi-level failure. |
| `software` | DCGM software-stack deployment plugin: every GPU has a present driver, matching CUDA, NVML responsive, no missing libs. Pass = DCGM reports OK. | Driver/CUDA/NVML mismatch on at least one GPU; environment is not ready for the rest of the suite. The `diagnostic.failed_gpus` field names which GPU and the DCGM-supplied warning text. |
| `diagnostic` | DCGM hardware diagnostic plugin (300s/GPU). Reads PCIe state, ECC counters, NVLink topology; exercises GEMM-class workloads to look for compute errors. Pass = DCGM reports OK. | A per-GPU hardware regression (compute error, NVLink degradation, ECC anomaly) that DCGM flagged. Per-GPU detail under `diagnostic.failed_gpus[]`. |
| `memory` | DCGM memory plugin: allocates ~99% of HBM per GPU, walks pages, checks for ECC events during the walk. Pass = DCGM reports OK. | HBM has a fault that surfaces under stress: page maps unusable, or the allocation triggered uncorrectable errors. |
| `pcie` | DCGM PCIe plugin: peer-to-peer bandwidth and latency between GPUs, link-state transitions. Pass = DCGM reports OK. | PCIe link is in a bad state (downgraded width/speed) or P2P transfers fail between specific pairs. NCCL allreduce below will likely also fail. |
| `targeted_power` | DCGM sustained-power plugin (600s/GPU). Drives each GPU near TDP and verifies power telemetry stays in spec. Pass = DCGM reports OK. | GPU could not sustain target power, throttled, or telemetry reported out-of-spec. Usually correlates with thermal or VRM faults. |
| `targeted_stress` | DCGM sustained-compute stress plugin (600s/GPU). Long-running GEMM-class load checking for correctness drift, hangs, or thermal excursions. Pass = DCGM reports OK. | The most common signal for "this GPU passes a quick check but fails under sustained load." Often the only test that catches marginal HBM or VRM issues. |

When a dcgm plugin fails, `diagnostic.failed_gpus[]` lists only the
specific GPUs that failed, with their per-GPU status and any
`warnings` / `info` strings DCGM emitted. The passing GPUs are not
echoed in the TAP diagnostic.

### nccl-allreduce (2 points) — `containers/nccl-tests-nvidia/entrypoint.sh`

Runs NCCL `all_reduce_perf -b 32K -e 8G -f 2 -g 8 -w 5 -n 20`, best of 3
runs (selected by highest average bus bandwidth). Concurrently captures
`nvidia-smi dmon` to `results/nccl-allreduce_dmon.log`.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `NCCL allreduce busbw@8GB >= 810 GB/s` | In-place bus bandwidth at the 8 GiB message size from the best of 3 runs is at least **810 GB/s** | This is the headline B300 collective-bandwidth floor. Below it means the GPU complex is not delivering the bandwidth a customer paying for a B300 expects — most often a fabric, NVLink, or PCIe regression. The diagnostic block includes `busbw_8g_GBps`, `best_avg_busbw_GBps`, and a `per_size_table` of 8 MB / 64 MB / 1 GB / 8 GB rows for triage. |
| `NCCL transport is NVLink (no PIX/SYS/PHB)` | All four must hold: (a) every rank logged `isAllDirectP2p 1 directMode 1 isAllCudaP2p 1`; (b) the count of those lines is `== GPU_COUNT`; (c) `NVLS multicast support is available on dev N` appeared at least `GPU_COUNT` times; (d) no `Falling back to`, `Cannot use P2P`, `cannot enable peer access`, or `disabling P2P` lines in the NCCL debug log | NCCL silently fell back to a slower transport (PIX/SYS/PHB). The busbw number above could be technically passing while still indicating a topology bug; this point is the independent transport assertion. The diagnostic lists which signals failed and the offending log lines. |

### nccl-alltoall (1 point) — same container, `NCCL_TEST=alltoall`

Runs `alltoall_perf -b 32K -e 8G -f 2 -g 8 -w 5 -n 20` once.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `NCCL alltoall_perf exit code == 0` | The binary exited 0 | The alltoall collective could not complete at all (hang, abort, illegal memory access). No SKU-specific bandwidth floor here — failure mode for alltoall on this hardware is binary; bandwidth regressions in allreduce already gate the suite. |

### post-health (5 points) — `containers/teardown-nvidia/entrypoint.sh`

Compares the post-test machine state against a baseline captured by
`setup-nvidia` before dcgm-diag/NCCL ran. Designed to catch silent
regressions induced by the stress phases.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `No new correctable ECC errors` | `ecc.errors.corrected.volatile.total` summed across all GPUs is unchanged from baseline | The stress phases triggered correctable ECC events. By definition the data was recovered, but a non-zero delta is an early warning of degrading memory. |
| `No new uncorrectable ECC errors` | `ecc.errors.uncorrected.volatile.total` summed across all GPUs is unchanged from baseline | An uncorrectable ECC event occurred during the run. The affected memory is now considered unreliable; this GPU should be quarantined regardless of whether dcgm-diag also flagged it. |
| `No new Xid errors in dmesg` | Count of `NVRM: Xid` lines in `dmesg -T` is `<=` baseline count | A kernel-level NVIDIA driver fault fired during the run (Xid). The new Xid lines are included in the diagnostic verbatim so the specific Xid number can be looked up. |
| `No thermal throttling observed` | No `(HW\|SW) (Thermal )?Slowdown : Active` line appears in `nvidia-smi -q -d PERFORMANCE` at post-test time | The card is currently throttling, i.e. the cooling envelope is insufficient at idle/cooldown — typically a fan or thermal-paste failure, not a software issue. |
| `Row remap status clean` | `nvidia-smi -q -d ROW_REMAPPER` reports `Pending: No` and `Remapping Failure Occurred: No` on every GPU | HBM row remapping is pending or has failed. Pending = remap will happen on next reboot; failed = the GPU has run out of spare rows. Either way the card has memory damage. |

## Reading a TAP failure

The TAP stream and `results/output.tap` show one line per test point. On
a failure, the indented block under that line is the diagnostic — the
key/value pairs come straight from the per-suite JSON. For deeper
investigation:

- `results/run.log` — full `run.sh` + compose stdout/stderr.
- `results/<suite>.json` — full diagnostic for every test in the suite,
  including the passing points whose diagnostics were elided from TAP.
- `results/dcgm-diag_raw.json` — verbatim `dcgmi diag -j` output.
- `results/nccl-allreduce_debug.log` — NCCL `NCCL_DEBUG=INFO` topology
  capture (consult when transport / NVLink points fail).
- `results/nccl-allreduce_best.log`, `results/nccl-alltoall_run.log` —
  raw nccl-tests perf-run output.
- `results/nccl-allreduce_dmon.log`, `results/nccl-alltoall_dmon.log` —
  `nvidia-smi dmon` samples (SM/util/mem/power) over the run window.
