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

# add_test <ok:true|false> <name> [message] [structured-json]
# Convention: every not-ok diagnostic MUST start with a human-readable
# `message` field (a single sentence describing the failure). Additional
# structured fields can follow. Passing points use a null diagnostic.
add_test() {
  local ok="$1" name="$2" msg="${3:-}" structured="${4:-null}"
  if [ -n "$msg" ]; then
    jq --argjson ok "$ok" --arg name "$name" --arg msg "$msg" --argjson s "$structured" \
       '. + [{ ok: $ok, name: $name, diagnostic: ({ message: $msg } + (if $s == null then {} else $s end)) }]' \
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
  add_test true "nvidia-smi responds"
else
  add_test false "nvidia-smi responds" \
    "nvidia-smi failed to query GPUs — driver not loaded or runtime not wired" \
    "$(jq -n --arg err "$smi_out" '{error: $err}')"
  mark_fail
fi

# 2. NVIDIA container runtime visible (CUDA libs injected = runtime worked).
if [ -e /dev/nvidia0 ] || [ -e /dev/nvidiactl ]; then
  add_test true "NVIDIA runtime exposes /dev/nvidia*"
else
  add_test false "NVIDIA runtime exposes /dev/nvidia*" \
    "no /dev/nvidia* device nodes inside container — nvidia-container-toolkit did not inject GPU devices"
  mark_fail
fi

# 3. NVSwitch fabric state (nvidia-fabricmanager).
#
# Only "Completed" counts. "In Progress" used to pass here so a fabricmanager
# still initializing when the suite starts wouldn't fail the run — but that
# also let through a host whose fabricmanager never started at all, because
# the state then sits at "In Progress" forever. That is exactly the B300 case
# where the service dies waiting on /sys/class/infiniband: prereqs passed, and
# the failure only surfaced 30 minutes later as NCCL "system not yet
# initialized", which killed the stack before it could report anything.
#
# Wait out the legitimate race instead of accepting its symptom: poll until
# every GPU reports Completed, then fail once the window expires.
FABRIC_READY_TIMEOUT="${FABRIC_READY_TIMEOUT:-60}"

# One fabric state per GPU, one per line, whitespace-trimmed.
fabric_states() {
  local out
  out="$(nvidia-smi --query-gpu=fabric.state --format=csv,noheader 2>/dev/null)" || out=""
  if [ -n "$out" ] && ! printf '%s\n' "$out" | grep -q '\[Not Supported\]'; then
    printf '%s\n' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    return 0
  fi
  # Drivers without the fabric.state query field: parse the per-GPU "Fabric"
  # block out of the long-form dump. Match the section header as a bare
  # "Fabric" line so the earlier "GPU Fabric GUID" field doesn't trip it.
  nvidia-smi -q 2>/dev/null | awk '
    /^[[:space:]]*Fabric[[:space:]]*$/ { in_fabric = 1; next }
    in_fabric && /^[[:space:]]*State[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; in_fabric = 0
    }'
}

# Distinct states seen, comma-separated — what the diagnostic reports.
fabric_summary() { fabric_states | sort -u | tr '\n' ',' | sed 's/,$//'; }

# True only when at least one GPU reported and every GPU says Completed.
fabric_all_completed() {
  local states
  states="$(fabric_states)"
  [ -n "$states" ] || return 1
  ! printf '%s\n' "$states" | grep -qv '^Completed$'
}

if [ "${REQUIRES_NVSWITCH_FABRIC:-0}" = "1" ]; then
  fabric_ok=0
  fabric_deadline=$(( $(date +%s) + FABRIC_READY_TIMEOUT ))
  while :; do
    if fabric_all_completed; then fabric_ok=1; break; fi
    [ "$(date +%s)" -lt "$fabric_deadline" ] || break
    log "fabric state not Completed yet ($(fabric_summary || true)); waiting"
    sleep 5
  done
  fabric_seen="$(fabric_summary || true)"
  if [ "$fabric_ok" = 1 ]; then
    add_test true "nvidia-fabricmanager fabric state == Completed on all GPUs"
  else
    add_test false "nvidia-fabricmanager fabric state == Completed on all GPUs" \
      "fabric state is '${fabric_seen:-<none>}' after ${FABRIC_READY_TIMEOUT}s, expected Completed on every GPU — nvidia-fabricmanager is not running or never finished; collectives will fail with 'system not yet initialized'" \
      "$(jq -n --arg s "${fabric_seen:-}" --argjson t "$FABRIC_READY_TIMEOUT" \
         '{states_seen: $s, expected: "Completed", waited_seconds: $t}')"
    mark_fail
  fi
else
  # Non-NVSwitch SKU: there is no fabric to initialize.
  add_test true "nvidia-fabricmanager fabric state (n/a on this SKU)"
fi

# 4. GPU count.
seen_count=0
if [ -n "$smi_out" ]; then
  seen_count="$(printf '%s\n' "$smi_out" | grep -c .)"
fi
if [ "$seen_count" -eq "$GPU_COUNT" ]; then
  add_test true "GPU count == $GPU_COUNT"
else
  add_test false "GPU count == $GPU_COUNT" \
    "expected $GPU_COUNT GPUs, saw $seen_count" \
    "$(jq -n --argjson e "$GPU_COUNT" --argjson o "$seen_count" '{expected: $e, observed: $o}')"
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
  add_test true "All GPUs match model regex /$EXPECTED_GPU_MODEL_REGEX/"
else
  add_test false "All GPUs match model regex /$EXPECTED_GPU_MODEL_REGEX/" \
    "GPU model(s) do not match /$EXPECTED_GPU_MODEL_REGEX/: $mismatch_models" \
    "$(jq -n --arg r "$EXPECTED_GPU_MODEL_REGEX" --arg m "$mismatch_models" '{expected_regex: $r, mismatches: $m}')"
  mark_fail
fi

if [ "$mem_ok" = 1 ]; then
  add_test true "All GPUs report $EXPECTED_MEM_MIB MiB memory"
else
  add_test false "All GPUs report $EXPECTED_MEM_MIB MiB memory" \
    "GPU(s) report unexpected memory size: $mismatch_mems" \
    "$(jq -n --argjson e "$EXPECTED_MEM_MIB" --arg m "$mismatch_mems" '{expected_mib: $e, mismatches: $m}')"
  mark_fail
fi

# Compose final result file.
jq --arg suite "$SUITE" '{ suite: $suite, tests: . }' "$results_tmp" > /results/prereqs.json

if [ "$fail" -ne 0 ]; then
  die_with_failures /results/prereqs.json \
    "prereqs failed" \
    "prereqs failed; halting suite"
fi
log "ok"
