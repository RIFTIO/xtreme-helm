CREATE DATABASE IF NOT EXISTS aeo_data;

USE aeo_data;

-- Service record details
CREATE TABLE service_record_details
(
    `service-record-id`                 String                          CODEC(ZSTD(1)),
    `status`                            LowCardinality(String)          CODEC(ZSTD(1)),
    `subscriber-id`                     String                          CODEC(ZSTD(1)),
    `olt-device-id`                     Array(String)                   CODEC(ZSTD(1)),
    `onu-info`                          Array(Map(String, String))      CODEC(ZSTD(1)),
    `associated-resource-oper-id-ref`   Array(String)                   CODEC(ZSTD(1))
)
ENGINE MergeTree()
PARTITION BY tuple()
ORDER BY (`service-record-id`)
SETTINGS index_granularity=8194;

-- Resource Operation Details
CREATE TABLE resource_operation_details
(
    `resource-op-id`                    String                          CODEC(ZSTD(1)),
    `op-start-time`                     DateTime                        CODEC(ZSTD(1)),
    `op-end-time`                       DateTime                        CODEC(ZSTD(1)),
    `status`                            LowCardinality(String)          CODEC(ZSTD(1)),
    `service-operation-name`            LowCardinality(String)          CODEC(ZSTD(1)),
    `op-type`                           LowCardinality(String)          CODEC(ZSTD(1)),
    `sdnc-account`                      LowCardinality(String)          CODEC(ZSTD(1)),
    `service-type`                      LowCardinality(String)          CODEC(ZSTD(1)),
    `associated-service-record-id-ref`  String                          CODEC(ZSTD(1)),
    `input-parameter`                   Array(Map(String, String))      CODEC(ZSTD(1))

)
ENGINE MergeTree()
PARTITION BY tuple()
ORDER BY (`resource-op-id`)
SETTINGS index_granularity=8194;

-- Service Order Details
CREATE TABLE service_order_details
(
    `service-order-id`                  String                          CODEC(ZSTD(1)),
    `state`                             LowCardinality(String)          CODEC(ZSTD(1)),
    `service-order-item`                Array(Map(String, String))      CODEC(ZSTD(1))
)
ENGINE MergeTree()
PARTITION BY tuple()
ORDER BY (`service-order-id`)
SETTINGS index_granularity=8194;

-- Service States
CREATE TABLE service_states
(
    `service-state-id`                  String                          CODEC(ZSTD(1)),
    `category`                          LowCardinality(String)          CODEC(ZSTD(1)),
    `service-date`                      DateTime                        CODEC(ZSTD(1)),
    `state`                             LowCardinality(String)          CODEC(ZSTD(1)),
    `name`                              LowCardinality(String)          CODEC(ZSTD(1))
)
ENGINE MergeTree()
PARTITION BY tuple()
ORDER BY (`service-state-id`)
SETTINGS index_granularity=8194;

-- Service Record Order Mapping
CREATE TABLE service_record_order_mapping
(
    `subscriber-id`                     String,
    `service-order-ids`                 Array(String),
    `service-record-id`                 Nullable(String)
)
ENGINE MergeTree()
PARTITION BY tuple()
ORDER BY (`subscriber-id`)
SETTINGS index_granularity=8194;
