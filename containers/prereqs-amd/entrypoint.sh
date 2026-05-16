#!/usr/bin/env bash
# Real prereqs for the amd-* family.
# Halts the compose stack on any failure by exiting non-zero (depends_on:
# service_completed_successfully). Writes /results/prereqs.json with one TAP
# point per check. Mirrors prereqs-nvidia's add_test helper + halt behavior.
#
# All GPU enumeration uses `amd-smi ... --json` + jq — the human tables vary
# across ROCm releases and (on SR-IOV VF boxes) hide the real SKU. Notably,
# on a VF host `asic.market_name` / `board.product_name` are generic
# ("AMD Radeon Graphics" / "N/A"); the only field that carries the real
# SKU is the VBIOS name (e.g. "AMD MI325X_SRIOV_CVS_1VF"), so the model
# regex is matched against that.
SUITE=prereqs
source /lib/result.sh
source /lib/amd_models.sh

: "${GPU_COUNT:?GPU_COUNT is not set}"

results_tmp="$(mktemp)"
trap 'rm -f "$results_tmp"' EXIT
printf '[]' > "$results_tmp"

# add_test <ok:true|false> <name> [message] [structured-json] [directive]
# Convention: every not-ok diagnostic MUST start with a human-readable
# `message` field. Passing points use a null diagnostic.
add_test() {
  local ok="$1" name="$2" msg="${3:-}" structured="${4:-null}" directive="${5:-}"
  local djson='null'
  [ -n "$directive" ] && djson="$(jq -n --arg d "$directive" '$d')"
  if [ -n "$msg" ]; then
    jq --argjson ok "$ok" --arg name "$name" --arg msg "$msg" \
       --argjson s "$structured" --argjson dir "$djson" \
       '. + [{ ok: $ok, name: $name, directive: $dir, diagnostic: ({ message: $msg } + (if $s == null then {} else $s end)) }]' \
       "$results_tmp" > "$results_tmp.next"
  else
    jq --argjson ok "$ok" --arg name "$name" --argjson dir "$djson" \
       '. + [{ ok: $ok, name: $name, directive: $dir, diagnostic: null }]' \
       "$results_tmp" > "$results_tmp.next"
  fi
  mv "$results_tmp.next" "$results_tmp"
}

fail=0
mark_fail() { fail=1; }

# 1. amd-smi responds (modern AMD GPU CLI shipped in the ROCm stack).
list_json=""
if list_json="$(amd-smi list --json 2>/dev/null)" && [ -n "$list_json" ] \
   && echo "$list_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
  add_test true "amd-smi responds"
else
  err="$(amd-smi list 2>&1 | head -c 800 || true)"
  add_test false "amd-smi responds" \
    "amd-smi failed to enumerate GPUs as JSON — ROCm driver not loaded or devices not passed through" \
    "$(jq -n --arg err "$err" '{error: $err}')"
  mark_fail
fi

# 2. ROCm device passthrough: KFD compute node + DRI render nodes.
if [ -e /dev/kfd ] && [ -d /dev/dri ]; then
  add_test true "ROCm runtime exposes /dev/kfd and /dev/dri"
else
  add_test false "ROCm runtime exposes /dev/kfd and /dev/dri" \
    "missing /dev/kfd and/or /dev/dri inside container — compose device passthrough did not wire the GPUs"
  mark_fail
fi

# 3. GPU count (length of the `amd-smi list --json` array).
seen_count=0
if [ -n "$list_json" ]; then
  seen_count="$(echo "$list_json" | jq 'length' 2>/dev/null || echo 0)"
fi
if [ "$seen_count" -eq "$GPU_COUNT" ]; then
  add_test true "GPU count == $GPU_COUNT"
else
  add_test false "GPU count == $GPU_COUNT" \
    "expected $GPU_COUNT GPUs, saw $seen_count" \
    "$(jq -n --argjson e "$GPU_COUNT" --argjson o "$seen_count" '{expected: $e, observed: $o}')"
  mark_fail
fi

# 4. Model regex, matched (case-insensitively) against each GPU's VBIOS
#    name — the only amd-smi field that carries the real SKU on a VF box.
vbios_json="$(amd-smi static --vbios --json 2>/dev/null || true)"
vbios_names="$(echo "$vbios_json" | jq -r '.gpu_data[].vbios.name' 2>/dev/null || true)"
model_ok=1
mismatch_models=""
if [ -n "$vbios_names" ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! printf '%s' "$name" | grep -qiE "$EXPECTED_GPU_MODEL_REGEX"; then
      model_ok=0
      mismatch_models="$mismatch_models[$name]"
    fi
  done <<< "$vbios_names"
else
  model_ok=0
  mismatch_models="(amd-smi static --vbios returned no vbios.name values)"
fi

if [ "$model_ok" = 1 ]; then
  add_test true "All GPUs match model regex /$EXPECTED_GPU_MODEL_REGEX/ (VBIOS name)"
else
  add_test false "All GPUs match model regex /$EXPECTED_GPU_MODEL_REGEX/ (VBIOS name)" \
    "GPU VBIOS name(s) do not match /$EXPECTED_GPU_MODEL_REGEX/: $mismatch_models" \
    "$(jq -n --arg r "$EXPECTED_GPU_MODEL_REGEX" --arg m "$mismatch_models" '{expected_regex: $r, matched_field: "vbios.name", mismatches: $m}')"
  mark_fail
fi

# 5. VRAM. Enforced as exact equality against EXPECTED_VRAM_MIB.
vram_json="$(amd-smi static --vram --json 2>/dev/null || true)"
vram_vals="$(echo "$vram_json" | jq -r '.gpu_data[].vram.size.value' 2>/dev/null | paste -sd, - || true)"
if [ "$EXPECTED_VRAM_MIB" -eq 0 ]; then
  add_test true "All GPUs report expected VRAM" \
    "VRAM check not yet calibrated for $GPU_MODEL — recorded for later calibration, not enforced" \
    "$(jq -n --arg v "$vram_vals" '{observed_vram_mib: $v}')" \
    "SKIP not yet calibrated"
else
  vram_ok=1
  mismatch_vram=""
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [ "$v" != "$EXPECTED_VRAM_MIB" ]; then
      vram_ok=0
      mismatch_vram="$mismatch_vram[$v]"
    fi
  done < <(echo "$vram_json" | jq -r '.gpu_data[].vram.size.value' 2>/dev/null)
  if [ "$vram_ok" = 1 ]; then
    add_test true "All GPUs report $EXPECTED_VRAM_MIB MiB VRAM"
  else
    add_test false "All GPUs report $EXPECTED_VRAM_MIB MiB VRAM" \
      "GPU(s) report unexpected VRAM size: $mismatch_vram" \
      "$(jq -n --argjson e "$EXPECTED_VRAM_MIB" --arg m "$mismatch_vram" '{expected_mib: $e, mismatches: $m}')"
    mark_fail
  fi
fi

jq --arg suite "$SUITE" '{ suite: $suite, tests: . }' "$results_tmp" > /results/prereqs.json

if [ "$fail" -ne 0 ]; then
  die "prereqs failed; halting suite"
fi
log "ok"
