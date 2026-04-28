#!/usr/bin/env bash
# Shared TAP v14 reporter. Reusable across --gpu-model flows.
#
# Reads result JSON files from /results in a defined order and emits a flat
# TAP v14 document (no subtests) to both stdout and /results/output.tap.
# Writes the final exit code to /results/tap_exit so the caller can reproduce
# the pass/fail signal after the fact (run.sh reads this after compose exits).
#
# Each result file must conform to the Result File Format from Dev Spec §1:
#   { "suite": "<name>", "tests": [ { "ok": bool, "name": str,
#       "diagnostic": null|object, "directive": null|string } ] }
#
# The output is intentionally a single, flat plan with one test point per
# logical check — no `# Subtest:` blocks and no nested plans. Downstream
# consumers therefore only need to parse the top-level TAP grammar from the
# spec at https://testanything.org/tap-version-14-specification.html.
# Suite identity is preserved by prefixing each description with the suite
# name (`<suite>: <name>`).
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
  "p2p-bandwidth.json"
  "nccl-alltoall.json"
  "mock-test.json"
  "post-health.json"
)

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

# ---------- 1. Total test point count across all suites ----------
total=0
for f in "${present[@]}"; do
  n=$(jq '.tests | length' "$RESULTS_DIR/$f")
  total=$((total + n))
done

emit "TAP version 14"
emit "1..$total"

# ---------- 2. Flat emit: one test point per check, suite-prefixed ----------
overall_ok=1
point=0
for f in "${present[@]}"; do
  path="$RESULTS_DIR/$f"
  suite="$(jq -r '.suite' "$path")"
  tcount="$(jq '.tests | length' "$path")"

  for i in $(seq 0 $((tcount - 1))); do
    t_ok=$(jq -r ".tests[$i].ok" "$path")
    t_name=$(jq -r ".tests[$i].name" "$path")
    t_directive=$(jq -r ".tests[$i].directive // empty" "$path")
    t_has_diag=$(jq -r "(.tests[$i].diagnostic // null) | if . == null then \"0\" else \"1\" end" "$path")

    point=$((point + 1))
    if [ "$t_ok" = "true" ]; then
      status="ok"
    else
      status="not ok"
      overall_ok=0
    fi

    if [ -n "$t_directive" ]; then
      emit "$status $point - $suite: $t_name # $t_directive"
    else
      emit "$status $point - $suite: $t_name"
    fi

    if [ "$t_has_diag" = "1" ]; then
      # TAP v14 YAML block, indented 2 spaces at the top level.
      emit "  ---"
      jq -r ".tests[$i].diagnostic | to_entries[] | \"  \(.key): \(.value | tojson)\"" "$path" \
        | tee -a "$OUT"
      emit "  ..."
    fi
  done
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
