# Copyright 2022 DZS Inc
{{/*
Default Template for Deployment. All Sub-Charts under this Chart can include the below template.
*/}}
{{- define "parent-chart.deploymenttemplate" }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.appName  }}
  namespace: {{ include "sdnc.namespace" . }}
  labels:
    {{- include "lighty-rnc-app-helm.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.lighty.replicaCount }}
  selector:
    matchLabels:
      {{- include "lighty-rnc-app-helm.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/path: "monitor/metrics/prometheus"
        prometheus.io/type: "sdnc-service"
        prometheus.io/port: "{{ .Values.lighty.restconf.restconfPort }}"
      labels:
        {{- include "lighty-rnc-app-helm.selectorLabels" . | nindent 8 }}
    spec:
      initContainers:
        - name: wait-for-deps
          image: "{{ .Values.initContainer.waitForDep.image.repository }}:{{ .Values.initContainer.waitForDep.image.tag }}"
          imagePullPolicy: {{ .Values.initContainer.waitForDep.image.pullPolicy }}
          env:
            - name: RW_NATS_SVC_NAME
              value: {{ include "nats.fqdn" . }}
            - name: RW_MONGODB_SVC_NAME
              value: {{ include "mongodb.fqdn" . }}
            {{- if and (eq .Values.svcName "netconf") (eq .Values.global.install.zms true) }}
            - name: RW_ZMS_SVC_NAME
              value: "zmsapp-tcp"
            {{- end }}
            {{- if and (eq .Values.svcName "config") (eq .Values.global.install.inas true) }}
            - name: RW_INAS2_BE_SVC_NAME
              value: {{ include "inas-be.fqdn" . }}
            {{- end }}
            {{- if eq .Values.svcName "config" }}
            - name: RW_SDNC_NETCONF_SVC_NAME
              value: {{ include "rnc-netconf-svc.fqdn" . }}
            {{- end }}
            {{- if and (eq .Values.global.install.kafka true) (or ( and (eq .Values.svcName "tpce") ( eq .Values.global.enableKafka_tpce true)) (and (eq .Values.svcName "config") (eq .Values.global.enableKafka_configMgr true)) (and (eq .Values.svcName "netconf") (eq .Values.global.enableKafka_netconf true))) }}
            - name: RW_KAFKA_SVC_NAME
              value: {{ include "kafkaBootstrap.fqdn" . }}
            {{- end }} 
          command:
            - /wait-for
          args:
            - --host="$(RW_NATS_SVC_NAME):4222"
            - --host="$(RW_MONGODB_SVC_NAME):8006"
            {{- if and (eq .Values.svcName "netconf") (eq .Values.global.install.zms true) }}
            - --host="$(RW_ZMS_SVC_NAME):830"
            {{- end }}
            {{- if and (eq .Values.svcName "config") (eq .Values.global.install.inas true) }}
            - --host="$(RW_INAS2_BE_SVC_NAME):30522"
            {{- end }}
            {{- if eq .Values.svcName "config" }}
            - --host="$(RW_SDNC_NETCONF_SVC_NAME):8888"
            {{- end }}
            {{- if and (eq .Values.global.install.kafka true) (or ( and (eq .Values.svcName "tpce") ( eq .Values.global.enableKafka_tpce true)) (and (eq .Values.svcName "config") (eq .Values.global.enableKafka_configMgr true)) (and (eq .Values.svcName "netconf") (eq .Values.global.enableKafka_netconf true))) }}
            - --host="$(RW_KAFKA_SVC_NAME):9092"
            {{- end }}
            - --timeout=120s
            - --verbose
 
      containers:
        - name: {{ .Chart.Name }}
          securityContext: 
            {{- toYaml .Values.securityContext | nindent 12}}
          image: "{{ .Values.image.name }}:{{ .Values.image.tag | default .Values.global.sdncImgtag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          {{- if .Values.daexim.enable }}
          lifecycle:
            postStart:
              exec:
                command:
                  - bash
                  - /lighty-rnc/k8s-config/postStart.sh
          {{- end }}
          args: [ "-c","{{ .Values.lighty.configDirectoryName }}/{{ .Values.lighty.configFilename }}",
                  {{- if  not (contains "dzs-transportpce" .Values.image.name) }}
                    "-l","{{ .Values.lighty.configDirectoryName }}/{{ .Values.lighty.loggerConfigFilename }}"
                  {{- end }}]
          volumeMounts:
            - name: config-volume
              mountPath: {{ .Values.lighty.workdir }}/{{ .Values.lighty.configDirectoryName }}
            - name: secrets-volume
              mountPath: {{ .Values.lighty.workdir }}/{{ .Values.lighty.restconf.keyStoreDirectory }}
            - name: {{ .Values.lighty.volume.name }}
              mountPath: {{ .Values.lighty.workdir }}/{{ .Values.lighty.volume.mountPath }}
            - name: {{ .Values.sdnc.volume.log.name }}
              mountPath: {{ .Values.sdnc.volume.log.pvc.mountPath }}
            {{- if .Values.sdnc.volume.plugins.enableExtPlugins }}
            - mountPath: {{ .Values.sdnc.volume.plugins.mountPath }}
              name: {{ .Values.sdnc.volume.plugins.name }}
            {{- end }}
            {{- if .Values.daexim.enable }}
            - name: {{ .Values.daexim.volume.name }}
              mountPath: {{ .Values.daexim.volume.pvc.mountPath }}
            {{- end }}
          env:
            - name: HOSTNAME
              valueFrom:
                fieldRef:
                  apiVersion: v1
                  fieldPath: status.podIP
            - name: RW_NATS_SVC_NAME
              value: {{ include "nats.fqdn" . }}
            - name: CACHE_SCHEMA
              value: "false"

            - name: JAVA_OPTS
              value:  "{{ .Values.java.opts.xmx }}
                      {{ if .Values.lighty.jmx.enableJmxRemoting }}
                      -Dcom.sun.management.jmxremote
                      -Dcom.sun.management.jmxremote.authenticate=false
                      -Dcom.sun.management.jmxremote.ssl=false
                      -Dcom.sun.management.jmxremote.local.only=false
                      -Dcom.sun.management.jmxremote.port={{ .Values.lighty.jmx.jmxPort }}
                      -Dcom.sun.management.jmxremote.rmi.port={{ .Values.lighty.jmx.jmxPort }}
                      -Djava.rmi.server.hostname=127.0.0.1
                      {{- end }}
                      {{- if .Values.sdnc.volume.log.pvc.log4j2Version }}
                      -Dlog4j.configurationFile={{ .Values.lighty.configDirectoryName }}/{{ .Values.lighty.loggerConfigFilename }}
                      {{- end }}
                      {{- if eq .Values.svcName "tpce" }}
                      -DPROP_DIR={{ .Values.lighty.configDirectoryName }}
                      {{- end }}"       
          ports:
            # akka remoting
            - name: remoting
              containerPort: {{ .Values.lighty.akka.remotingPort }}
              protocol: TCP
            # When
            # akka.management.cluster.bootstrap.contact-point-discovery.port-name
            # is defined, it must correspond to this name:
            - name: management
              containerPort: {{ .Values.lighty.akka.managementPort }}
              protocol: TCP
            # restconf port
            - name: restconf
              containerPort: {{ .Values.lighty.restconf.restconfPort }}
              protocol: TCP
              {{- if .Values.lighty.jmx.enableJmxRemoting }}
              # JMX port on which JMX server is listening
            - name: jmx
              containerPort: {{ .Values.lighty.jmx.jmxPort }}
              protocol: TCP
              {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
        - name: "fluentd"
          securityContext: 
            {{- toYaml .Values.securityContext | nindent 12}}
          image: "{{ .Values.fluentd.image.repository }}:{{ .Values.fluentd.image.tag }}"
          imagePullPolicy: {{ .Values.fluentd.image.pullPolicy }}
          command: ["fluentd"]
          args: ["-c", "/fluentd/etc/fluent.conf"]
          volumeMounts:
            - name: config-volume
              mountPath: /fluentd/etc
            - name: {{ .Values.sdnc.volume.log.name }}
              mountPath: {{ .Values.sdnc.volume.log.pvc.mountPath }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}            
      volumes:
        {{- if .Values.sdnc.volume.plugins.enableExtPlugins }}
        - name: {{ .Values.sdnc.volume.plugins.name }}
          hostPath:
            path: {{ .Values.sdnc.volume.plugins.hostPath }}
        {{- end }}
        - name: {{ .Values.sdnc.volume.log.name }}
          persistentVolumeClaim:
            claimName: {{ .Values.sdnc.volume.log.pvc.name }}
        - name: {{ .Values.lighty.volume.name }}
          persistentVolumeClaim:
            claimName: {{ .Values.lighty.volume.pvc.name }}
        - name: config-volume
          configMap:
            name: {{ include "lighty-rnc-app-helm.fullname" . }}
        - name: secrets-volume
          secret:
            secretName: {{ include "lighty-rnc-app-helm.fullname" . }}
            items:
              - key: keystore.jks
                path: {{ .Values.lighty.restconf.keyStoreFileName }}
        {{- if .Values.daexim.enable }}
        - name: {{ .Values.daexim.volume.name }}
          persistentVolumeClaim:
            claimName: {{ .Values.moduleName }}-{{ .Values.daexim.volume.pvc.name }}
        {{- end }}
{{- end }}
