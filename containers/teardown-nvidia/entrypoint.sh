#!/usr/bin/env bash
# Post-test health for the nvidia-* family.
# Compares ECC + Xid against /results/baseline.json (written by setup-nvidia),
# checks for thermal throttling and row remap activity, writes post-health.json.
SUITE=post-health
source /lib/result.sh
source /lib/nvidia_models.sh

BASELINE=/results/baseline.json
[ -f "$BASELINE" ] || die "missing baseline.json from setup container"

results_tmp="$(mktemp)"
trap 'rm -f "$results_tmp"' EXIT
printf '[]' > "$results_tmp"

add_test() {
  local ok="$1" name="$2" diag_json="${3:-null}"
  jq --argjson ok "$ok" --arg name "$name" --argjson diag "$diag_json" \
     '. + [{ ok: $ok, name: $name, diagnostic: $diag }]' \
     "$results_tmp" > "$results_tmp.next"
  mv "$results_tmp.next" "$results_tmp"
}

# ----- ECC delta -----
ecc_now="$(nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total \
  --format=csv,noheader,nounits 2>/dev/null \
  | awk -F',' 'BEGIN{print "["} NR>1{print ","} {gsub(/ /,""); printf "{\"index\":%s,\"corrected\":%s,\"uncorrected\":%s}", $1, $2, $3} END{print "]"}')"

delta="$(jq -n \
  --argjson before "$(jq '.ecc_baseline' "$BASELINE")" \
  --argjson after  "$ecc_now" '
  reduce range(0; ($after | length)) as $i ([];
    . + [{
      index: ($after[$i].index),
      d_corrected:   ($after[$i].corrected   - ($before[$i].corrected   // 0)),
      d_uncorrected: ($after[$i].uncorrected - ($before[$i].uncorrected // 0))
    }])
')"

d_corr_total="$(echo "$delta" | jq '[.[] | .d_corrected]   | add // 0')"
d_uncorr_total="$(echo "$delta" | jq '[.[] | .d_uncorrected] | add // 0')"

if [ "$d_corr_total" = "0" ]; then
  add_test true "No new correctable ECC errors" "null"
else
  add_test false "No new correctable ECC errors" "$(echo "$delta" | jq '{ delta_corrected_total: '"$d_corr_total"', per_gpu: . }')"
fi

if [ "$d_uncorr_total" = "0" ]; then
  add_test true "No new uncorrectable ECC errors" "null"
else
  add_test false "No new uncorrectable ECC errors" "$(echo "$delta" | jq '{ delta_uncorrected_total: '"$d_uncorr_total"', per_gpu: . }')"
fi

# ----- Xid in dmesg -----
xid_baseline_count="$(jq '.xid_baseline.count // 0' "$BASELINE")"
xid_now_lines="$(dmesg -T 2>/dev/null | grep -i 'NVRM: Xid' || true)"
xid_now_count="$(printf '%s\n' "$xid_now_lines" | grep -c . || true)"
xid_delta=$(( xid_now_count - xid_baseline_count ))

if [ "$xid_delta" -le 0 ]; then
  add_test true "No new Xid errors in dmesg" "null"
else
  new_lines="$(printf '%s\n' "$xid_now_lines" | tail -n "$xid_delta")"
  diag="$(jq -n --arg lines "$new_lines" --argjson n "$xid_delta" '{ new_xid_count: $n, lines: ($lines | split("\n") | map(select(length>0))) }')"
  add_test false "No new Xid errors in dmesg" "$diag"
fi

# ----- Thermal throttling -----
# `nvidia-smi -q -d PERFORMANCE` exposes "Clocks Event Reasons" with HW
# Slowdown, HW Thermal Slowdown, SW Thermal Slowdown lines whose value is
# "Active" or "Not Active". Match only lines that end in ": Active" (with no
# leading "Not"). The trailing-$ anchor matters — without it, "Not Active"
# also matches because the substring "Active" is shared.
perf_out="$(nvidia-smi -q -d PERFORMANCE 2>/dev/null || true)"
throttle_active="$(printf '%s\n' "$perf_out" \
  | grep -E '(HW|SW) (Thermal )?Slowdown[[:space:]]*:[[:space:]]*Active$' \
  | head -n 5 || true)"
if [ -z "$throttle_active" ]; then
  add_test true "No thermal throttling observed" "null"
else
  diag="$(jq -n --arg active "$throttle_active" '{ active: ($active | split("\n") | map(select(length>0))) }')"
  add_test false "No thermal throttling observed" "$diag"
fi

# ----- Row remap status -----
remap_out="$(nvidia-smi -q -d ROW_REMAPPER 2>/dev/null || true)"
pending="$(printf '%s\n' "$remap_out" | awk '/Pending/ {gsub(/ /,""); print $2}' | sort -u)"
failure="$(printf '%s\n' "$remap_out" | awk '/Remapping Failure Occurred/ {gsub(/ /,""); print $4}' | sort -u)"
remap_clean=1
case "$pending" in *Yes*) remap_clean=0 ;; esac
case "$failure" in *Yes*) remap_clean=0 ;; esac
if [ "$remap_clean" = 1 ]; then
  add_test true "Row remap status clean" "null"
else
  diag="$(jq -n --arg p "$pending" --arg f "$failure" '{ pending: $p, failure_occurred: $f }')"
  add_test false "Row remap status clean" "$diag"
fi

jq --arg suite "$SUITE" '{ suite: $suite, tests: . }' "$results_tmp" > /results/post-health.json
log "ok"
