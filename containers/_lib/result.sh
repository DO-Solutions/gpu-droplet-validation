#!/usr/bin/env bash
# Shared helpers for droplet-validation container entrypoints.
# Source this from each container's entrypoint.sh: `source /lib/result.sh`.

set -euo pipefail

log() { printf '[%s] %s\n' "${SUITE:-container}" "$*" >&2; }
die() { printf '[%s] %s\n' "${SUITE:-container}" "$*" >&2; exit 1; }

# write_result_json <suite-name> <output-path> <jq-expression>
# Evaluates the jq expression in "null input" mode and writes the result to the
# output path. The suite name is exposed to the jq expression as $suite.
write_result_json() {
  local suite="$1" path="$2" expr="$3"
  jq -n --arg suite "$suite" "$expr" > "$path"
}
