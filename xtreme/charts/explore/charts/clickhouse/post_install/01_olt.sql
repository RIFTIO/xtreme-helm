CREATE DATABASE IF NOT EXISTS olt;

USE olt;

CREATE TABLE mxk_resource_metrics
(
    created_at    DateTime               CODEC(Delta, ZSTD(1)),
    project       LowCardinality(String) CODEC(ZSTD(1)),
    model         LowCardinality(String) CODEC(ZSTD(1)),
    serial        LowCardinality(String) CODEC(ZSTD(1)),
    ip_address    IPv6                   CODEC(ZSTD(1)),
    uptime        UInt64                 CODEC(DoubleDelta),
    card_resource Nested
    (
        card_num          Int16,
        avail_memory      UInt64,
        processor_usage   UInt8,
        peak_memory_usage UInt64,
        total_memory      UInt64,
        memory_status     UInt8,
        oper_status       UInt8
    ) CODEC(Delta, ZSTD(1))
)
ENGINE MergeTree()
PARTITION BY (toMonth(created_at), project)
ORDER BY (ip_address, -toUnixTimestamp(created_at))
SETTINGS index_granularity=8194;

CREATE TABLE mxk_network_service_metrics
(
    created_at      DateTime                                     CODEC(Delta, ZSTD(1)),
    project         LowCardinality(String)                       CODEC(ZSTD(1)),
    model           LowCardinality(String)                       CODEC(ZSTD(1)),
    serial          LowCardinality(String)                       CODEC(ZSTD(1)),
    ip_address      IPv6                                         CODEC(ZSTD(1)),
    level           Enum('physical'=1, 'logical'=2, 'service'=3),
    network_type    Enum('gpon'=1, 'ethernet'=2),
    port_identifier LowCardinality(String)                       CODEC(ZSTD(1)),
    counter_metric_name     Array(LowCardinality(String))        CODEC(ZSTD(1)),
    counter_metric_value    Array(UInt64)                        CODEC(DoubleDelta),
    gauge_metric_name       Array(LowCardinality(String))        CODEC(ZSTD(1)),
    gauge_metric_value      Array(Int64)                         CODEC(Delta, ZSTD(1)),
    vlan                    Nullable(Int16)                      CODEC(Delta, ZSTD(1)),
    slan                    Nullable(Int16)                      CODEC(Delta, ZSTD(1))
)
ENGINE MergeTree()
PARTITION BY (toMonth(created_at), project)
ORDER BY (ip_address, -toUnixTimestamp(created_at), level, network_type)
SETTINGS index_granularity=8194;
