{{/*
Image reference helper — prepends imageRegistry if set.
Usage: {{ include "nvis.image" (dict "root" . "repo" .Values.dcgmExporter.image.repository "tag" .Values.dcgmExporter.image.tag) }}
*/}}
{{- define "nvis.image" -}}
{{- $registry := .root.Values.imageRegistry -}}
{{- if $registry -}}
{{ $registry }}/{{ .repo }}:{{ .tag }}
{{- else -}}
{{ .repo }}:{{ .tag }}
{{- end -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "nvis-gpu-agents.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
nvis/cluster: {{ .Values.cluster }}
{{- end -}}
