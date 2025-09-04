CREATE DATABASE IF NOT EXISTS sdnc;

USE sdnc;

CREATE TABLE pm_collector_olt
(
    CreatedAt               DateTime                            CODEC(Delta, ZSTD(1)),
    deviceId                LowCardinality(String)              CODEC(ZSTD(1)),
    resourceType            LowCardinality(String)              CODEC(ZSTD(1)),
    portIdentifier          LowCardinality(String)              CODEC(ZSTD(1)),
    metrics                 Map(String, Float64)                CODEC(ZSTD(1))
)
ENGINE ReplacingMergeTree(CreatedAt)
PARTITION BY (toMonth(CreatedAt))
ORDER BY (-toUnixTimestamp(CreatedAt), deviceId, resourceType, portIdentifier)
SETTINGS index_granularity=8194;

CREATE TABLE pm_collector_onu
(
    CreatedAt               DateTime                            CODEC(Delta, ZSTD(1)),
    deviceId                LowCardinality(String)              CODEC(ZSTD(1)),
    resourceType            LowCardinality(String)              CODEC(ZSTD(1)),
    portIdentifier          LowCardinality(String)              CODEC(ZSTD(1)),
    metrics                 Map(String, Float64)                CODEC(ZSTD(1))
)
ENGINE ReplacingMergeTree(CreatedAt)
PARTITION BY (toMonth(CreatedAt))
ORDER BY (-toUnixTimestamp(CreatedAt), deviceId, resourceType, portIdentifier)
SETTINGS index_granularity=8194;

CREATE TABLE pm_collector_saber
(
    CreatedAt               DateTime                            CODEC(Delta, ZSTD(1)),
    deviceId                LowCardinality(String)              CODEC(ZSTD(1)),
    resourceType            LowCardinality(String)              CODEC(ZSTD(1)),
    portIdentifier          LowCardinality(String)              CODEC(ZSTD(1)),
    metrics                 Map(String, Float64)                CODEC(ZSTD(1))
)
ENGINE ReplacingMergeTree(CreatedAt)
PARTITION BY (toMonth(CreatedAt))
ORDER BY (-toUnixTimestamp(CreatedAt), deviceId, resourceType, portIdentifier)
SETTINGS index_granularity=8194;
