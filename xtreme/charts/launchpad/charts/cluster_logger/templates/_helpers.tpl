{{/*
# Copyright 2022 DZS Inc
*/}}

{{/*
App name for Mongo
*/}}

{{- define "mongodb.fullname" -}}
{{- $name := default "mongodb" .Values.mongodbNameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
