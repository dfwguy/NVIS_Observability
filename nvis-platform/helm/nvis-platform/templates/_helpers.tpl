{{/*
=============================================================================
_helpers.tpl — Shared template helpers for nvis-platform chart
=============================================================================
*/}}

{{/*
Chart name (sanitized, trimmed to 63 chars)
*/}}
{{- define "nvis-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Full-qualified app name. If release name already contains chart name,
returns release name; otherwise concatenates them. Trimmed to 63 chars.
*/}}
{{- define "nvis-platform.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart version label
*/}}
{{- define "nvis-platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every resource
*/}}
{{- define "nvis-platform.labels" -}}
helm.sh/chart: {{ include "nvis-platform.chart" . }}
app.kubernetes.io/name: {{ include "nvis-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: nvis-platform
{{- end -}}

{{/*
Selector labels — stable identity across upgrades (do NOT add version here)
*/}}
{{- define "nvis-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nvis-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Image reference helper — prefers .Values.image.registry, falls back to ghcr.io/nvidia-nvis
Usage:
  {{ include "nvis-platform.image" (dict "root" . "repo" "prom/prometheus" "tag" "v2.54.1") }}
*/}}
{{- define "nvis-platform.image" -}}
{{- $registry := .root.Values.image.registry -}}
{{- if $registry -}}
{{ $registry }}/{{ .repo }}:{{ .tag }}
{{- else -}}
{{ .repo }}:{{ .tag }}
{{- end -}}
{{- end -}}

{{/*
Image tag fallback: .Values.image.tag, else .Chart.AppVersion
*/}}
{{- define "nvis-platform.imageTag" -}}
{{- if .Values.image.tag -}}
{{ .Values.image.tag }}
{{- else -}}
{{ .Chart.AppVersion }}
{{- end -}}
{{- end -}}

{{/*
Image pull secrets block
*/}}
{{- define "nvis-platform.imagePullSecrets" -}}
{{- if .Values.image.pullSecrets }}
imagePullSecrets:
{{- range .Values.image.pullSecrets }}
  - name: {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}
