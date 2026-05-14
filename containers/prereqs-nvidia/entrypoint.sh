#!/usr/bin/env bash
# Real prereqs for the nvidia-* family.
# Halts the compose stack on any failure by exiting non-zero (depends_on:
# service_completed_successfully). Writes /results/prereqs.json with one TAP
# point per check.
SUITE=prereqs
source /lib/result.sh
source /lib/nvidia_models.sh

: "${GPU_COUNT:?GPU_COUNT is not set}"

results_tmp="$(mktemp)"
trap 'rm -f "$results_tmp"' EXIT
printf '[]' > "$results_tmp"

# add_test <ok:true|false> <name> <diag-or-empty>
add_test() {
  local ok="$1" name="$2" diag="${3:-}"
  if [ -n "$diag" ]; then
    jq --argjson ok "$ok" --arg name "$name" --arg diag "$diag" \
       '. + [{ ok: $ok, name: $name, diagnostic: { detail: $diag } }]' \
       "$results_tmp" > "$results_tmp.next"
  else
    jq --argjson ok "$ok" --arg name "$name" \
       '. + [{ ok: $ok, name: $name, diagnostic: null }]' \
       "$results_tmp" > "$results_tmp.next"
  fi
  mv "$results_tmp.next" "$results_tmp"
}

fail=0
mark_fail() { fail=1; }

# 1. nvidia-smi responds at all.
smi_out=""
if smi_out="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>&1)"; then
  add_test true "nvidia-smi responds" ""
else
  add_test false "nvidia-smi responds" "$smi_out"
  mark_fail
fi

# 2. NVIDIA container runtime visible (CUDA libs injected = runtime worked).
if [ -e /dev/nvidia0 ] || [ -e /dev/nvidiactl ]; then
  add_test true "NVIDIA runtime exposes /dev/nvidia*" ""
else
  add_test false "NVIDIA runtime exposes /dev/nvidia*" "no /dev/nvidia* device nodes inside container"
  mark_fail
fi

# 3. fabricmanager state (per nvidia-smi -q "Fabric").
fabric_state="$(nvidia-smi -q 2>/dev/null | awk -F': ' '/^[[:space:]]*State[[:space:]]*:/ && seen {print $2; exit} /Fabric/ {seen=1}' | tr -d '[:space:]')"
case "$fabric_state" in
  Completed|InProgress)
    add_test true "nvidia-fabricmanager state ($fabric_state)" ""
    ;;
  "")
    # Not all SKUs report a fabric block; treat absence as pass on non-NVSwitch boxes.
    add_test true "nvidia-fabricmanager state (n/a on this SKU)" ""
    ;;
  *)
    add_test false "nvidia-fabricmanager state ($fabric_state)" "expected Completed or InProgress"
    mark_fail
    ;;
esac

# 4. GPU count.
seen_count=0
if [ -n "$smi_out" ]; then
  seen_count="$(printf '%s\n' "$smi_out" | grep -c .)"
fi
if [ "$seen_count" -eq "$GPU_COUNT" ]; then
  add_test true "GPU count == $GPU_COUNT" ""
else
  add_test false "GPU count == $GPU_COUNT" "saw $seen_count GPUs"
  mark_fail
fi

# 5. Model + memory per GPU.
model_ok=1
mem_ok=1
mismatch_models=""
mismatch_mems=""
if [ -n "$smi_out" ]; then
  while IFS=',' read -r name mem; do
    name="$(echo "$name" | sed 's/^ *//;s/ *$//')"
    mem="$(echo "$mem" | sed 's/^ *//;s/ *$//')"
    if ! echo "$name" | grep -q "$EXPECTED_GPU_MODEL_REGEX"; then
      model_ok=0
      mismatch_models="$mismatch_models[$name]"
    fi
    if [ "$mem" != "$EXPECTED_MEM_MIB" ]; then
      mem_ok=0
      mismatch_mems="$mismatch_mems[$mem]"
    fi
  done <<< "$smi_out"
fi

if [ "$model_ok" = 1 ]; then
  add_test true "All GPUs match model regex /$EXPECTED_GPU_MODEL_REGEX/" ""
else
  add_test false "All GPUs match model regex /$EXPECTED_GPU_MODEL_REGEX/" "mismatch: $mismatch_models"
  mark_fail
fi

if [ "$mem_ok" = 1 ]; then
  add_test true "All GPUs report $EXPECTED_MEM_MIB MiB memory" ""
else
  add_test false "All GPUs report $EXPECTED_MEM_MIB MiB memory" "mismatch: $mismatch_mems"
  mark_fail
fi

# Compose final result file.
jq --arg suite "$SUITE" '{ suite: $suite, tests: . }' "$results_tmp" > /results/prereqs.json

if [ "$fail" -ne 0 ]; then
  die "prereqs failed; halting suite"
fi
log "ok"
