# Copyright 2025 DZS Inc
{{/*
Default Template for daexim. All Sub-Charts under this Chart can include the below template.
*/}}
{{- define "parent-chart.pvc_daeximtemplate" }}
apiVersion: v1
kind: {{ .Values.sdnc.volume.log.kind }}
metadata:
  name: {{ .Values.moduleName }}-{{ .Values.daexim.volume.pvc.name }}
  namespace: {{ include "sdnc.namespace" . }}
spec:
  accessModes:
    - {{ .Values.daexim.volume.pvc.accessMode }}
  resources:
    requests:
      storage: {{ .Values.daexim.volume.pvc.storage }}
  {{- include "parent-chart.resolveStorageClass" (dict "local" .Values.daexim.volume.pvc.storageClassName "Values" .Values) | nindent 2 }}
{{- end }}