{{/*
Copyright 2022 DZS Inc
*/}}

{{/*
App name generator
*/}}

{{- define "common.fullname" -}}
{{- $top := index . 0 -}}
{{- $svc := index . 1 -}}
{{- if $top.Values.natsFullnameOverride -}}
{{- $top.Values.natsFullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default $svc $top.Values.natsNameOverride -}}
{{- if contains $name $top.Release.Name -}}
{{- $top.Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" $top.Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Service name prefix for strimzi kafka
*/}}
{{- define "kafka.prefix" -}}
dzs-strimzi
{{- end -}}

{{/*
App name for strimzi kafka bootstrap
*/}}
{{- define "kafkaBootstrap.fullname" -}}
{{ include "kafka.prefix" . -}}-kafka-bootstrap
{{- end -}}

{{/*
FQDN for Kafka bootstrap
*/}}
{{- define "kafkaBootstrap.fqdn" -}}
{{ include "kafkaBootstrap.fullname" . -}}.{{- .Values.global.namespace.name }}
{{- end -}}

{{/*
App name for Launchpad platform service. Overrides definition defined by subcharts.
*/}}
{{- define "launchpad.fullname" -}}
{{ include "common.fullname" (list . "launchpad") -}}
{{- end -}}

{{/*
FQDN for Launchpad service (including the namespace)
*/}}
{{- define "launchpad.fqdn" -}}
{{ include "launchpad.fullname" . -}}.{{- .Values.global.namespace.name }}
{{- end -}}


{{/*
App name for NATS. Overrides definition defined by subcharts.
*/}}
{{- define "nats.fullname" -}}
{{ include "common.fullname" (list . "nats") -}}
{{- end -}}

{{/*
FQDN for NATS (including the namespace)
*/}}
{{- define "nats.fqdn" -}}
{{ include "nats.fullname" . -}}.{{- .Values.global.namespace.name }}
{{- end -}}

{{/*
App name for MongoDB. Overrides definition defined by subcharts.
*/}}
{{- define "mongodb.fullname" -}}
{{ include "common.fullname" (list . "mongodb") -}}
{{- end -}}

{{/*
FQDN for MongoDB (including the namespace)
*/}}
{{- define "mongodb.fqdn" -}}
{{ include "mongodb.fullname" . -}}.{{- .Values.global.namespace.name }}
{{- end -}}

{{/*
App name for Redis. Overrides definition defined by subcharts.
*/}}
{{- define "redis.fullname" -}}
{{ include "common.fullname" (list . "redis") -}}
{{- end -}}

{{/*
FQDN for Redis (including the namespace)
*/}}
{{- define "redis.fqdn" -}}
{{ include "redis.fullname" . -}}.{{- .Values.global.namespace.name }}
{{- end -}}

{{/*
App name for Redis. Overrides definition defined by subcharts.
*/}}
{{- define "redis-tunnel.fullname" -}}
{{ include "common.fullname" (list . "redis-tunnel") -}}
{{- end -}}

{{/*
App name for Prometheus
*/}}
{{- define "prometheus.fullname" -}}
{{ include "common.fullname" (list . "prometheus") -}}
{{- end -}}

{{/*
FQDN for Prometheus (including the namespace)
*/}}
{{- define "prometheus.fqdn" -}}
{{ include "prometheus.fullname" . -}}.{{- .Values.global.namespace.name }}
{{- end -}}

{{/*
App name for Grafana
*/}}
{{- define "grafana.fullname" -}}
{{ include "common.fullname" (list . "grafana") -}}
{{- end -}}

{{/*
FQDN for Grafana (including the namespace)
*/}}
{{- define "grafana.fqdn" -}}
{{ include "grafana.fullname" . -}}.{{- .Values.global.namespace.name }}
{{- end -}}

{{/*
App name for sftp
*/}}
{{- define "sftp.fullname" -}}
{{ include "common.fullname" (list . "sftp") -}}
{{- end -}}

