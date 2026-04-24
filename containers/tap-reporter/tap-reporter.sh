#!/usr/bin/env bash
# Shared TAP v14 reporter. Reusable across --gpu-model flows.
#
# Reads result JSON files from /results in a defined order and emits a TAP v14
# document to both stdout and /results/output.tap. Writes the final exit code
# to /results/tap_exit so the caller can reproduce the pass/fail signal after
# the fact (run.sh reads this after compose exits).
#
# Each file must conform to the Result File Format from Dev Spec §1:
#   { "suite": "<name>", "tests": [ { "ok": bool, "name": str,
#       "diagnostic": null|object, "directive": null|string } ] }
#
# The read order encodes execution order and is easy to extend for the real
# --gpu-model flows: just add the additional suite filenames.
set -euo pipefail

RESULTS_DIR="/results"
OUT="$RESULTS_DIR/output.tap"

# Execution order of suites in the TAP output. Files are skipped if absent,
# which lets us reuse this image for real flows that produce more suites.
SUITE_FILES=(
  "prereqs.json"
  "gpu-health.json"
  "nvlink.json"
  "gemm-compute.json"
  "nccl-allreduce.json"
  "nccl-alltoall.json"
  "p2p-bandwidth.json"
  "mock-test.json"
  "post-health.json"
)

# Collect files that actually exist, preserving order.
present=()
for f in "${SUITE_FILES[@]}"; do
  [ -f "$RESULTS_DIR/$f" ] && present+=("$f")
done

if [ "${#present[@]}" -eq 0 ]; then
  echo "tap-reporter: no result files found in $RESULTS_DIR" >&2
  echo 1 > "$RESULTS_DIR/tap_exit"
  exit 1
fi

emit() {
  # Write to both stdout (visible in `docker compose up` logs) and output.tap
  # (what run.sh forwards to the caller's stdout).
  printf '%s\n' "$1" | tee -a "$OUT"
}

: > "$OUT"

top_count="${#present[@]}"
emit "TAP version 14"
emit "1..$top_count"

overall_ok=1
top_idx=0
for f in "${present[@]}"; do
  top_idx=$((top_idx + 1))
  path="$RESULTS_DIR/$f"

  suite="$(jq -r '.suite' "$path")"
  tcount="$(jq '.tests | length' "$path")"

  emit "# Subtest: $suite"
  emit "    1..$tcount"

  suite_ok=1
  for i in $(seq 0 $((tcount - 1))); do
    t_ok=$(jq -r ".tests[$i].ok" "$path")
    t_name=$(jq -r ".tests[$i].name" "$path")
    t_directive=$(jq -r ".tests[$i].directive // empty" "$path")
    t_has_diag=$(jq -r "(.tests[$i].diagnostic // null) | if . == null then \"0\" else \"1\" end" "$path")

    point=$((i + 1))
    if [ "$t_ok" = "true" ]; then
      status="ok"
    else
      status="not ok"
      suite_ok=0
      overall_ok=0
    fi

    if [ -n "$t_directive" ]; then
      emit "    $status $point - $t_name # $t_directive"
    else
      emit "    $status $point - $t_name"
    fi

    if [ "$t_has_diag" = "1" ]; then
      emit "      ---"
      # Dump diagnostic as key: value pairs. jq emits each line; indent to 6
      # spaces to sit inside the subtest's 4-space indent as TAP YAML.
      jq -r ".tests[$i].diagnostic | to_entries[] | \"      \(.key): \(.value | tojson)\"" "$path" \
        | tee -a "$OUT"
      emit "      ..."
    fi
  done

  if [ "$suite_ok" = "1" ]; then
    emit "ok $top_idx - $suite"
  else
    emit "not ok $top_idx - $suite"
  fi
done

# tap_exit is written for traceability (did any test point report not ok?)
# but the container always exits 0 on success of the reporter itself. TAP is
# the pass/fail signal; the container's exit code only needs to signal
# "tap-reporter ran" vs "tap-reporter crashed." Returning non-zero here would
# mark the compose run failed and confuse callers that key off docker compose
# exit codes.
if [ "$overall_ok" = "1" ]; then
  echo 0 > "$RESULTS_DIR/tap_exit"
else
  echo 1 > "$RESULTS_DIR/tap_exit"
fi
exit 0
