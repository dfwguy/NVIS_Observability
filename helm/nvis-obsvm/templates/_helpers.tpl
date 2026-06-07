{{/*
=============================================================================
_helpers.tpl — Shared template helpers for nvis-obsvm chart
=============================================================================
*/}}

{{/*
Image reference helper — prepends imageRegistry if set.
Usage:
  {{ include "nvis.image" (dict "root" . "repo" .Values.prometheus.image.repository "tag" .Values.prometheus.image.tag) }}
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
Common labels applied to every resource
*/}}
{{- define "nvis-obsvm.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: nvis-observability
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Selector labels — used in matchLabels (must be stable across upgrades)
*/}}
{{- define "nvis-obsvm.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .release }}
{{- end -}}

{{/*
Namespace helper — use Values.namespace
*/}}
{{- define "nvis.namespace" -}}
{{ .Values.namespace }}
{{- end -}}

{{/*
Security context for non-root containers (fsGroup set at pod level)
*/}}
{{- define "nvis.containerSecurityContext" -}}
securityContext:
  runAsNonRoot: {{ .Values.securityContext.runAsNonRoot }}
  runAsUser: {{ .Values.securityContext.runAsUser }}
  runAsGroup: {{ .Values.securityContext.runAsGroup }}
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
{{- end -}}

{{/*
Pod security context (sets fsGroup so mounted volumes are writable)
*/}}
{{- define "nvis.podSecurityContext" -}}
securityContext:
  runAsNonRoot: {{ .Values.securityContext.runAsNonRoot }}
  runAsUser: {{ .Values.securityContext.runAsUser }}
  runAsGroup: {{ .Values.securityContext.runAsGroup }}
  fsGroup: {{ .Values.securityContext.runAsGroup }}
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{/*
Storage backend — returns "victoria" or "thanos"
*/}}
{{- define "nvis.storage" -}}
{{ .Values.storage | default "victoria" }}
{{- end -}}

{{/*
Returns the Prometheus remote_write URL depending on storage backend
*/}}
{{- define "nvis.remoteWriteURL" -}}
{{- if eq (include "nvis.storage" .) "thanos" -}}
http://nvis-thanos-receive.{{ .Values.namespace }}.svc:{{ .Values.thanos.receive.port }}/api/v1/receive
{{- else -}}
http://nvis-victoriametrics.{{ .Values.namespace }}.svc:{{ .Values.victoriametrics.port }}/api/v1/write
{{- end -}}
{{- end -}}
