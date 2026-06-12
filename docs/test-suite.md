# Tests

Per-SKU breakdown of every TAP point emitted by `run.sh`: what each test
checks, what threshold or criterion decides pass/fail, and what `ok` vs
`not ok` actually means in practice.

YAML diagnostic blocks under each TAP point only render on `not ok` —
passing points are a single line. The full per-test diagnostic (including
data attached to passing points) is always preserved in
`results/<suite>.json` for postmortems.

The TAP point set is **identical** between the Docker Compose path (`run.sh`)
and the Kubernetes path (`run-k8s.sh`) — same entrypoints, same
`tap-reporter`. One k8s-only caveat: on a hard prereqs/setup/rvs failure the
in-pod `tap-reporter` (the Job's main container) never runs, so instead of an
emitted TAP doc `run-k8s.sh` reports a synthetic single `not ok` for that node
and exit `255` ("could not run"), capturing the failing stage's logs under
`results/<node>/`. Soft (perf-floor) failures behave exactly as in compose:
real TAP with `not ok` points and exit `1`.

## `--gpu-model nvidia-b300`

Thresholds and expected values come from
[`containers/_lib/nvidia_models.sh`](../containers/_lib/nvidia_models.sh).
A clean run emits 20 TAP points across five suites in the order below.

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

### dcgm-diag (6 points) — `containers/dcgm-diag/`

Runs `dcgmi diag -r "memory,diagnostic,targeted stress,targeted
power" -p "diagnostic.test_duration=300;targeted_stress.test_duration=600;targeted_power.test_duration=600"`.
The `software` plugin runs unconditionally as a deployment check. Total
DCGM phase ≈ 29 min on 8x B300 (measured per-plugin: software ~30 s,
diagnostic ~5 min, memory ~3 min, targeted_stress ~10 min,
targeted_power ~10 min). The `pcie` plugin is deliberately *not* run —
in isolation it took ~47 min on 8x B300 and dominated the entire phase;
its GPU↔GPU bandwidth/latency signal is covered better by the NCCL
allreduce busbw floor + transport assertion below, which exercise the
fabric with the real collective workload. See
[`nvidia_models.sh`](../containers/_lib/nvidia_models.sh) for the full
rationale and measured numbers.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `dcgmi diag exit code == 0` | The `dcgmi diag` process exited 0 | DCGM itself reported overall failure. Belt-and-suspenders: even if per-plugin parsing somehow silently passes, this point still flips on any dcgmi-level failure. |
| `software` | DCGM software-stack deployment plugin: every GPU has a present driver, matching CUDA, NVML responsive, no missing libs. Pass = DCGM reports OK. | Driver/CUDA/NVML mismatch on at least one GPU; environment is not ready for the rest of the suite. The `diagnostic.failed_gpus` field names which GPU and the DCGM-supplied warning text. |
| `diagnostic` | DCGM hardware diagnostic plugin (300s/GPU). Reads PCIe state, ECC counters, NVLink topology; exercises GEMM-class workloads to look for compute errors. Pass = DCGM reports OK. | A per-GPU hardware regression (compute error, NVLink degradation, ECC anomaly) that DCGM flagged. Per-GPU detail under `diagnostic.failed_gpus[]`. |
| `memory` | DCGM memory plugin: allocates ~99% of HBM per GPU, walks pages, checks for ECC events during the walk. Pass = DCGM reports OK. | HBM has a fault that surfaces under stress: page maps unusable, or the allocation triggered uncorrectable errors. |
| `targeted_power` | DCGM sustained-power plugin (600s/GPU). Drives each GPU near TDP and verifies power telemetry stays in spec. Pass = DCGM reports OK. | GPU could not sustain target power, throttled, or telemetry reported out-of-spec. Usually correlates with thermal or VRM faults. |
| `targeted_stress` | DCGM sustained-compute stress plugin (600s/GPU). Long-running GEMM-class load checking for correctness drift, hangs, or thermal excursions. Pass = DCGM reports OK. | The most common signal for "this GPU passes a quick check but fails under sustained load." Often the only test that catches marginal HBM or VRM issues. |

When a dcgm plugin fails, `diagnostic.failed_gpus[]` lists only the
specific GPUs that failed, with their per-GPU status and any
`warnings` / `info` strings DCGM emitted. The passing GPUs are not
echoed in the TAP diagnostic.

### nccl-allreduce (2 points) — `containers/nccl-tests-nvidia/entrypoint.sh`

Runs NCCL `all_reduce_perf -b 32K -e 8G -f 2 -g 8 -w 5 -n 20` three times and
gates on the **mean** busbw@8GB across the runs (so a single low run is not
masked by a good one). Concurrently captures `nvidia-smi dmon` to
`results/nccl-allreduce_dmon.log`.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `NCCL allreduce mean busbw@8GB >= 810 GB/s` | The mean of the per-run in-place bus bandwidths at the 8 GiB message size, across the 3 runs, is at least **810 GB/s** | This is the headline B300 collective-bandwidth floor. Below it means the GPU complex is not delivering the bandwidth a customer paying for a B300 expects — most often a fabric, NVLink, or PCIe regression. The diagnostic block includes `mean_busbw_8g_GBps`, `floor_GBps`, and `per_run_busbw_8g_GBps`. For per-size triage, the raw output of all three runs is saved to `results/nccl-allreduce_run1.log` … `_run3.log`. |
| `NCCL transport is NVLink (no PIX/SYS/PHB)` | All four must hold: (a) every rank logged `isAllDirectP2p 1 directMode 1 isAllCudaP2p 1`; (b) the count of those lines is `== GPU_COUNT`; (c) `NVLS multicast support is available on dev N` appeared at least `GPU_COUNT` times; (d) no `Falling back to`, `Cannot use P2P`, `cannot enable peer access`, or `disabling P2P` lines in the NCCL debug log | NCCL silently fell back to a slower transport (PIX/SYS/PHB). The busbw number above could be technically passing while still indicating a topology bug; this point is the independent transport assertion. The diagnostic lists which signals failed and the offending log lines. |

### nccl-alltoall (1 point) — same container, `NCCL_TEST=alltoall`

Runs `alltoall_perf -b 32K -e 8G -f 2 -g 8 -w 5 -n 20` once.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `NCCL alltoall_perf exit code == 0` | The binary exited 0 | The alltoall collective could not complete at all (hang, abort, illegal memory access). No SKU-specific bandwidth floor here — failure mode for alltoall on this hardware is binary; bandwidth regressions in allreduce already gate the suite. |

### post-health (4 points) — `containers/teardown-nvidia/entrypoint.sh`

Compares the post-test machine state against a baseline captured by
`setup-nvidia` before dcgm-diag/NCCL ran. Designed to catch silent
regressions induced by the stress phases.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `No new uncorrectable ECC errors` | `ecc.errors.uncorrected.volatile.total` summed across all GPUs is unchanged from baseline | An uncorrectable ECC event occurred during the run. The affected memory is now considered unreliable; this GPU should be quarantined regardless of whether dcgm-diag also flagged it. |
| `No new Xid errors in dmesg` | Count of `NVRM: Xid` lines in `dmesg -T` is `<=` baseline count | A kernel-level NVIDIA driver fault fired during the run (Xid). The new Xid lines are included in the diagnostic verbatim so the specific Xid number can be looked up. |
| `No thermal throttling observed` | No `(HW\|SW) (Thermal )?Slowdown : Active` line appears in `nvidia-smi -q -d PERFORMANCE` at post-test time | The card is currently throttling, i.e. the cooling envelope is insufficient at idle/cooldown — typically a fan or thermal-paste failure, not a software issue. |
| `Row remap status clean` | `nvidia-smi -q -d ROW_REMAPPER` reports `Pending: No` and `Remapping Failure Occurred: No` on every GPU | HBM row remapping is pending or has failed. Pending = remap will happen on next reboot; failed = the GPU has run out of spare rows. Either way the card has memory damage. |

> Correctable ECC errors are recorded but intentionally do **not** fail the
> suite — they are recovered by hardware. Only an increase in *uncorrectable*
> ECC errors fails the run. (The correctable-delta check is still in the
> teardown script, commented out.)

## `--gpu-model amd-mi325x`

Thresholds and expected values come from
[`containers/_lib/amd_models.sh`](../containers/_lib/amd_models.sh). A clean
run on the **current host** emits TAP across five suites in the order
below, and every point is `ok` **except** `rvs | power-stress (IET)`,
which is `not ok` on the only available MI325X host
(`very-bad-mi325x8-be-careful`, a VF/fabric box) — and, as a consequence,
the `rvs | rvs exit code == 0` belt-and-suspenders point is also `not ok`
because the non-zero RVS exit is real. Both are real `not ok` results (no
SKIP) per direction until IET is validated on a non-VF host; the run exit
code is therefore `1`.

> **Adding a future AMD SKU** is a purely additive, two-file change: add
> one `case` arm to
> [`containers/_lib/amd_models.sh`](../containers/_lib/amd_models.sh) (its
> model regex + VRAM) and drop in one vendored conf at
> `containers/rvs/conf/<gpu-model>/rvs_level_4.conf` (sourced from the RVS
> repo's `conf/<SKU>/levels`). The conf directory name **is** the
> `--gpu-model` value, so `amd_models.sh` resolves it with no extra
> mapping. No compose, image, or parser changes — the same five AMD
> containers and the conf-agnostic RVS parser serve every AMD SKU.

### prereqs (5 points) — `containers/prereqs-amd/entrypoint.sh`

A failure here halts the compose stack via `depends_on:
service_completed_successfully`; no downstream suite runs.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `amd-smi responds` | `amd-smi list` exits 0 and enumerates GPUs | ROCm driver not loaded, or `/dev/kfd`/`/dev/dri` not passed through — the suite can't see the GPUs. |
| `ROCm runtime exposes /dev/kfd and /dev/dri` | `/dev/kfd` exists and `/dev/dri` is a directory inside the container | Compose device passthrough did not wire the GPUs; nothing downstream can run. |
| `GPU count == 8` | Number of `GPU N:` blocks in `amd-smi list` equals `--gpu-count` | One or more GPUs missing from the topology, or `--gpu-count` was wrong for this droplet shape. |
| `All GPUs match model regex /MI325X/` | Each GPU `MARKET_NAME` from `amd-smi static` matches `MI325X` (case-insensitive) | Wrong SKU provisioned or a card swapped. Thresholds below are calibrated for MI325X. |
| `All GPUs report 261824 MiB VRAM` | Each GPU's `vram.size.value` from `amd-smi static --vram` equals `EXPECTED_VRAM_MIB` (261824). | A GPU reports a different HBM size — a bad/mis-binned card or the wrong SKU provisioned. |

### rvs (guard + exit-code + one point per RVS action) — `containers/rvs/`

Runs `rvs -c /rvs/conf/amd-mi325x/rvs_level_4.conf -d 3` (the vendored
MI325X level-4 conf). The parser is **conf-agnostic**: it reads the
end-of-run RVS summary table and emits one TAP point per action that
actually ran, so the exact list below is whatever the vendored conf
defines. `results/rvs.log` is always preserved (like
`dcgm-diag_raw.json`) for postmortems.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `rvs produced a summary table` | The RVS end-of-run summary table was found in the log | RVS did not complete, or its output format drifted; no per-action signal is trustworthy. Diagnostic points at `results/rvs.log`. |
| `rvs exit code == 0` | The `rvs` process exited 0 | RVS reported overall failure. Belt-and-suspenders: flips on any RVS-level failure even if per-action parsing passes. **Expected `not ok` on the current host** because `power-stress` fails. |
| `hbm_full (BABEL)` | Babel HBM stress: read/write/copy/add/mul/triad/dot kernels over HBM. Pass = table row `PASS`. | An HBM bandwidth/integrity fault surfaced under the Babel memory stress. |
| `pcie_d2h_bandwidth (PEBB)` / `pcie_h2d_bandwidth (PEBB)` | PCIe device↔host bandwidth sweep, each direction. Pass = row `PASS`. | PCIe link degraded (lane width/speed) or a bandwidth regression on that direction. |
| `xgmi_d2d_bandwidth (PBQT)` | xGMI device↔device peer bandwidth (bidirectional, all peers). Pass = row `PASS`. | The GPU↔GPU xGMI fabric is degraded — the AMD analogue of an NVLink regression; RCCL bandwidth below would also suffer. |
| `memtest (MEM)` | Exhaustive GPU memory test (500 passes, stress mode). Pass = row `PASS`. | A marginal/failed memory cell — the most likely test to catch HBM damage the stress plugins miss. |
| `compute-fp8-trig` / `compute-fp16-trig` / `compute-bf16-trig` / `compute-fp32-trig` / `compute-fp64-trig (GST)` | Sustained GEMM at a per-dtype target stress (hipBLASLt/rocBLAS). Pass = row `PASS`. | The GPU could not sustain the target compute throughput for that datatype, or produced incorrect results — marginal compute/VRM/thermal fault. |
| `power-stress (IET)` | Sustained-power stress driving each GPU toward `target_power` (1000 W) via dgemm. Pass = row `PASS`. | GPU could not sustain target power / telemetry out of spec. **Expected `not ok` on the current host**: IET fails on `very-bad-mi325x8-be-careful` (VF/fabric box). Treated as a real `not ok` (no SKIP) until validated on a non-VF MI325X. The diagnostic lists the failing GPU ID(s) from the per-GPU `pass: FALSE` lines. |

When an action fails, `diagnostic.failed_gpu_ids[]` lists only the GPU IDs
RVS reported `pass: FALSE` for that action; passing GPUs are not echoed.

### rccl-allreduce (1 point) — `containers/rccl-tests-amd/entrypoint.sh`

Runs RCCL `all_reduce_perf -b 32K -e 8G -f 2 -g 8 -w 5 -n 20` three times and
gates on the **mean** busbw@8GB across the runs. Concurrently captures an
`amd-smi monitor` sample stream to `results/rccl-allreduce_dmon.log`.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `RCCL all_reduce_perf mean busbw@8GB >= 300 GB/s` | The mean of the per-run in-place bus bandwidths at the 8 GiB message size, across the 3 runs, is at least **300 GB/s** (or no run produced a busbw@8GB row) | The GPU complex is not delivering the collective bandwidth an MI325X should — most often an xGMI fabric or PCIe regression, or (if no run completed) a hang/abort. Floor calibrated 2026-05-16 across three idle 8× MI325X hosts (min best run 318.26 GB/s, spread <1%); the ~6% headroom keeps a healthy host's mean above the floor. The diagnostic includes `mean_busbw_8g_GBps`, `floor_GBps`, and `per_run_busbw_8g_GBps`. For per-size triage, the raw output of all three runs is saved to `results/rccl-allreduce_run1.log` … `_run3.log`. |

### rccl-alltoall (1 point) — same container, `RCCL_TEST=alltoall`

Runs `alltoall_perf -b 32K -e 8G -f 2 -g 8 -w 5 -n 20` three times and gates on
the mean busbw@8GB across the runs.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `RCCL alltoall_perf mean busbw@8GB >= 285 GB/s` | The mean of the per-run in-place bus bandwidths at the 8 GiB message size, across the 3 runs, is at least **285 GB/s** (or no run produced a busbw@8GB row) | The all-to-all collective is not delivering expected bandwidth, or could not complete. Floor calibrated 2026-05-16 across three idle 8× MI325X hosts (min best run 301.67 GB/s, spread <1%). Same diagnostic shape as allreduce. |

### post-health (3 points) — `containers/teardown-amd/entrypoint.sh`

Compares post-test state against a baseline captured by `setup-amd`
before RVS/RCCL ran.

| Test | Threshold / criterion | What `not ok` means |
|---|---|---|
| `No new uncorrectable ECC errors` | Summed `uncorrected` ECC count is unchanged from baseline | An uncorrectable ECC event occurred during the run; the affected memory is unreliable and the GPU should be quarantined. |
| `No new amdgpu faults in dmesg` | Count of `amdgpu` lines in `dmesg -T` is `<=` baseline count | A kernel-level amdgpu fault fired during the run. The new lines are included verbatim in the diagnostic. |
| `No thermal throttling observed` | No active throttle/PVIOL/thermal status in `amd-smi metric` at post-test time | The card is throttling at cooldown — cooling/power envelope inadequate, typically a hardware (fan/thermal) fault. |

> Correctable ECC errors are recorded but intentionally do **not** fail the
> suite — they are recovered by hardware. Only an increase in *uncorrectable*
> ECC errors fails the run. (The correctable-delta check is still in the
> teardown script, commented out.)

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
- `results/nccl-allreduce_run1.log` … `_run3.log`,
  `results/nccl-alltoall_run.log` — raw nccl-tests perf-run output.
- `results/nccl-allreduce_dmon.log`, `results/nccl-alltoall_dmon.log` —
  `nvidia-smi dmon` samples (SM/util/mem/power) over the run window.

For `amd-mi325x`:

- `results/rvs.log` — verbatim `rvs -c <conf> -d 3` text log (the
  `[RESULT]` stream + the summary table the parser reads).
- `results/rccl-allreduce_run1.log` … `_run3.log`,
  `results/rccl-alltoall_run1.log` … `_run3.log` — raw rccl-tests perf-run output.
- `results/rccl-allreduce_dmon.log`, `results/rccl-alltoall_dmon.log` —
  `amd-smi monitor` samples over the run window.

## Adding new tests

A "test" here is one point in the TAP stream. Tests are emitted by a
container that writes a single result file at
`/results/<suite>.json` and is wired into the appropriate compose stack
(`compose.test.yaml` for the mock family, `compose.nvidia.yaml` for the
nvidia family, `compose.amd.yaml` for the amd family). The `tap-reporter`
container reads those JSON files in
the order declared by its `SUITE_FILES` array
(`containers/tap-reporter/tap-reporter.sh`) and emits the flat TAP
v14 stream — so adding a new suite means:

1. Build a container that writes `/results/<suite>.json` in the schema
   below.
2. Add the service to the right `compose.*.yaml`, wired with
   `depends_on: ... service_completed_successfully` so it runs after
   any prerequisite suite and before `tap-reporter`.
3. Add `<suite>.json` to `SUITE_FILES` in
   `containers/tap-reporter/tap-reporter.sh` in the order it should
   appear in the TAP stream.
4. Add the new test points to this file under the appropriate
   `## --gpu-model <sku>` section, with threshold and `not ok`
   interpretation.

### Result-file schema

Every suite's `/results/<suite>.json` must conform to:

```json
{
  "suite": "<suite-name>",
  "tests": [
    {
      "ok": true | false,
      "name": "<short test description>",
      "directive": null | "SKIP <reason>",
      "diagnostic": null | { ... }
    }
  ]
}
```

### Diagnostic convention

The `diagnostic` field is what renders as the indented YAML block under
a TAP point. The reporter only prints YAML for `not ok` points; passing
points are a single line in TAP. Per-suite JSON keeps the diagnostic
regardless, so passing diagnostics are fine but they will not surface
on the human-facing stream.

**Rule:** every `not ok` diagnostic MUST start with a `message` key
whose value is a single human-readable sentence describing the failure.
Additional structured fields (counts, thresholds, per-GPU detail, raw
log excerpts) follow the message and are free-form. The intent is that
anyone scanning the TAP output sees the *why* in one line before
deciding whether to read the structured detail.

Pass / fail examples:

```yaml
# passing point — diagnostic is null
ok 4 - prereqs | GPU count == 8

# failing point — diagnostic starts with `message`
not ok 4 - prereqs | GPU count == 8
  ---
  message: "expected 8 GPUs, saw 9"
  expected: 8
  observed: 9
  ...
```

```yaml
not ok 10 - dcgm-diag | memory
  ---
  message: "dcgm 'memory' plugin reported Fail (1/8 GPU(s) failed)"
  status: "Fail"
  failed_gpus: [{"gpu":3,"status":"Fail","info":["..."]}]
  ...
```

### How existing suites generate the `message` field

- **Shell entrypoints** (`prereqs-nvidia`, `teardown-nvidia`,
  `nccl-tests-nvidia`): `jq -n` builds the diagnostic object literal
  with `message:` as the first field, optionally merged with structured
  data via `{ message: ... } + $structured`. See
  `containers/prereqs-nvidia/entrypoint.sh:add_test` for the shared
  helper pattern (`add_test false "<name>" "<message>" "<structured-json>"`).
- **Parsers** (`dcgm-diag/parse.jq`): the diagnostic is constructed
  inside an `if $ok then null else { message: "...", ...rest } end`
  branch, so the message is only computed for failing points.

When you add a suite, follow whichever pattern matches: a shell
entrypoint that calls a small `add_test` helper, or a jq parser that
constructs the result object directly. The convention is the same
either way — `message` first, structured detail after.
