# Copyright 2022 DZS Inc
{{/*
Default Template for Configmaps. All Sub-Charts under this Chart can include the below template.
*/}}
{{- define "parent-chart.configmapstemplate" }}

{{- $nats_svc := include "nats.fqdn" . }}
{{- $gnpy_svc := include "gnpy.fqdn" . }}
{{- $netconf_svc := include "rnc-netconf-svc.fqdn" . }}
{{- $inventory_mgr := include "rnc-inventory-mgr.fqdn" . }}
{{- $inas_svc := include "inas-be.fqdn" . }}
{{- $transportpce_svc := include "rnc-transportpce.fqdn" . }}
{{- $sftp_svc := include "sftp.fqdn" . }}
{{- $kafka_socket := include "kafka.socket" . }}
{{- $mongo_db := include "mongodb.fqdn" . }}


apiVersion: v1

metadata:
  name: {{ include "lighty-rnc-app-helm.fullname" . }}
  namespace: {{ include "sdnc.namespace" . }}
kind: ConfigMap

data:
  pre-upgrade.sh: |
    #!/bin/bash
    max_wait_time=300
    elapsed_time=0
    curl -X POST "http://{{ include "lighty-rnc-app-helm.fullname" . }}:8888/restconf/operations/data-export-import:schedule-export" -H "accept: application/json" -H "Content-Type: application/json" -d "{\"input\":{\"run-at\":\"100\",\"local-node-only\":false,\"strict-data-consistency\":true,\"split-by-module\":false}}"
    while [ $elapsed_time -lt $max_wait_time ]; do
      response=$(curl -X POST "http://{{ include "lighty-rnc-app-helm.fullname" . }}:8888/restconf/operations/data-export-import:status-export" -H "accept: application/json" -H "Content-Type: application/json" -d "{\"input\":{}}")
      echo $response
      if [[ $response == *"\"status\":\"complete\""* ]]; then
        echo "export is already done."
        curl -X POST "http://{{ include "lighty-rnc-app-helm.fullname" . }}:8888/restconf/operations/{{ .Values.moduleName }}:upload-daexim-files" -H "accept: application/json" -H "Content-Type: application/json" -d "{\"input\":{\"task-id\":\"local-backup\",\"url\":\"sftp://sftp:sftp@{{ $sftp_svc }}:{{ default 22 .Values.sftp.port }}\"}}"
        break
      else
        echo "export is not done yet, waiting..."
        sleep 5
        elapsed_time=$((elapsed_time + 5))
      fi
    done
    if [ $elapsed_time -eq $max_wait_time ]; then
      echo "The maximum wait time \($max_wait_time\) has been exceeded."
    fi

  post-upgrade.sh: |
    #curl -X POST "http://{{ include "lighty-rnc-app-helm.fullname" . }}:8888/restconf/operations/{{ .Values.moduleName }}:download-daexim-files" -H "accept: application/json" -H "Content-Type: application/json" -d "{\"input\":{\"task-id\":\"local-backup\",\"url\":\"sftp://sftp:sftp@{{ $sftp_svc }}:{{ default 22 .Values.sftp.port }}\"}}"
    curl -X POST "http://localhost:{{ .Values.lighty.restconf.restconfPort }}/restconf/operations/data-export-import:immediate-import" -H "accept: application/json" -H "Content-Type: application/json" -d "{\"input\":{\"check-models\":false,\"clear-stores\":\"all\",\"strict-data-consistency\":false,\"import-batching\":{\"max-traversal-depth\":2,\"list-batch-size\":2000}}}"

  postStart.sh: |
    #!/bin/bash
    file_path="{{ .Values.daexim.volume.pvc.mountPath }}/odl_backup_config.json"
    if [ -e "$file_path" ]; then
      while true; do
        if curl -m 5 -s "http://localhost:{{ .Values.lighty.restconf.restconfPort }}/restconf"; then
          response=$(bash /lighty-rnc/k8s-config/post-upgrade.sh)
          if [[ $response == *"\"result\":true"* ]]; then
            echo "post-upgrade.sh executed successfully." >> /lighty-rnc/postStart.log
            break
          else
            echo "Failed post-upgrade.sh. Retrying..." >> /lighty-rnc/postStart.log
            sleep 10
          fi
        else
          echo "Port 8888 is closed. Retrying..." >> /lighty-rnc/postStart.log
          sleep 10
        fi
      done
    else
      echo "No backup history." >> /lighty-rnc/postStart.log
    fi

  preStop.sh: |
    #!/bin/bash
    while true; do
      response=$(bash /lighty-rnc/k8s-config/pre-upgrade.sh)
      if [[ $response == *"\"status\":\"successful\""* ]]; then
        echo "pre-upgrade.sh executed successfully."
        break
      else
        echo "Failed pre-upgrade.sh. Retrying"
        sleep 5
      fi
    done

  lighty-config.json: |
    {
        "controller":{
            "restoreDirectoryPath":"./clustered-datastore-restore",
            "maxDataBrokerFutureCallbackQueueSize":1000,
            "maxDataBrokerFutureCallbackPoolSize":10,
            "metricCaptureEnabled":false,
            "mailboxCapacity":1000,
            "moduleShardsConfig": "configuration/initial/module-shards.conf",
            "modulesConfig": "configuration/initial/modules.conf",
            {{- if and (eq .Values.lighty.initData.hasInitData true) (eq .Values.global.install.zms true) }}
            "initialConfigData": {
                "pathToInitDataFile": "{{ .Values.lighty.configDirectoryName }}/initData.json",
                "format": "json"
            },
            {{- end }}
            "datastoreProperties": {
                "operational.persistent" : false,
                "config.persistent" : {{ .Values.lighty.akka.isPersistence | default true }}
            },
            "domNotificationRouterConfig":{
                "queueDepth":65536,
                "spinTime":0,
                "parkTime":0,
                "unit":"MILLISECONDS"
            },
            "actorSystemConfig":{
                {{- if .Values.lighty.akka.isSingleNode }}
                "akkaConfigPath":"singlenode/akka-default.conf",
                {{- else }}
                "akkaConfigPath":"{{ .Values.lighty.configDirectoryName }}/{{ .Values.lighty.akka.akkaNodeConfigFilename }}",
                {{- end }}
                "factoryAkkaConfigPath":"singlenode/factory-akka-default.conf"
            },
            "schemaServiceConfig":{
                "topLevelModels":[
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:mdsal:core:general-entity", "name": "odl-general-entity", "revision": "2015-09-30" },
                    { "nameSpace": "urn:ietf:params:xml:ns:yang:ietf-yang-library", "name": "ietf-yang-library", "revision": "2019-01-04" },
                    { "nameSpace": "urn:ietf:params:xml:ns:yang:ietf-restconf-monitoring", "name": "ietf-restconf-monitoring", "revision": "2017-01-26" },
                    { "nameSpace": "urn:ietf:params:xml:ns:yang:ietf-yang-types", "name": "ietf-yang-types", "revision": "2010-09-24" },
                    { "nameSpace": "instance:identifier:patch:module", "name": "instance-identifier-patch-module", "revision": "2015-11-21" },
                    { "nameSpace": "urn:ietf:params:xml:ns:yang:iana-if-type", "name": "iana-if-type", "revision": "2014-05-08" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:config:actor-system-provider:impl", "name": "actor-system-provider-impl", "revision": "2015-10-05" },
                    { "nameSpace": "urn:ietf:params:xml:ns:yang:ietf-network-topology", "name": "ietf-network-topology", "revision": "2015-06-08" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:entity-owners", "name": "odl-entity-owners" },
                    { "nameSpace": "urn:ietf:params:xml:ns:yang:ietf-access-control-list", "name": "ietf-access-control-list", "revision": "2016-02-18" },
                    { "nameSpace": "config:aaa:authn:encrypt:service:config", "name": "aaa-encrypt-service-config", "revision": "2016-09-15" },
                    { "nameSpace": "urn:ietf:params:xml:ns:yang:ietf-lisp-address-types", "name": "ietf-lisp-address-types", "revision": "2015-11-05" },
                    { "nameSpace": "subscribe:to:notification", "name": "subscribe-to-notification", "revision": "2016-10-28" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:config:concurrent-data-broker", "name": "odl-concurrent-data-broker-cfg", "revision": "2014-11-24" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:md:sal:core:general-entity", "name": "general-entity", "revision": "2015-08-20" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:md:sal:dom:pingpong", "name": "opendaylight-pingpong-broker", "revision": "2014-11-07" },
                    { "nameSpace": "urn:sal:restconf:event:subscription", "name": "sal-remote-augment", "revision": "2014-07-08" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:netty", "name": "netty", "revision": "2013-11-19" },
                    { "nameSpace": "urn:ietf:params:xml:ns:yang:ietf-restconf", "name": "ietf-restconf", "revision": "2013-10-19" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:md:sal:cluster:admin", "name": "cluster-admin", "revision": "2015-10-13" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:md:sal:config:impl:cluster-singleton-service", "name": "cluster-singleton-service-impl", "revision": "2016-07-18" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:md:sal:clustering:prefix-shard-configuration", "name": "prefix-shard-configuration", "revision": "2017-01-10" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:inmemory-datastore-provider", "name": "opendaylight-inmemory-datastore-provider", "revision": "2014-06-17" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:md:sal:binding:impl", "name": "opendaylight-sal-binding-broker-impl", "revision": "2013-10-28" },
                    { "nameSpace": "urn:ietf:params:xml:ns:yang:ietf-restconf", "name": "ietf-restconf", "revision": "2017-01-26" },
                    { "nameSpace": "urn:ietf:params:xml:ns:netmod:notification", "name": "nc-notifications", "revision": "2008-07-14" },
                    { "nameSpace": "urn:opendaylight:l2:types", "name": "opendaylight-l2-types", "revision": "2013-08-27" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:config:distributed-datastore-provider", "name": "distributed-datastore-provider", "revision": "2014-06-12" },
                    { "nameSpace": "urn:opendaylight:params:xml:ns:yang:controller:config:legacy-entity-ownership-service-provider", "name": "opendaylight-legacy-entity-ownership-service-provider", "revision": "2016-02-26" }
                    {{- if contains "dzs-config-mgr" .Values.image.name }}
                        ,{{ .Values.lighty.configModel }}
                    {{- end }}
                    {{- if contains "dzs-topology-mgr" .Values.image.name }}
                        ,{{ .Values.lighty.topologyModel }}
                    {{- end }}
                    {{- if contains "dzs-netconf-svc" .Values.image.name }}
                        ,{{ .Values.lighty.netconfModel }}
                    {{- end }}
                ]
            }
        },
        "restconf":{
            "inetAddress":"0.0.0.0",
            "httpPort":{{ .Values.lighty.restconf.restconfPort }},
            "restconfServletContextPath":{{ .Values.lighty.restconf.restconfPath | quote}},
            "useHttps": {{ .Values.lighty.restconf.useHttps }},
            "keyStorePassword":{{ .Values.lighty.restconf.keyStorePassword | quote }},
            "keyStoreType":{{ .Values.lighty.restconf.keyStoreType | quote }},
            "keyStoreFilePath":"{{ .Values.lighty.restconf.keyStoreDirectory }}/{{ .Values.lighty.restconf.keyStoreFileName }}",
            "enableMonitoring": true,
            "prometheusMetricsContextPath": "/monitor/metrics/prometheus"
        },
        "netconf-northbound":{
            "connectionTimeout":20000,
            "monitoringUpdateInterval":6,
            "netconfNorthboundTcpServerBindingAddress":"0.0.0.0",
            "netconfNorthboundTcpServerPortNumber":"2831",
            "netconfNorthboundSshServerBindingAddress":"0.0.0.0",
            "netconfNorthboundSshServerPortNumber":"2830",
            "userCredentials":{
                "admin":"admin"
            }
        },
        "netconf":{
            "topologyId":"topology-netconf"
        },
        "aaa": {
            "enableAAA": {{ .Values.lighty.aaa.enableAAA }},
            "moonEndpointPath" : "/moon",
            "dbPassword" : "bar",
            "dbUsername" : "foo"
        }
        {{- if contains "dzs-netconf-svc" .Values.image.name }}
            ,{{ .Values.lighty.serviceConfig | replace "nats-svc-name" $nats_svc | replace "transportpce-svc" $transportpce_svc | replace "mongodb-host" $mongo_db | replace "kafka-headless" $kafka_socket | replace "enableKafka" (toString .Values.global.enableKafka_netconf) }}
        {{- end }}
        {{- if contains "dzs-config-mgr" .Values.image.name }}
            ,{{ .Values.lighty.serviceConfig | replace "nats-svc-name" $nats_svc | replace "netconf-svc-dzs-rnc" $netconf_svc | replace "inventory-mgr-dzs-rnc" $inventory_mgr | replace "transportpce-svc" $transportpce_svc | replace "inas2-be" $inas_svc | replace "mongodb-host" $mongo_db | replace "kafka-headless" $kafka_socket | replace "enableKafka" (toString .Values.global.enableKafka_configMgr) }}
        {{- end }}
        {{- if contains "dzs-transportpce" .Values.image.name }}
            ,{{ .Values.lighty.serviceConfig | replace "enableNbinotification" (toString .Values.global.enableKafka_tpce) | replace "gnpy-svc-name" $gnpy_svc }}
        {{- end }}
    }

  {{- if .Values.lighty.initData.hasInitData }}
  initData.json: |
    {{ .Values.lighty.initData.content }}
  {{- end }}

  {{- if .Values.sdnc.volume.log.pvc.log4j2Version }}
  log4j2.xml: |
    <?xml version="1.0" encoding="UTF-8"?>
    <Configuration status="WARN" monitorInterval="30">
        <Properties>
            <Property name="LOG_PATTERN">%d{ISO8601} | %-5p | dzsi | sdn | %t | %c{1} | %m%n</Property>
            <Property name="LOG_PATTERN_APPDATA">%m%n</Property>
            <Property name="NETCONF_LOG_PATTERN">%d{ISO8601} - %m%n</Property>
            <Property name="APP_LOG_ROOT">./logs</Property>
            <Property name="DATA_LOG_ROOT">{{ .Values.sdnc.volume.log.pvc.mountPath }}</Property>
            <Property name="json_pattern">{"service_name":"{{ .Values.svcName }}","message":"%replace{ %replace{ %replace{ %replace{%message}{[\r]+}{\\r} }{[\n]+}{\\n} }{[\t]+}{\\t} }{[[&quot;&quot;]+]+}{\\"}","severity":"%level","tag":"sdnc.{{ .Values.svcName }}.log","evt_time":"%date{yyyy-MM-dd HH:mm:ss.SSS'Z'}","evt_time_gmt":"%date{yyyy-MM-dd'T'HH:mm:ss'Z'}"}%n</Property>
            <Property name="config_json_pattern">{"service_name":"{{ .Values.svcName }}","message":"%replace{ %replace{ %replace{%message}{[\r]+}{\\r} }{[\n]+}{\\n} }{[\t]+}{\\t}",%replace{%replace{%message}{\\"}{"}}{^(.)(.*)(.)$}{$2},"severity":"%level","tag":"sdnc.config-mgr.outevt","evt_time":"%date{yyyy-MM-dd HH:mm:ss.SSS'Z'}","evt_time_gmt":"%date{yyyy-MM-dd'T'HH:mm:ss'Z'}"}%n</Property>
        </Properties>
        <Appenders>
            <Console name="Console" target="SYSTEM_OUT" follow="true">
                <PatternLayout pattern="${LOG_PATTERN}" />
            </Console>
            <RollingFile name="appLog"
                         fileName="${APP_LOG_ROOT}/{{ .Values.sdnc.log.appLogFile }}.log"
                         filePattern="${APP_LOG_ROOT}/{{ .Values.sdnc.log.appLogFile }}-%d{yyyy-MM-dd}-%i.log">
                <PatternLayout pattern="${LOG_PATTERN}" />
                <Policies>
                    <SizeBasedTriggeringPolicy size="20MB" />
                </Policies>
                <DefaultRolloverStrategy max="5" />
            </RollingFile>
            <RollingFile name="appLogData"
                         fileName="${DATA_LOG_ROOT}/{{ .Values.sdnc.log.appLogFile }}.log"
                         filePattern="${DATA_LOG_ROOT}/{{ .Values.sdnc.log.appLogFile }}-%d{yyyy-MM-dd}-%i.log">
                <PatternLayout pattern="${LOG_PATTERN_APPDATA}" />
                <Policies>
                    <SizeBasedTriggeringPolicy size="20MB" />
                </Policies>
                <DefaultRolloverStrategy max="5" />
            </RollingFile>
            {{- if or (contains "dzs-transportpce" .Values.image.name) (contains "dzs-netconf-svc" .Values.image.name) }}
            <RollingFile name="netconfCommandLog" fileName="${APP_LOG_ROOT}/netconf-command.log"
                filePattern="${APP_LOG_ROOT}/netconf-command-%d{yyyy-MM-dd}-%i.log">
                <LevelRangeFilter minLevel="info" maxLevel="trace" onMatch="ACCEPT" onMismatch="DENY"/>
                <PatternLayout pattern="${NETCONF_LOG_PATTERN}"/>
                <Policies>
                    <SizeBasedTriggeringPolicy size="20MB" />
                </Policies>
                <DefaultRolloverStrategy max="10"/>
            </RollingFile>
            <RollingFile name="dataLogAppender" fileName="${DATA_LOG_ROOT}/netconf-command.log"
                filePattern="${DATA_LOG_ROOT}/netconf-command-%d{yyyy-MM-dd}-%i.log">
                <LevelRangeFilter minLevel="debug" maxLevel="debug" onMatch="ACCEPT" onMismatch="DENY"/>
                <PatternLayout pattern="${json_pattern}"/>
                <Policies>
                    <SizeBasedTriggeringPolicy size="20MB" />
                </Policies>
                <DefaultRolloverStrategy max="10"/>
            </RollingFile>
            {{- end }}
            {{- if contains "dzs-netconf-svc" .Values.image.name }}
            <RollingFile name="CONFIG"
                         fileName="${DATA_LOG_ROOT}/nc-config-event.log"
                         filePattern="${DATA_LOG_ROOT}/nc-config-event-%d{yyyy-MM-dd}-%i.log">
                <PatternLayout pattern="${LOG_PATTERN_APPDATA}"/>
                <Policies>
                    <SizeBasedTriggeringPolicy size="10MB"/>
                </Policies>
                <DefaultRolloverStrategy max="10"/>
            </RollingFile>
            <RollingFile name="NOTIFICATION"
                         fileName="${DATA_LOG_ROOT}/netconf-notification.log"
                         filePattern="${DATA_LOG_ROOT}/netconf-notification-%d{yyyy-MM-dd}-%i.log">
                <LevelRangeFilter minLevel="info" maxLevel="info" onMatch="ACCEPT" onMismatch="DENY"/>
                <PatternLayout pattern="${json_pattern}"/>
                <Policies>
                    <SizeBasedTriggeringPolicy size="10MB"/>
                </Policies>
                <DefaultRolloverStrategy max="10"/>
            </RollingFile>
            {{- end }}
            {{- if contains "dzs-config-mgr" .Values.image.name }}
            <RollingFile name="PROVISION"
                         fileName="${DATA_LOG_ROOT}/{{ .Values.lighty.log4j.provisionFileName }}"
                         filePattern="${DATA_LOG_ROOT}/nc-config-event-%d{yyyy-MM-dd}-%i.log">
                <PatternLayout pattern="${LOG_PATTERN_APPDATA}"/>
                <Policies>
                    <SizeBasedTriggeringPolicy size="10MB"/>
                </Policies>
                <DefaultRolloverStrategy max="10"/>
            </RollingFile>
            <RollingFile name="CONFIG_CHANGE"
                         fileName="${DATA_LOG_ROOT}/{{ .Values.lighty.log4j.configChangeFileName }}"
                         filePattern="${DATA_LOG_ROOT}/{{ .Values.lighty.log4j.configChangeFileName }}.%d{yyyy-MM-dd}-%i">
                <PatternLayout pattern="${LOG_PATTERN_APPDATA}"/>
                <Policies>
                    <SizeBasedTriggeringPolicy size="10MB"/>
                </Policies>
                <DefaultRolloverStrategy max="10"/>
            </RollingFile>
            <RollingFile name="SYNC"
                         fileName="${DATA_LOG_ROOT}/{{ .Values.lighty.log4j.syncFileName }}"
                         filePattern="${DATA_LOG_ROOT}/{{ .Values.lighty.log4j.syncFileName }}.%d{yyyy-MM-dd}-%i">
                <PatternLayout pattern="${config_json_pattern}"/>
                <Policies>
                    <SizeBasedTriggeringPolicy size="10MB"/>
                </Policies>
                <DefaultRolloverStrategy max="10"/>
            </RollingFile>
            {{- end }}

        </Appenders>
        <Loggers>
            <Root level="info">
                <AppenderRef ref="Console" />
                <AppenderRef ref="appLog" />
            </Root>
            <Logger name="appLogData" level="info">
                <AppenderRef ref="appLogData"/>
            </Logger>
            <Logger name="org.opendaylight.netconf.sal.connect.netconf.listener.NetconfDeviceCommunicator" additivity="false" level="trace">
                <AppenderRef ref="netconfCommandLog" />
                <AppenderRef ref="dataLogAppender" />
                {{- if contains "dzs-netconf-svc" .Values.image.name }}
                <AppenderRef ref="NOTIFICATION" />
                {{- end }}
            </Logger>
            {{- if contains "dzs-netconf-svc" .Values.image.name }}
            <Logger name="CONFIG" level="info">
                <AppenderRef ref="CONFIG"/>
            </Logger>
            {{- end }}
            {{- if contains "dzs-config-mgr" .Values.image.name }}
            <Logger name="PROVISION" level="info">
                <AppenderRef ref="PROVISION"/>
            </Logger>
            <Logger name="CONFIG_CHANGE" level="info">
                <AppenderRef ref="CONFIG_CHANGE"/>
            </Logger>
            <Logger name="SYNC" level="info">
                <AppenderRef ref="SYNC"/>
            </Logger>
            {{- end }}
        </Loggers>
    </Configuration>
  {{- else }}
  log4j.properties: |
    log4j.rootLogger=INFO,STDOUT,APPLOG
    log4j.appender.STDOUT=org.apache.log4j.ConsoleAppender
    log4j.appender.STDOUT.layout=org.apache.log4j.PatternLayout
    log4j.appender.STDOUT.layout.ConversionPattern=%5p %d{ISO8601} [%c{1}] - %m%n
    log4j.logger.APPLOG=INFO,APPLOG
    log4j.appender.APPLOG=org.apache.log4j.RollingFileAppender
    log4j.appender.APPLOG.File=./log/{{ .Values.lighty.log4j.fileName }}
    log4j.appender.APPLOG.MaxFileSize=20MB
    log4j.appender.APPLOG.MaxBackupIndex=10
    log4j.appender.APPLOG.layout=org.apache.log4j.PatternLayout
    log4j.appender.APPLOG.layout.ConversionPattern=%5p %d{ISO8601} [%c{1}] - %m%n
    log4j.logger.APP=INFO,APP
    log4j.appender.APP=org.apache.log4j.RollingFileAppender
    log4j.appender.APP.File=/data/log/{{ .Values.lighty.log4j.logDir }}/{{ .Values.lighty.log4j.fileName }}
    log4j.appender.APP.MaxFileSize=20MB
    log4j.appender.APP.MaxBackupIndex=10
    log4j.appender.APP.layout=org.apache.log4j.PatternLayout
    log4j.appender.APP.layout.ConversionPattern=%m%n
    {{- if contains "dzs-netconf-svc" .Values.image.name }}
    log4j.logger.org.opendaylight.netconf.sal.connect.netconf.listener.NetconfDeviceCommunicator=DEBUG, dataLogAppender, logAppender
    log4j.additivity.org.opendaylight.netconf.sal.connect.netconf.listener.NetconfDeviceCommunicator=false
    log4j.appender.dataLogAppender=org.apache.log4j.RollingFileAppender
    log4j.appender.dataLogAppender.datePattern='-'dd'.log'
    log4j.appender.dataLogAppender.File=/data/log/{{ .Values.lighty.log4j.logDir }}/netconf-command.log
    log4j.appender.dataLogAppender.MaxFileSize=20MB
    log4j.appender.dataLogAppender.MaxBackupIndex=10
    log4j.appender.dataLogAppender.layout=org.apache.log4j.PatternLayout
    log4j.appender.dataLogAppender.layout.ConversionPattern={"service_name":"netconf-svc","message":"%m","severity":"%p","tag":"sdnc.netconf-svc.connection","evt_time":"%d{yyyy-MM-dd'T'HH:mm:ss.SSS'Z'}","evt_time_gmt":"%d{yyyy-MM-dd'T'HH:mm:ss'Z'}"}%n
    log4j.appender.dataLogAppender.filter.a=org.apache.log4j.varia.LevelRangeFilter
    log4j.appender.dataLogAppender.filter.a.LevelMin=DEBUG
    log4j.appender.dataLogAppender.filter.a.LevelMax=DEBUG

    log4j.appender.logAppender=org.apache.log4j.RollingFileAppender
    log4j.appender.logAppender.datePattern='-'dd'.log'
    log4j.appender.logAppender.File=./log/netconf-command.log
    log4j.appender.logAppender.MaxFileSize=20MB
    log4j.appender.logAppender.MaxBackupIndex=10
    log4j.appender.logAppender.threshold=NETCONFCOMMANDLOG#org.opendaylight.netconf.sal.connect.netconf.listener.CustomLogLevel
    log4j.appender.logAppender.layout=org.apache.log4j.PatternLayout
    log4j.appender.logAppender.layout.ConversionPattern=%d{ISO8601} - %m%n
    log4j.appender.logAppender.filter.b=org.apache.log4j.varia.LevelRangeFilter
    log4j.appender.logAppender.filter.b.LevelMin=NETCONFCOMMANDLOG#org.opendaylight.netconf.sal.connect.netconf.listener.CustomLogLevel
    log4j.appender.logAppender.filter.b.LevelMax=NETCONFCOMMANDLOG#org.opendaylight.netconf.sal.connect.netconf.listener.CustomLogLevel

    log4j.logger.CONFIG=INFO,CONFIG
    log4j.appender.CONFIG=org.apache.log4j.RollingFileAppender
    log4j.appender.CONFIG.File=/data/log/{{ .Values.lighty.log4j.logDir }}/nc-config-event.log
    log4j.appender.CONFIG.MaxFileSize=20MB
    log4j.appender.CONFIG.MaxBackupIndex=10
    log4j.appender.CONFIG.layout=org.apache.log4j.PatternLayout
    log4j.appender.CONFIG.layout.ConversionPattern=%m%n
    {{- end }}
    {{- if contains "dzs-config-mgr" .Values.image.name }}
    log4j.logger.PROVISION=INFO,PROVISION
    log4j.appender.PROVISION=org.apache.log4j.RollingFileAppender
    log4j.appender.PROVISION.File=/data/log/{{ .Values.lighty.log4j.logDir }}/{{ .Values.lighty.log4j.provisionFileName }}
    log4j.appender.PROVISION.MaxFileSize=20MB
    log4j.appender.PROVISION.MaxBackupIndex=5
    log4j.appender.PROVISION.layout=org.apache.log4j.PatternLayout
    log4j.appender.PROVISION.layout.ConversionPattern=%m%n
    log4j.logger.CONFIG_CHANGE=INFO,CONFIG_CHANGE
    log4j.appender.CONFIG_CHANGE=org.apache.log4j.RollingFileAppender
    log4j.appender.CONFIG_CHANGE.File=/data/log/{{ .Values.lighty.log4j.logDir }}/{{ .Values.lighty.log4j.configChangeFileName }}
    log4j.appender.CONFIG_CHANGE.MaxFileSize=20MB
    log4j.appender.CONFIG_CHANGE.MaxBackupIndex=5
    log4j.appender.CONFIG_CHANGE.layout=org.apache.log4j.PatternLayout
    log4j.appender.CONFIG_CHANGE.layout.ConversionPattern=%m%n
    log4j.logger.SYNC=INFO,SYNC
    log4j.appender.SYNC=org.apache.log4j.RollingFileAppender
    log4j.appender.SYNC.File=/data/log/{{ .Values.lighty.log4j.logDir }}/{{ .Values.lighty.log4j.syncFileName }}
    log4j.appender.SYNC.MaxFileSize=20MB
    log4j.appender.SYNC.MaxBackupIndex=5
    log4j.appender.SYNC.layout=org.apache.log4j.PatternLayout
    log4j.appender.SYNC.layout.ConversionPattern={"service_name":"config-mgr","message":"%m","severity":"%p","tag":"sdnc.config-mgr.outevt","evt_time":"%d{yyyy-MM-dd'T'HH:mm:ss.SSS'Z'}","evt_time_gmt":"%d{yyyy-MM-dd'T'HH:mm:ss'Z'}"}%n
    {{- end }}
  {{- end }}

  {{- if contains "dzs-transportpce" .Values.image.name }}
  publisher.properties: |
    bootstrap.servers={{ $kafka_socket }}
    acks=all
    retries=3
    max.in.flight.requests.per.connection=1
    batch.size=16384
    linger.ms=1
    buffer.memory=33554432
  subscriber.properties: |
    bootstrap.servers={{ $kafka_socket }}
    enable.auto.commit=true
    auto.commit.interval.ms=1000
    auto.offset.reset=earliest
  {{- end }}

  akka-node-k8s.conf: |
    akka {

      log-level = "debug"

      actor {
        provider = "akka.cluster.ClusterActorRefProvider"
      }

      remote {
        netty.tcp {
          hostname = ${?HOSTNAME}
          port = {{ .Values.lighty.akka.remotingPort }}
          bind-hostname = 0.0.0.0
          bind-port = {{ .Values.lighty.akka.remotingPort }}
        }
      }

      cluster {
        seed-nodes = []
        roles = [
          "{{ .Values.lighty.akka.memberNamePrefix }}"${?HOSTNAME}
        ]
      }

      management.http.hostname = ${?HOSTNAME}
      management.http.bind-hostname = "0.0.0.0"
      management.http.port = {{ .Values.lighty.akka.managementPort }}
      management.http.bind-port = {{ .Values.lighty.akka.managementPort }}

      management.cluster.bootstrap {
        new-cluster-enabled = on
        contact-point-discovery {
          required-contact-point-nr = {{ .Values.lighty.akka.minimumClusterNodes }} // minimun number of nodes to bootstrap the cluster
        }
      }

      discovery {
        method = kubernetes-api
        kubernetes-api {
          class = akka.discovery.kubernetes.KubernetesApiServiceDiscovery
          pod-namespace = {{ .Values.lighty.akka.discovery.podNamespace | quote }} // in which namespace cluster is running
          pod-label-selector = "{{ .Values.lighty.akka.discovery.podSelectorName }}={{ .Values.lighty.akka.discovery.podSelectorValue }}" // selector - to find other cluster nodes
          pod-port-name = {{ .Values.lighty.akka.discovery.portName | quote }} // name of cluster management port
        }
      }

      lighty-kubernetes {
        pod-restart-timeout = 30
      }

      persistence {
        # You can choose to put the snapshots/journal directories somewhere else by modifying
        # the following two properties. The directory location specified may be a relative or absolute path.

        journal.leveldb.dir = "target/journal"
        snapshot-store.local.dir = "target/snapshots"
        # Use lz4 compression for LocalSnapshotStore snapshots
        snapshot-store.local.use-lz4-compression = false
        # Size of blocks for lz4 compression: 64KB, 256KB, 1MB or 4MB
        snapshot-store.local.lz4-blocksize = 256KB

        journal {
          leveldb {
            # Set native = off to use a Java-only implementation of leveldb.
            # Note that the Java-only version is not currently considered by Akka to be production quality,
            # but being Java-only makes it work also on platforms where native leveldb is not available.

            #native = on
          }
        }
      }

    }

  fluent.conf: |

    {{- if contains "config" .Values.svcName }}
    <source>
      @type tail
      path {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.lighty.log4j.provisionFileName }}
      pos_file {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.lighty.log4j.provisionFileName }}.pos
      tag sdnc.configMgr.provision.logs
      read_from_head true
      <parse>
        @type json
        time_key evt_time_gmt
        time_format %Y-%m-%dT%H:%M:%SZ
      </parse>
    </source>

    <match sdnc.configMgr.provision.logs>
      @type mongo
      host {{ include "mongodb.fqdn" . }}
      port 8006
      database events
      collection sdnc.configMgr.provision.logs

      # authentication
      user {{ .Values.global.eventsDB.username }}
      password {{ .Values.global.eventsDB.password }}

      <inject>
        time_key evt_time_gmt
      </inject>

      <buffer>
        flush_interval 5s
      </buffer>
    </match>

    <source>
      @type tail
      path {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.lighty.log4j.configChangeFileName }}
      pos_file {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.lighty.log4j.configChangeFileName }}.pos
      tag sdnc.configMgr.configChange.logs
      read_from_head true
      <parse>
        @type json
        time_key evt_time_gmt
        time_format %Y-%m-%dT%H:%M:%SZ
      </parse>
    </source>

    <match sdnc.configMgr.configChange.logs>
      @type mongo
      host {{ include "mongodb.fqdn" . }}
      port 8006
      database events
      collection sdnc.configMgr.configChange.logs

      # authentication
      user {{ .Values.global.eventsDB.username }}
      password {{ .Values.global.eventsDB.password }}

      <inject>
        time_key evt_time_gmt
      </inject>

      <buffer>
        flush_interval 5s
      </buffer>
    </match>

    <source>
      @type tail
      path {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.lighty.log4j.syncFileName }}
      pos_file {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.lighty.log4j.syncFileName }}.pos
      tag sdnc.configMgr.sync.logs
      read_from_head true
      <parse>
        @type json
        time_key evt_time_gmt
        time_format %Y-%m-%dT%H:%M:%SZ
      </parse>
    </source>

    <match sdnc.configMgr.sync.logs>
      @type mongo
      host {{ include "mongodb.fqdn" . }}
      port 8006
      database events
      collection sdnc.configMgr.sync.logs

      # authentication
      user {{ .Values.global.eventsDB.username }}
      password {{ .Values.global.eventsDB.password }}

      <inject>
        time_key evt_time_gmt
      </inject>

      <buffer>
        flush_interval 1s
      </buffer>
    </match>

    <source>
      @type tail
      path {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.svcName  }}.log
      pos_file {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.svcName  }}.log.pos
      tag sdnc.configMgr.logs
      read_from_head true
      <parse>
        @type json
        time_key evt_time_gmt
        time_format %Y-%m-%dT%H:%M:%SZ
      </parse>
    </source>

    <match sdnc.configMgr.logs>
      @type mongo
      host {{ include "mongodb.fqdn" . }}
      port 8006
      database events
      collection sdnc.configMgr.logs

      # authentication
      user {{ .Values.global.eventsDB.username }}
      password {{ .Values.global.eventsDB.password }}

      <inject>
        time_key evt_time_gmt
      </inject>

      <buffer>
        flush_interval 5s
      </buffer>
    </match>
    {{- else if contains "netconf" .Values.svcName }}
    <source>
      @type tail
      path {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.svcName  }}.log
      pos_file {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.svcName  }}.log.pos
      tag sdnc.netconfSvc.logs
      read_from_head true
      <parse>
        @type json
        time_key evt_time_gmt
        time_format %Y-%m-%dT%H:%M:%SZ
      </parse>
    </source>

    <match sdnc.netconfSvc.logs>
      @type mongo
      host {{ include "mongodb.fqdn" . }}
      port 8006
      database events
      collection sdnc.netconfSvc.logs

      # authentication
      user {{ .Values.global.eventsDB.username }}
      password {{ .Values.global.eventsDB.password }}

      <inject>
        time_key evt_time_gmt
      </inject>

      <buffer>
        flush_interval 5s
      </buffer>
    </match>

    <source>
      @type tail
      path {{ .Values.sdnc.volume.log.pvc.mountPath }}/netconf-command.log
      pos_file {{ .Values.sdnc.volume.log.pvc.mountPath }}/netconf-command.log.pos
      tag sdnc.netconfSvc.netconfCommand.logs
      read_from_head true
      <parse>
        @type json
        time_key evt_time_gmt
        time_format %Y-%m-%dT%H:%M:%SZ
      </parse>
    </source>

    <match sdnc.netconfSvc.netconfCommand.logs>
      @type mongo
      host {{ include "mongodb.fqdn" . }}
      port 8006
      database events
      collection sdnc.netconfCommand.logs

      # authentication
      user {{ .Values.global.eventsDB.username }}
      password {{ .Values.global.eventsDB.password }}

      <inject>
        time_key evt_time_gmt
      </inject>

      <buffer>
        flush_interval 5s
      </buffer>
    </match>

    <source>
      @type tail
      path {{ .Values.sdnc.volume.log.pvc.mountPath }}/netconf-notification.log
      pos_file {{ .Values.sdnc.volume.log.pvc.mountPath }}/netconf-notification.log.pos
      tag sdnc.netconfSvc.netconfNotification.logs
      read_from_head true
      <parse>
        @type json
        time_key evt_time_gmt
        time_format %Y-%m-%dT%H:%M:%SZ
      </parse>
    </source>

    <match sdnc.netconfSvc.netconfNotification.logs>
      @type mongo
      host {{ include "mongodb.fqdn" . }}
      port 8006
      database events
      collection sdnc.netconfCommand.logs

      # authentication
      user {{ .Values.global.eventsDB.username }}
      password {{ .Values.global.eventsDB.password }}

      <inject>
        time_key evt_time_gmt
      </inject>

      <buffer>
        flush_interval 5s
      </buffer>
    </match>
    {{- else if contains "tpce" .Values.svcName }}
    <source>
      @type tail
      path {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.svcName  }}.log
      pos_file {{ .Values.sdnc.volume.log.pvc.mountPath }}/{{ .Values.svcName  }}.log.pos
      tag sdnc.tpce.logs
      read_from_head true
      <parse>
        @type json
        time_key evt_time_gmt
        time_format %Y-%m-%dT%H:%M:%SZ
      </parse>
    </source>

    <match sdnc.tpce.logs>
      @type mongo
      host {{ include "mongodb.fqdn" . }}
      port 8006
      database events
      collection sdnc.tpce.logs

      # authentication
      user {{ .Values.global.eventsDB.username }}
      password {{ .Values.global.eventsDB.password }}

      <inject>
        time_key evt_time_gmt
      </inject>

      <buffer>
        flush_interval 5s
      </buffer>
    </match>

    <source>
      @type tail
      path {{ .Values.sdnc.volume.log.pvc.mountPath }}/netconf-command.log
      pos_file {{ .Values.sdnc.volume.log.pvc.mountPath }}/netconf-command.log.pos
      tag sdnc.tpce.netconfCommand.logs
      read_from_head true
      <parse>
        @type json
        time_key evt_time_gmt
        time_format %Y-%m-%dT%H:%M:%SZ
      </parse>
    </source>

    <match sdnc.tpce.netconfCommand.logs>
      @type mongo
      host {{ include "mongodb.fqdn" . }}
      port 8006
      database events
      collection sdnc.netconfCommand.logs

      # authentication
      user {{ .Values.global.eventsDB.username }}
      password {{ .Values.global.eventsDB.password }}

      <inject>
        time_key evt_time_gmt
      </inject>

      <buffer>
        flush_interval 5s
      </buffer>
    </match>
    {{- end }}
{{- end }}