{{/*
FQDN for sftp (including the namespace)
*/}}
{{- define "sftp.fqdn" -}}
{{ include "sftp.fullname" . -}}.{{- .Values.global.namespace.name }}
{{- end -}}

{{/*
App name for ftp
*/}}
{{- define "ftp.fullname" -}}
{{ include "common.fullname" (list . "ftp") -}}
{{- end -}}

{{/*
FQDN for ftp (including the namespace)
*/}}
{{- define "ftp.fqdn" -}}
{{ include "ftp.fullname" . -}}.{{- .Values.global.namespace.name }}
{{- end -}}

{{/*
 Namespace where AEO runs. Overrides the one defined in subchart.
*/}}
{{- define "aeo.namespace" -}}
{{- if .Values.global.aeoNamespacePrefix -}}
{{- printf "%s-%s" .Values.global.aeoNamespacePrefix .Values.global.namespace.name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{ .Values.global.namespace.name | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{-  end -}}

{{/*
 Namespace where SDNC runs. Overrides the one defined in subchart.
*/}}
{{- define "sdnc.namespace" -}}
{{- if .Values.global.sdncNamespacePrefix -}}
{{- printf "%s-%s" .Values.global.sdncNamespacePrefix .Values.global.namespace.name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{ .Values.global.namespace.name | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{-  end -}}

{{/*
App name for SDNC Config Mgr.
*/}}
{{- define "rnc-config-mgr.fullname" -}}
{{ include "common.fullname" (list . "sdnc-config-mgr") -}}
{{- end -}}

{{/*
App name for SDNC Config Mgr FQDN.
*/}}
{{- define "rnc-config-mgr.fqdn" -}}
{{ include "rnc-config-mgr.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC Alarm Svc.
*/}}
{{- define "rnc-alarm-svc.fullname" -}}
{{ include "common.fullname" (list . "sdnc-alarm-svc") -}}
{{- end -}}

{{/*
App name for SDNC alarm-svc FQDN.
*/}}
{{- define "rnc-alarm-svc.fqdn" -}}
{{ include "rnc-alarm-svc.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC Netconf service.
*/}}
{{- define "rnc-netconf-svc.fullname" -}}
{{ include "common.fullname" (list . "sdnc-netconf-svc") -}}
{{- end -}}

{{/*
App name for SDNC Netcon Service FQDN.
*/}}
{{- define "rnc-netconf-svc.fqdn" -}}
{{ include "rnc-netconf-svc.fullname" . -}}.{{-  include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC Inventory Mgr.
*/}}
{{- define "rnc-inventory-mgr.fullname" -}}
{{ include "common.fullname" (list . "sdnc-inventory-mgr") -}}
{{- end -}}

{{/*
App name for SDNC Inventory Mgr FQDN.
*/}}
{{- define "rnc-inventory-mgr.fqdn" -}}
{{ include "rnc-inventory-mgr.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC File Mgr.
*/}}
{{- define "file-mgr.fullname" -}}
{{ include "common.fullname" (list . "sdnc-file-mgr") -}}
{{- end -}}

{{/*
App name for SDNC File Mgr FQDN.
*/}}
{{- define "file-mgr.fqdn" -}}
{{ include "file-mgr.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC Task Mgr.
*/}}
{{- define "task-mgr.fullname" -}}
{{ include "common.fullname" (list . "sdnc-task-mgr") -}}
{{- end -}}

{{/*
App name for SDNC Task Mgr FQDN.
*/}}
{{- define "task-mgr.fqdn" -}}
{{ include "task-mgr.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC PM Collector.
*/}}
{{- define "pm-collector.fullname" -}}
{{ include "common.fullname" (list . "sdnc-pm-collector") -}}
{{- end -}}

{{/*
App name for SDNC PM Collector FQDN.
*/}}
{{- define "pm-collector.fqdn" -}}
{{ include "pm-collector.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC gnpy.
*/}}
{{- define "gnpy.fullname" -}}
{{ include "common.fullname" (list . "sdnc-gnpy") -}}
{{- end -}}

{{/*
App name for SDNC gnpy FQDN.
*/}}
{{- define "gnpy.fqdn" -}}
{{ include "gnpy.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC InfluxDB.
*/}}
{{- define "influxdb.fullname" -}}
{{ include "common.fullname" (list . "sdnc-influxdb") -}}
{{- end -}}

{{/*
App name for SDNC influxdb FQDN.
*/}}
{{- define "influxdb.fqdn" -}}
{{ include "influxdb.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC Artifactory.
*/}}
{{- define "artifactory.fullname" -}}
{{ include "common.fullname" (list . "sdnc-artifactory") -}}
{{- end -}}

{{/*
App name for SDNC artifactory FQDN.
*/}}
{{- define "artifactory.fqdn" -}}
{{ include "artifactory.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC TransportPCE.
*/}}
{{- define "rnc-transportpce.fullname" -}}
{{ include "common.fullname" (list . "sdnc-transportpce") -}}
{{- end -}}

{{/*
App name for SDNC transportpce FQDN.
*/}}
{{- define "rnc-transportpce.fqdn" -}}
{{ include "rnc-transportpce.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
App name for SDNC BE UI.
*/}}
{{- define "sdnc-connector.fullname" -}}
{{ include "common.fullname" (list . "sdnc-ui") -}}
{{- end -}}

{{/*
App name for SDNC BE UI FQDN.
*/}}
{{- define "sdnc-connector.fqdn" -}}
{{ include "sdnc-connector.fullname" . -}}.{{- include "sdnc.namespace" . }}
{{- end -}}

{{/*
 Namespace where ZMS runs. Overrides the one defined in subchart.
*/}}
{{- define "zms.namespace" -}}
{{- if .Values.global -}}
{{- if .Values.global.zmsNamespacePrefix -}}
{{- printf "%s-%s" .Values.global.zmsNamespacePrefix .Values.global.namespace.name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{ .Values.global.namespace.name | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- else -}}
{{ .Release.Namespace }}
{{- end -}}
{{-  end -}}

{{/*
App name for ZMS.
*/}}
{{- define "zms.fullname" -}}
{{ include "common.fullname" (list . "zms") -}}
{{- end -}}

{{/*
App name for ZMS FQDN.
*/}}
{{- define "zms.fqdn" -}}
{{ include "zms.fullname" . -}}.{{- include "zms.namespace" . }}
{{- end -}}

{{/*
 Namespace where INAS runs. Overrides the one defined in subchart.
*/}}
{{- define "inas.namespace" -}}
{{- if .Values.global -}}
{{- if .Values.global.inasNamespacePrefix -}}
{{- printf "%s-%s" .Values.global.inasNamespacePrefix .Values.global.namespace.name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{ .Values.global.namespace.name | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- else -}}
{{ .Release.Namespace }}
{{- end -}}
{{-  end -}}

{{/*
App name for INAS.
*/}}
{{- define "inas-be.fullname" -}}
{{ include "common.fullname" (list . "inas2-be") -}}
{{- end -}}

{{/*
App name for INAS FQDN.
*/}}
{{- define "inas-be.fqdn" -}}
{{ include "inas-be.fullname" . -}}.{{- include "inas.namespace" . }}
{{- end -}}

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

{{- define "postgres.fullname" -}}
{{ include "common.fullname" (list . "postgres") -}}
{{- end }}

{{- define "postgres.fqdn" -}}
{{ include "postgres.fullname" . -}}.{{- include "inas.namespace" . }}
{{- end -}}

{{/*
Kafka Socket
*/}}
{{- define "kafka.socket" -}}
{{- if .Values.global -}}
{{- if (ne "" .Values.global.kafkaExtIp) -}}
{{- .Values.global.kafkaExtIp -}}
{{- else -}}
{{ include "kafkaBootstrap.fqdn" . -}}:9092
{{- end -}}
{{- end -}}
{{- end -}}