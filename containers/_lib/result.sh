#!/usr/bin/env bash
# Shared helpers for droplet-validation container entrypoints.
# Source this from each container's entrypoint.sh: `source /lib/result.sh`.

set -euo pipefail

log() { printf '[%s] %s\n' "${SUITE:-container}" "$*" >&2; }
die() { printf '[%s] %s\n' "${SUITE:-container}" "$*" >&2; exit 1; }

# format_failures <result-json-path>
# Renders every not-ok test point in a suite result file as a single line:
#   "<name> — <message>; <name> — <message>"
# Points with no diagnostic message degrade to just the check name. Prints
# nothing (rc 0) when the file is missing, unreadable, malformed, or has no
# failures, so callers can test for a non-empty string. Kept to one line on
# purpose: the stderr contract in README.md is a single error line.

format_failures() {
  local path="$1"
  [ -r "$path" ] || return 0
  jq -r '
    [ (.tests // [])[]
      | select(.ok == false)
      | ((.name // "unnamed check") | tostring) as $n
      | (if (.diagnostic | type) == "object"
         then ((.diagnostic.message // "") | tostring)
         else "" end) as $m
      | if $m == "" then $n else "\($n) — \($m)" end
    ]
    | join("; ")
    | gsub("[\r\n]+"; " ")
  ' "$path" 2>/dev/null || true
}

# die_with_failures <result-json-path> <prefix> <fallback-message>
# Exits non-zero with the specific reason(s) this suite failed, so the
# container's stderr names the failing check instead of a generic string.
# Falls back to <fallback-message> when the result file can't tell us why
# (never written, truncated, etc.).
die_with_failures() {
  local path="$1" prefix="$2" fallback="$3" summary
  summary="$(format_failures "$path")"
  if [ -n "$summary" ]; then
    die "$prefix: $summary"
  fi
  die "$fallback"
}

# write_result_json <suite-name> <output-path> <jq-expression>
# Evaluates the jq expression in "null input" mode and writes the result to the
# output path. The suite name is exposed to the jq expression as $suite.
write_result_json() {
  local suite="$1" path="$2" expr="$3"
  jq -n --arg suite "$suite" "$expr" > "$path"
}
