CREATE DATABASE IF NOT EXISTS aeo;

USE aeo;

-- Main service record table
CREATE TABLE aeo_service_analytics
(
	CreatedAt         DateTime               CODEC(Delta, ZSTD(1)),
	Project           LowCardinality(String) CODEC(ZSTD(2)),
    EventType         LowCardinality(String) CODEC(ZSTD(2)),
	CustomerId        String                 CODEC(ZSTD(1)),
    CustomerType      LowCardinality(String) CODEC(ZSTD(1)),
    ServiceOrderId    String                 CODEC(ZSTD(2)),
    ServiceName       LowCardinality(String) CODEC(ZSTD(2)),
	ServiceAction     LowCardinality(String) CODEC(ZSTD(2)),
	ExternalId        LowCardinality(String) CODEC(ZSTD(2)),
	ServiceType       LowCardinality(String) CODEC(ZSTD(2)),
	UpstreamBw        LowCardinality(String) CODEC(ZSTD(2)),
	DownstreamBw      LowCardinality(String) CODEC(ZSTD(2)),
	TransportType     LowCardinality(String) CODEC(ZSTD(2)),
	ServiceOrderState LowCardinality(String) CODEC(ZSTD(2)),
	CFSStateId        String                 CODEC(ZSTD(2)),
	CFSState          LowCardinality(String) CODEC(ZSTD(2)),
	RFSStateId        String                 CODEC(ZSTD(2)),
	RFSState          LowCardinality(String) CODEC(ZSTD(2)),
	ResourceInfo      Nested
	(
		ResourceOpId  String,
		Status        LowCardinality(String),
		DeviceId      String,
		DeviceType    LowCardinality(String),
		MfgName       LowCardinality(String),
		ModelName     LowCardinality(String),
		SerialNumber  String,
		MgmtIPAddress IPv6,
		AdminState    LowCardinality(String),
		SDNAccount    LowCardinality(String),
		OperationName LowCardinality(String)
	) CODEC(ZSTD(2)),
	OLTInfo           Nested
	(
		ResourceOpId    String,
		MgmtIPAddress   IPv6,
		CPEConnectionId String,
		CVLANId         LowCardinality(String),
		SVLANId		LowCardinality(String),
		PortId		String
	) CODEC(ZSTD(2)),
	ResourceEvents    Nested
	(
		ResourceOpId    String,
		Events          Array(Tuple(name String, OccuredAt String))
	) CODEC(ZSTD(2)),
	_EventNotifSource   String                CODEC(ZSTD(10)),
	_ResourceOpSource   String                CODEC(ZSTD(10)),
	_ResourceInstSource String                CODEC(ZSTD(10)),
	_DeviceInvSource    String                CODEC(ZSTD(10))

)
ENGINE MergeTree()
PARTITION BY (toStartOfMonth(CreatedAt))
ORDER BY (Project, CustomerId, -toUnixTimestamp(CreatedAt))
SETTINGS index_granularity=8194;

-- Customer metadata table
CREATE TABLE customer_metadata
(
	CustomerId	String                                     CODEC(ZSTD(1)),
	Name            String                                     CODEC(ZSTD(10)),
	Address         String                                     CODEC(ZSTD(10)),
	GeoLoc          Tuple(longitude Float64, latitude Float64) CODEC(ZSTD(1)),
	Location		String									CODEC(ZSTD(10))
)
ENGINE MergeTree()
PARTITION BY tuple()
ORDER BY (CustomerId)
SETTINGS index_granularity=1024;

-- OLT Join helper table
CREATE TABLE olt_customer_reverse_mapping
(
	IPAddress  IPv6   CODEC(ZSTD(1)),
	PortId     String CODEC(ZSTD(1)),
	CustomerId String CODEC(ZSTD(1))
)
ENGINE ReplacingMergeTree()
ORDER BY (IPAddress, PortId)
SETTINGS index_granularity=1024;

-- MV for auto populating
CREATE MATERIALIZED VIEW olt_customer_reverse_mapping_mv
TO olt_customer_reverse_mapping
AS
SELECT OLTInfo.MgmtIPAddress as IPAddress, OLTInfo.PortId as PortId, CustomerId
FROM aeo.aeo_service_analytics
ARRAY JOIN OLTInfo
WHERE IPv6NumToString(OLTInfo.MgmtIPAddress) != '' AND
      OLTInfo.PortId != '';
