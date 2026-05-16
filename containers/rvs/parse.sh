#!/usr/bin/env bash
# Translate an `rvs -c <conf> -d 3` text log into the tap-reporter result
# schema. Conf-agnostic: every SKU's vendored conf defines its own action
# set, so whatever RVS actually ran (per the end-of-run summary table) is
# what gets reported — no hardcoded action list.
#
# Usage: parse.sh <rvs.log> <rvs-exit-code>
# Output: { "suite": "rvs", "tests": [ ... ] } on stdout.
#
# RVS prints a summary table at the end of the run:
#   +=====...=====+
#   | Action Name        | Module    | Result   |
#   +=====...=====+
#   | hbm_full           | BABEL     | PASS     |
#   | power-stress       | IET       | FAIL     |
#   +-----...-----+
# PASS/FAIL are ANSI-colored, so colour codes are stripped first. One TAP
# point is emitted per data row that actually appears in the table, plus a
# guard point ("a summary table was produced") and an "exit code == 0"
# point. On FAIL we scan the per-GPU `[RESULT] ... [<action>] [GPU:: <id>]
# pass: FALSE` lines to list the failing GPU IDs in the diagnostic.
set -euo pipefail

LOG="${1:?usage: parse.sh <rvs.log> <rvs-exit-code>}"
RC="${2:?usage: parse.sh <rvs.log> <rvs-exit-code>}"
SUITE="rvs"

# Strip ANSI colour escapes so PASS/FAIL match as plain words.
clean="$(sed -E 's/\x1b\[[0-9;]*m//g' "$LOG")"

# Pull the summary-table data rows: 3 pipe-delimited columns whose third
# column is exactly PASS or FAIL (this naturally excludes the
# "| Action Name | Module | Result |" header and the +===+/+---+ rules).
# Emit "<action>\t<module>\t<result>" per row, trimmed.
rows="$(printf '%s\n' "$clean" | awk -F'|' '
  NF==5 {
    a=$2; m=$3; r=$4;
    gsub(/^[ \t]+|[ \t]+$/, "", a);
    gsub(/^[ \t]+|[ \t]+$/, "", m);
    gsub(/^[ \t]+|[ \t]+$/, "", r);
    if (r=="PASS" || r=="FAIL") printf "%s\t%s\t%s\n", a, m, r;
  }
')"

row_count="$(printf '%s' "$rows" | grep -c . || true)"

tests='[]'
add() {
  # add <ok:true|false> <name> [diagnostic-json|null]
  tests="$(jq -c --argjson ok "$1" --arg name "$2" --argjson diag "${3:-null}" \
    '. + [{ ok: $ok, name: $name, directive: null, diagnostic: $diag }]' \
    <<<"$tests")"
}

# 1. Guard: did RVS produce a parseable summary table at all?
if [ "$row_count" -gt 0 ]; then
  add true "rvs produced a summary table"
else
  add false "rvs produced a summary table" "$(jq -n \
    '{ message: "no RVS summary table found in the log — rvs did not complete or its output format drifted", raw: "/results/rvs.log" }')"
fi

# 2. Exit-code point (belt-and-suspenders, mirrors dcgmi).
if [ "$RC" -eq 0 ]; then
  add true "rvs exit code == 0"
else
  add false "rvs exit code == 0" "$(jq -n --argjson rc "$RC" \
    '{ message: "rvs exited with code \($rc)", exit_code: $rc }')"
fi

# 3. One point per action row in the table.
if [ "$row_count" -gt 0 ]; then
  while IFS=$'\t' read -r action module result; do
    [ -n "$action" ] || continue
    if [ "$result" = "PASS" ]; then
      add true "$action ($module)"
    else
      # Collect the GPU IDs that failed this action.
      failed_ids="$(printf '%s\n' "$clean" \
        | grep -F "[$action]" \
        | grep -E '\[GPU:: *[0-9]+\] +pass: *FALSE' \
        | sed -E 's/.*\[GPU:: *([0-9]+)\].*/\1/' \
        | sort -u || true)"
      n_failed="$(printf '%s' "$failed_ids" | grep -c . || true)"
      ids_json="$(printf '%s\n' "$failed_ids" \
        | jq -R 'select(length>0)' | jq -s 'map(tonumber)')"
      diag="$(jq -n \
        --arg action "$action" --arg mod "$module" \
        --argjson n "$n_failed" --argjson ids "$ids_json" \
        '{ message: ("RVS \"\($action)\" (\($mod)) reported FAIL" + (if $n>0 then " (\($n) GPU(s) failed)" else "" end)),
           "module": $mod, "result": "FAIL",
           failed_gpu_ids: $ids }')"
      add false "$action ($module)" "$diag"
    fi
  done <<<"$rows"
fi

jq -n --arg suite "$SUITE" --argjson tests "$tests" \
  '{ suite: $suite, tests: $tests }'
