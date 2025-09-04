# Copyright 2022 DZS Inc
{{/*
Default Template for Service. All Sub-Charts under this Chart can include the below template.
*/}}
{{- define "parent-chart.servicetemplate" }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "lighty-rnc-app-helm.fullname" . }}
  namespace: {{ include "sdnc.namespace" . }}
spec:
  {{- if .Values.nodePort.useNodePort }}
  type: NodePort
  {{ else }}
  type: ClusterIP
  {{- end}}
  ports:
    {{- if .Values.nodePort.exposeManagement }}
    - protocol: TCP
      name: http-akka
      port: {{ .Values.lighty.akka.managementPort }}
      {{- if .Values.nodePort.useNodePort }}
      targetPort: {{ .Values.lighty.akka.managementPort }}
      nodePort: {{ .Values.nodePort.managementNodePort }}
      {{- end }}
    {{- end }}
    - protocol: TCP
      name: http-restconf
      port: {{ .Values.lighty.restconf.restconfPort }}
      {{- if .Values.nodePort.useNodePort }}
      targetPort: {{ .Values.lighty.restconf.restconfPort }}
      nodePort: {{ .Values.nodePort.restconfNodePort }}
      {{- end }}
  selector:
    {{- include "lighty-rnc-app-helm.selectorLabels" . | nindent 4 }}
{{- end }}