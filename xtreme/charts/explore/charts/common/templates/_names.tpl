{{/*
Copyright 2022 DZS Inc
*/}}

{{/*
 Namespace where Explore App runs. Overrides the one defined in subchart.
*/}}
{{- define "explore-application.namespace" -}}
{{- if .Values.global -}}
{{- if .Values.global.exploreNamespacePrefix -}}
{{- printf "%s-%s" .Values.global.exploreNamespacePrefix .Values.global.namespace.name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{ .Values.global.namespace.name | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- else -}}
{{ .Release.Namespace }}
{{- end -}}
{{-  end -}}

{{/*
App name for Explore App.
*/}}
{{- define "explore-application.fullname" -}}
{{ include "common.fullname" (list . "explore-app") -}}
{{- end -}}

{{/*
App name for Explore FQDN.
*/}}
{{- define "explore-application.fqdn" -}}
{{ include "explore-application.fullname" . -}}.{{- include "explore-application.namespace" . }}
{{- end -}}

{{/*
 Namespace where Explore App runs. Overrides the one defined in subchart.
*/}}
{{- define "explore.namespace" -}}
{{ include "explore-application.namespace" . -}}
{{- end -}}
