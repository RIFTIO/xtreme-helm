# Copyright 2025 DZS Inc
{{/*
Default Template for Pvc. All Sub-Charts under this Chart can include the below template.
*/}}
{{- define "parent-chart.pvctemplate" }}
apiVersion: v1
kind: {{ .Values.lighty.volume.kind }}
metadata:
  name: {{ .Values.lighty.volume.pvc.name }}
  namespace: {{ include "sdnc.namespace" . }}
spec:
  accessModes:
    - {{ .Values.lighty.volume.pvc.accessMode }}
  resources:
    requests:
      storage: {{ .Values.lighty.volume.pvc.storage }}
  {{- include "parent-chart.resolvePceNetconfStorageClass" . | nindent 2 }}
{{- end }}
