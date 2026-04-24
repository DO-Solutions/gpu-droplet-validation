#!/usr/bin/env bash
# Mock test container for --gpu-model test.
# Emits a result JSON conforming to Dev Spec §1 Result File Format.
# RUN_ID prefix selects scenario; any non-fail prefix is treated as pass.
# Exits 0 in both pass and fail scenarios — the failure signal is carried by
# ok:false entries inside the JSON, not by exit code. Only prereqs failure
# (error-*) uses exit code to halt the pipeline.
SUITE=mock-test
source /lib/result.sh

# Always produce a small Tier-3 debug artifact so the upload path is exercised.
{
  echo "# mock dmon log (RUN_ID=${RUN_ID:-<unset>})"
  echo "# gpu  pwr  gtemp  mtemp  sm   mem   enc   dec   mclk   pclk"
  for i in 1 2 3 4 5; do
    echo "   0   450    55     60   95    80     0     0   2619   1980"
  done
} > /results/mock-test_dmon.log

case "${RUN_ID:-}" in
  fail-*)
    write_result_json mock-test /results/mock-test.json '{
      suite: $suite,
      tests: [
        { ok: true,  name: "mock health probe A",        diagnostic: null },
        { ok: false, name: "mock perf floor (GEMM)",
          diagnostic: {
            message: "mock GEMM TFLOPS below floor",
            severity: "fail",
            gpu: 5,
            floor: 2200,
            observed: 1980
          }
        },
        { ok: true,  name: "mock perf floor (NCCL)",     diagnostic: null }
      ]
    }'
    log "produced FAIL scenario (RUN_ID=$RUN_ID)"
    ;;
  *)
    write_result_json mock-test /results/mock-test.json '{
      suite: $suite,
      tests: [
        { ok: true, name: "mock health probe A",    diagnostic: null },
        { ok: true, name: "mock perf floor (GEMM)", diagnostic: null },
        { ok: true, name: "mock perf floor (NCCL)", diagnostic: null }
      ]
    }'
    log "produced PASS scenario (RUN_ID=${RUN_ID:-<unset>})"
    ;;
esac
