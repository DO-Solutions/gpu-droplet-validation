{{/*
gdv.fullname — release-scoped chart name, DNS-safe, <=63 chars.
Call with the root context (".").
*/}}
{{- define "gdv.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
gdv.sanitize — lower-case a node name into a DNS-1123-safe fragment.
*/}}
{{- define "gdv.sanitize" -}}
{{- $s := regexReplaceAll "[^a-z0-9-]" (lower .) "-" -}}
{{- $s | trimAll "-" | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{/*
gdv.jobName — per-node Job name. dict: root, node (may be "").
*/}}
{{- define "gdv.jobName" -}}
{{- $base := printf "%s-gdv" .root.Release.Name -}}
{{- if .node -}}
{{- printf "%s-%s" $base (include "gdv.sanitize" .node) | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $base | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
gdv.image — full image ref. dict: root, name.
*/}}
{{- define "gdv.image" -}}
{{- $img := .root.Values.image -}}
{{- printf "%s/%s/%s:%s" $img.registry $img.repoPrefix .name $img.version -}}
{{- end -}}

{{/*
gdv.commonEnv — the env block every container shares (mirrors compose
x-common-env). dict: root, node, runId. Emitted as a list of env entries;
the caller nindents it under `env:`.
*/}}
{{- define "gdv.commonEnv" -}}
- name: RUN_ID
  value: {{ .runId | quote }}
- name: GPU_MODEL
  value: {{ .root.Values.gpuModel | quote }}
- name: GPU_COUNT
  value: {{ .root.Values.gpuCount | quote }}
- name: NODE_ID
  value: {{ .root.Values.nodeId | default .node | quote }}
- name: REGION
  value: {{ .root.Values.region | quote }}
{{- end -}}

{{/*
gdv.tolerations — merge GPU-taint + cordoned + user-extra tolerations into a
single YAML list (or [] when none). dict: root, gpuTaintKey.
*/}}
{{- define "gdv.tolerations" -}}
{{- $t := .root.Values.tolerations -}}
{{- $list := list -}}
{{- if and $t.gpuTaint .gpuTaintKey -}}
{{- $list = append $list (dict "key" .gpuTaintKey "operator" "Equal" "value" "true" "effect" "NoSchedule") -}}
{{- end -}}
{{- if $t.allowCordoned -}}
{{- $list = append $list (dict "key" "node.kubernetes.io/unschedulable" "operator" "Exists" "effect" "NoSchedule") -}}
{{- end -}}
{{- range $t.extra -}}
{{- $list = append $list . -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}

{{/*
gdv.stageList — the model -> ordered-stage mapping. This is the single seam
that keeps one chart for AMD/NVIDIA/test: adding a model is one arm here, no
new template files (mirrors the repo's one-image-set philosophy). Emits YAML
consumed via `include "gdv.stageList" . | fromYaml`.

Keys:
  gpu          bool   — GPU stages need device-plugin resource + securityContext
  gpuResource  string — device-plugin resource name (e.g. amd.com/gpu)
  gpuTaintKey  string — taint key to tolerate (e.g. amd.com/gpu); "" = none
  main         string — image name for the main (tap-reporter) container
  init         list   — ordered initContainers: {name, image, env?}
*/}}
{{- define "gdv.stageList" -}}
{{- $m := .Values.gpuModel -}}
{{- if hasPrefix "amd-" $m -}}
gpu: true
gpuResource: {{ .Values.resources.gpuResourceName | default "amd.com/gpu" }}
gpuTaintKey: "amd.com/gpu"
main: tap-reporter
init:
  - name: prereqs
    image: prereqs-amd
  - name: setup
    image: setup-amd
  - name: rvs
    image: rvs
    env:
      RVS_TIMEOUT: {{ .Values.rvsTimeout | quote }}
  - name: rccl-allreduce
    image: rccl-tests-amd
    env:
      RCCL_TEST: allreduce
  - name: rccl-alltoall
    image: rccl-tests-amd
    env:
      RCCL_TEST: alltoall
  - name: teardown
    image: teardown-amd
{{- else if hasPrefix "nvidia-" $m -}}
gpu: true
gpuResource: {{ .Values.resources.gpuResourceName | default "nvidia.com/gpu" }}
gpuTaintKey: "nvidia.com/gpu"
main: tap-reporter
init:
  - name: prereqs
    image: prereqs-nvidia
  - name: setup
    image: setup-nvidia
  - name: dcgm-diag
    image: dcgm-diag
  - name: nccl-allreduce
    image: nccl-tests-nvidia
    env:
      NCCL_TEST: allreduce
  - name: nccl-alltoall
    image: nccl-tests-nvidia
    env:
      NCCL_TEST: alltoall
  - name: teardown
    image: teardown-nvidia
{{- else if eq $m "test" -}}
gpu: false
gpuResource: ""
gpuTaintKey: ""
main: tap-reporter
init:
  - name: prereqs
    image: prereqs-test
  - name: setup
    image: setup-test
  - name: mock-test
    image: mock-test
  - name: teardown
    image: teardown-test
{{- else -}}
{{- fail (printf "unsupported gpuModel %q (expected: test | amd-* | nvidia-*)" $m) -}}
{{- end -}}
{{- end -}}
