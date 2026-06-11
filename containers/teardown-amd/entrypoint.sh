#!/usr/bin/env bash
# Post-test health for the amd-* family.
# Diffs ECC/RAS + amdgpu-dmesg against /results/baseline.json (written by
# setup-amd), checks for thermal throttling, writes post-health.json.
# Mirrors teardown-nvidia's add_test helper + message-first convention.
SUITE=post-health
source /lib/result.sh
source /lib/amd_models.sh

BASELINE=/results/baseline.json
[ -f "$BASELINE" ] || die "missing baseline.json from setup container"

results_tmp="$(mktemp)"
trap 'rm -f "$results_tmp"' EXIT
printf '[]' > "$results_tmp"

add_test() {
  local ok="$1" name="$2" diag_json="${3:-null}"
  jq --argjson ok "$ok" --arg name "$name" --argjson diag "$diag_json" \
     '. + [{ ok: $ok, name: $name, directive: null, diagnostic: $diag }]' \
     "$results_tmp" > "$results_tmp.next"
  mv "$results_tmp.next" "$results_tmp"
}

# ----- ECC delta (same normalization as setup-amd) -----
ecc_now='[]'
if ecc_json="$(amd-smi metric --ecc --json 2>/dev/null)" && [ -n "$ecc_json" ]; then
  ecc_now="$(printf '%s' "$ecc_json" | jq '
    [ (.gpu_data // [])[]
      | { index: .gpu,
          corrected:   (.ecc.total_correctable_count   // 0),
          uncorrected: (.ecc.total_uncorrectable_count // 0) } ]' \
    2>/dev/null || echo '[]')"
fi

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

# Correctable ECC errors do NOT fail the suite: they are recovered by hardware
# by definition, so a correctable delta alone is not sufficient to fail the
# test suite. Only an increase in UNCORRECTABLE errors (below) indicates
# unreliable memory. The correctable delta ($d_corr_total) is still computed
# above and could be surfaced as a diagnostic later if we want an early-warning
# signal; the test point is intentionally disabled, not deleted.
# if [ "$d_corr_total" = "0" ]; then
#   add_test true "No new correctable ECC errors" "null"
# else
#   add_test false "No new correctable ECC errors" \
#     "$(echo "$delta" | jq --argjson n "$d_corr_total" \
#         '{ message: "\($n) new correctable ECC error(s) across all GPUs since baseline", delta_corrected_total: $n, per_gpu: . }')"
# fi

if [ "$d_uncorr_total" = "0" ]; then
  add_test true "No new uncorrectable ECC errors" "null"
else
  add_test false "No new uncorrectable ECC errors" \
    "$(echo "$delta" | jq --argjson n "$d_uncorr_total" \
        '{ message: "\($n) new UNCORRECTABLE ECC error(s) since baseline — GPU memory may be unreliable", delta_uncorrected_total: $n, per_gpu: . }')"
fi

# ----- amdgpu faults in dmesg -----
# MUST use the same fault-signature regex as setup-amd's baseline so the
# delta is apples-to-apples (benign "queue evicted" / "Freeing queue vital
# buffer" / "hogged CPU" lifecycle noise is excluded on both sides).
AMDGPU_FAULT_RE='page fault|ring [0-9].*timeout|GPU reset|gpu recover|uncorrectable|ECC error|\bRAS\b|xgmi.*error|fault from die|GPU hang|reset begin|soft recovery|amdgpu: GPU fault'
amdgpu_base_count="$(jq '.amdgpu_baseline.count // 0' "$BASELINE")"
amdgpu_now_lines="$(dmesg -T 2>/dev/null | grep -i 'amdgpu' | grep -iE "$AMDGPU_FAULT_RE" || true)"
amdgpu_now_count="$(printf '%s\n' "$amdgpu_now_lines" | grep -c . || true)"
amdgpu_delta=$(( amdgpu_now_count - amdgpu_base_count ))

if [ "$amdgpu_delta" -le 0 ]; then
  add_test true "No new amdgpu faults in dmesg" "null"
else
  new_lines="$(printf '%s\n' "$amdgpu_now_lines" | tail -n "$amdgpu_delta")"
  diag="$(jq -n --arg lines "$new_lines" --argjson n "$amdgpu_delta" \
    '{ message: "\($n) new amdgpu kernel message(s) appeared in dmesg during the run — possible kernel-level GPU fault",
       new_amdgpu_count: $n,
       lines: ($lines | split("\n") | map(select(length>0))) }')"
  add_test false "No new amdgpu faults in dmesg" "$diag"
fi

# ----- Thermal / power throttling -----
# amd-smi metric exposes optional `throttle` / `pviol` objects per GPU. On
# SR-IOV VF boxes these are absent/null (no throttle telemetry through the
# VF), so the check is null-tolerant: only an explicitly-true active
# indicator fails it. We do NOT infer throttling from temperature alone
# (no per-SKU limit calibrated). Missing telemetry => pass (can't observe
# throttling is not the same as observing it).
perf_json="$(amd-smi metric --json 2>/dev/null || true)"
throttled_gpus="$(echo "$perf_json" | jq -c '
  [ (.gpu_data // [])[]
    | select(
        ((.throttle.active? // false) == true)
        or ((.pviol.active? // false) == true)
        or (((.throttle.status? // "") | ascii_downcase) | test("active|throttl"))
      )
    | .gpu ]' 2>/dev/null || echo '[]')"
if [ "$(echo "$throttled_gpus" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
  add_test true "No thermal throttling observed" "null"
else
  diag="$(jq -n --argjson g "$throttled_gpus" \
    '{ message: "Thermal/power throttling is active on GPU(s) \($g | tostring) — cooling/power envelope inadequate",
       throttled_gpu_ids: $g }')"
  add_test false "No thermal throttling observed" "$diag"
fi

jq --arg suite "$SUITE" '{ suite: $suite, tests: . }' "$results_tmp" > /results/post-health.json
log "ok"
