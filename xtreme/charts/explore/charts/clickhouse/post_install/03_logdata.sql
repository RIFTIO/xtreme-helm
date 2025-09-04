CREATE DATABASE IF NOT EXISTS logdata;

USE logdata;

-- Table to store raw logs
CREATE TABLE platform_log_events
(
    `_id.$oid`                        FixedString(24)                     CODEC(ZSTD(1)),
    `metadata.timestamp.$date`        DateTime                            CODEC(Delta, ZSTD(1)),
    `metadata.event_time`             DateTime                            CODEC(Delta, ZSTD(1)),
    `metadata.event_module`           LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.event_name`             LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.description`            String                              CODEC(ZSTD(1)),
    `metadata.severity`               LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.appname`                LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.message`                String                              CODEC(ZSTD(1)),
    `attributes.trap_name`            LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.annotation`           String                              CODEC(ZSTD(1)),
    `attributes.error`                String                              CODEC(ZSTD(1)),
    `attributes.operation`            LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.datacenter`           LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.details`              String                              CODEC(ZSTD(1)),
    `attributes.datacenter_name`      LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.oper_status`          LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.failed_reason`        String                              CODEC(ZSTD(1)),
    `attributes.restored_oper_state`  LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.package_status`       LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.error_msg`            String                              CODEC(ZSTD(1)),
    `attributes.bug_info`             String                              CODEC(ZSTD(1)),
    `attributes.url`                  String                              CODEC(ZSTD(1)),
    `attributes.error_string`         String                              CODEC(ZSTD(1)),
    `attributes.packages`             String                              CODEC(ZSTD(1))
)
ENGINE MergeTree()
PARTITION BY (toMonth(`metadata.timestamp.$date`))
ORDER BY (-toUnixTimestamp(`metadata.timestamp.$date`), `_id.$oid`)
SETTINGS index_granularity=8194;

-- Table to store failure detections
CREATE TABLE failure_details
(
    `_id.$oid`                        FixedString(24)                     CODEC(ZSTD(1)),
    `metadata.timestamp.$date`        DateTime                            CODEC(Delta, ZSTD(1)),
    `metadata.event_module`           LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.event_name`             LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.description`            String                              CODEC(ZSTD(1)),
    `metadata.severity`               LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.appname`                LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.message`                String                              CODEC(ZSTD(1)),
    `attributes.trap_name`            LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.annotation`           String                              CODEC(ZSTD(1)),
    `attributes.error`                String                              CODEC(ZSTD(1)),
    `attributes.operation`            LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.datacenter`           LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.details`              String                              CODEC(ZSTD(1)),
    `attributes.datacenter_name`      LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.oper_status`          LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.failed_reason`        String                              CODEC(ZSTD(1)),
    `attributes.restored_oper_state`  LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.package_status`       LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.error_msg`            String                              CODEC(ZSTD(1)),
    `attributes.bug_info`             String                              CODEC(ZSTD(1)),
    `attributes.url`                  String                              CODEC(ZSTD(1)),
    `attributes.error_string`         String                              CODEC(ZSTD(1)),
    `attributes.packages`             String                              CODEC(ZSTD(1)),
    `FailureID`                       FixedString(53)                     CODEC(ZSTD(1))
)
ENGINE MergeTree()
PARTITION BY (toMonth(`metadata.timestamp.$date`))
ORDER BY (-toUnixTimestamp(`metadata.timestamp.$date`), `_id.$oid`)
SETTINGS index_granularity=8194;

-- Table to store root cause related to failures detected
CREATE TABLE rootcause_details
(
    `_id.$oid`                        FixedString(24)                     CODEC(ZSTD(1)),
    `metadata.timestamp.$date`        DateTime                            CODEC(Delta, ZSTD(1)),
    `metadata.event_module`           LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.event_name`             LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.description`            String                              CODEC(ZSTD(1)),
    `metadata.severity`               LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.appname`                LowCardinality(String)              CODEC(ZSTD(1)),
    `metadata.message`                String                              CODEC(ZSTD(1)),
    `attributes.trap_name`            LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.annotation`           String                              CODEC(ZSTD(1)),
    `attributes.error`                String                              CODEC(ZSTD(1)),
    `attributes.operation`            LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.datacenter`           LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.details`              String                              CODEC(ZSTD(1)),
    `attributes.datacenter_name`      LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.oper_status`          LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.failed_reason`        String                              CODEC(ZSTD(1)),
    `attributes.restored_oper_state`  LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.package_status`       LowCardinality(String)              CODEC(ZSTD(1)),
    `attributes.error_msg`            String                              CODEC(ZSTD(1)),
    `attributes.bug_info`             String                              CODEC(ZSTD(1)),
    `attributes.url`                  String                              CODEC(ZSTD(1)),
    `attributes.error_string`         String                              CODEC(ZSTD(1)),
    `attributes.packages`             String                              CODEC(ZSTD(1)),
    `ClusterID`                       LowCardinality(String)              CODEC(ZSTD(1)),
    `Weight`                          Float32                             CODEC(ZSTD(1)),
    `similarity`                      Float32                             CODEC(ZSTD(1)),
    `FailureID`                       FixedString(53)                     CODEC(ZSTD(1))
)
ENGINE MergeTree()
PARTITION BY (toMonth(`metadata.timestamp.$date`))
ORDER BY (-toUnixTimestamp(`metadata.timestamp.$date`), `_id.$oid`)
SETTINGS index_granularity=8194;
