# Copyright 2025 DZS Inc
{{/*
Default Template for pvc_sdnclog. All Sub-Charts under this Chart can include the below template.
*/}}
{{- define "parent-chart.pvc_sdnclogtemplate" }}
apiVersion: v1
kind: {{ .Values.sdnc.volume.log.kind }}
metadata:
  name: {{ .Values.sdnc.volume.log.pvc.name }}
  namespace: {{ include "sdnc.namespace" . }}
spec:
  accessModes:
    - {{ .Values.sdnc.volume.log.pvc.accessMode }}
  resources:
    requests:
      storage: {{ .Values.sdnc.volume.log.pvc.storage }}
  {{- include "parent-chart.resolveLogPceNetconfStorageClass" . | nindent 2 }}
{{- end }}