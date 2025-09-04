{{/* Copyright 2020 RIFT Inc */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "launchpad.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Check if the IP address is valid either IPV4 or IPV6
retutns false if IP address is not in valid format
*/}}
{{- define "isIPchk" -}}
{{- $ipAddress := . -}}
{{- $ipv4Pattern := "^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$" -}}
{{- $ipv6Pattern := "^[0-9a-fA-F]{0,4}(:[0-9a-fA-F]{0,4}){0,7}$" -}}
{{- if or (regexMatch $ipv4Pattern $ipAddress) (regexMatch $ipv6Pattern $ipAddress) -}}
  true
{{- else -}}
  false
{{- end -}}
{{- end -}}


{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "launchpad.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "launchpad.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "launchpad.labels" -}}
helm.sh/chart: {{ include "launchpad.chart" . }}
{{ include "launchpad.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | replace "+" "_" | trunc 63 | trimSuffix "-"| quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "launchpad.selectorLabels" -}}
app.kubernetes.io/name: {{ include "launchpad.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "launchpad.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "launchpad.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{- define "launchpad.coreDir" -}}
{{- if .Values.launchpad.coreDir -}}
{{- .Values.launchpad.coreDir | quote -}}
{{- else -}}
{{-  printf "/usr/rift/var/rift" | quote -}}
{{- end -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "grafana.fullname" -}}
{{- if .Values.grafanaFullnameOverride -}}
{{- .Values.grafanaFullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "grafana" .Values.grafanaNameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
App name for Prometheus
*/}}

{{- define "prometheus.fullname" -}}
{{- if .Values.prometheusFullnameOverride -}}
{{- .Values.prometheusFullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "prometheus" .Values.prometheusNameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
App name for Redis
*/}}

{{- define "redis.fullname" -}}
{{- if .Values.redisFullnameOverride -}}
{{- .Values.redisFullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "redis" .Values.redisNameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
App name for NATS
*/}}

{{- define "nats.fullname" -}}
{{- if .Values.natsFullnameOverride -}}
{{- .Values.natsFullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "nats" .Values.natsNameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
App name for Alert Manager
*/}}

{{- define "alertmgr.fullname" -}}
{{- if .Values.alertmgrFullnameOverride -}}
{{- .Values.alertmgrFullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "alertmgr" .Values.alertmgrNameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
App name for Mongo
*/}}

{{- define "mongodb.fullname" -}}
{{- if .Values.mongodbFullnameOverride -}}
{{- .Values.mongodbFullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "mongodb" .Values.mongodbNameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
App name for HAProxy
*/}}

{{- define "haproxy.fullname" -}}
{{- if .Values.haproxyFullnameOverride -}}
{{- .Values.haproxyFullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "haproxy-ingress" .Values.haproxyNameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
App name for HAProxy metrics service
*/}}

{{- define "haproxy-metrics.fullname" -}}
{{- if .Values.haproxymetricsFullnameOverride -}}
{{- .Values.haproxymetricsFullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "haproxy-metrics" .Values.haproxymetricsNameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
App name for Loki
*/}}

{{- define "loki.fullname" -}}
{{- if .Values.lokiFullnameOverride -}}
{{- .Values.lokiFullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "loki" .Values.lokiNameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}
