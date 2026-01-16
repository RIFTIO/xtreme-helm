{{/*
Expand the name of the chart.
*/}}
{{- define "llm-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "llm-stack.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "llm-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "llm-stack.labels" -}}
helm.sh/chart: {{ include "llm-stack.chart" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Ollama image name
*/}}
{{- define "llm-stack.ollama.image" -}}
{{- printf "%s/%s:%s" .Values.global.imageRegistry .Values.ollama.image.repository .Values.ollama.image.tag }}
{{- end }}

{{/*
Open WebUI image name
*/}}
{{- define "llm-stack.openwebui.image" -}}
{{- printf "%s/%s:%s" .Values.global.imageRegistry .Values.openWebui.image.repository .Values.openWebui.image.tag }}
{{- end }}
