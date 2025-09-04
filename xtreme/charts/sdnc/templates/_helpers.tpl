# Copyright 2025 DZS Inc
{{/*
Expand the name of the chart.
*/}}
{{- define "lighty-rnc-app-helm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "lighty-rnc-app-helm.fullname" -}}
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
{{- define "lighty-rnc-app-helm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "lighty-rnc-app-helm.labels" -}}
helm.sh/chart: {{ include "lighty-rnc-app-helm.chart" . }}
{{ include "lighty-rnc-app-helm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "lighty-rnc-app-helm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "lighty-rnc-app-helm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{ .Values.lighty.akka.discovery.podSelectorName }}: {{ .Values.lighty.akka.discovery.podSelectorValue }}
{{- end }}

{{/*
Return the correct storageClassName for a PVC:
- Checks the subchart’s path first (passed in via dict)
- Falls back to .Values.global.pvcmetadata.storageClass
*/}}
{{- define "parent-chart.resolveStorageClass" -}}
{{- if .local }}
storageClassName: {{ .local | quote }}
{{- else if and .Values (kindIs "map" .Values.global) (hasKey .Values.global "pvcmetadata") (kindIs "map" .Values.global.pvcmetadata) (hasKey .Values.global.pvcmetadata "storageClass") }}
storageClassName: {{ .Values.global.pvcmetadata.storageClass | quote }}
{{- else }}
storageClassName: null
{{- end }}
{{- end }}


{{- define "parent-chart.resolvePceNetconfStorageClass" -}}
{{- if .Values.global.pvcmetadata.pceNetconfConfigmgr.storageClass }}
storageClassName: {{ tpl .Values.global.pvcmetadata.pceNetconfConfigmgr.storageClass . | quote }}
{{- else if .Values.global.pvcmetadata.storageClass }}
storageClassName: {{ tpl .Values.global.pvcmetadata.storageClass . | quote }}
{{- else }}
storageClassName: null
{{- end }}
{{- end }}


{{- define "parent-chart.resolveLogPceNetconfStorageClass" -}}
{{- if .Values.global.pvcmetadata.logPceNetconfConfigmgr.storageClass }}
storageClassName: {{ tpl .Values.global.pvcmetadata.logPceNetconfConfigmgr.storageClass . | quote }}
{{- else if .Values.global.pvcmetadata.storageClass }}
storageClassName: {{ tpl .Values.global.pvcmetadata.storageClass . | quote }}
{{- else }}
storageClassName: null
{{- end }}
{{- end }}


{{- define "parent-chart.resolvePersistenceStorageClass" -}}
{{- if .Values.global.pvcmetadata.persistence.storageClass }}
storageClassName: {{ .Values.global.pvcmetadata.persistence.storageClass | quote }}
{{- else if .Values.global.pvcmetadata.storageClass }}
storageClassName: {{ tpl .Values.global.pvcmetadata.storageClass . | quote }}
{{- else }}
storageClassName: null
{{- end }}
{{- end }}


{{- define "parent-chart.resolvePersistenceFtpStorageClass" -}}
{{- if .Values.global.pvcmetadata.persistenceFtp.storageClass }}
storageClassName: {{ .Values.global.pvcmetadata.persistenceFtp.storageClass | quote }}
{{- else if .Values.global.pvcmetadata.storageClass }}
storageClassName: {{ tpl .Values.global.pvcmetadata.storageClass . | quote }}
{{- else }}
storageClassName: null
{{- end }}
{{- end }}

