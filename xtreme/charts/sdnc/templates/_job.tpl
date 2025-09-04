# Copyright 2023 DZS Inc
{{- define "parent-chart.jobtemplate" }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Values.appName }}-pre-upgrade-job
  namespace: {{ include "sdnc.namespace" . }}
  annotations:
    "helm.sh/hook": pre-upgrade
spec:
  template:
    spec:
      containers:
      - name: {{ .Values.appName }}-pre-upgrade-hook
        image: "{{ .Values.image.name }}:{{ .Values.image.tag | default .Values.global.sdncImgtag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}

        volumeMounts:
        - name: config-volume
          mountPath: {{ .Values.lighty.workdir }}/{{ .Values.lighty.configDirectoryName }}

        command:
        - bash
        - /lighty-rnc/k8s-config/preStop.sh

      volumes:
      - name: config-volume
        configMap:
          name: {{ include "lighty-rnc-app-helm.fullname" . }}
      restartPolicy: Never
  backoffLimit: 4
  ttlSecondsAfterFinished : 100
{{- end }}