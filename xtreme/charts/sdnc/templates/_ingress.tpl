# Copyright 2025 DZS Inc
{{/*
Default Template for Ingress. All Sub-Charts under this Chart can include the below template.
*/}}
{{- define "parent-chart.ingresstemplate" }}
{{- if .Values.ingress.useIngress }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "lighty-rnc-app-helm.fullname" . }}
  namespace: {{ include "sdnc.namespace" . }}
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$1
spec:
  rules:
    - http:
        paths:
          - path: {{ .Values.ingress.prefix }}/(.*)
            pathType: Prefix
            backend:
              service:
                name: {{ include "lighty-rnc-app-helm.fullname" . }}
                port:
                  number: {{ .Values.lighty.restconf.restconfPort }}
    {{- if .Values.ingress.exposeManagement }}
    - host: {{ .Values.ingress.managementHost }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
            service:
                name: {{ include "lighty-rnc-app-helm.fullname" . }}
                port:
                  number: {{ .Values.lighty.akka.managementPort }}
    {{- end }}
{{- end }}
{{- end }}
