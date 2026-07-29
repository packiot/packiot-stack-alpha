-- ADR-0041 / ADR-0036 §2.4 — Glue Data Catalog DDL for the offline lakehouse (Athena engine v3 / Trino dialect)
--
-- SCAFFOLD — NOT executed by any migration runner. This is Athena DDL to run BY HAND
-- (Athena console / `aws athena start-query-execution`) or via CI ONLY AFTER P0 is approved
-- and the S3 lake (terraform/modules/lakehouse) is stood up in staging (P1). No prod, no GCP.
--
-- Design: docs/adr/reference/designs/0041-lakehouse-build-plan.md
-- Decision: docs/adr/0041-gcp-exit-lakehouse.md
--
-- Substitute ${env} (staging|prod) before running. Tables use PARTITION PROJECTION
-- (no crawler): partitions are computed from the query predicate at plan time.
-- Partition columns (id_enterprise, dt) live in the S3 PATH, not in the parquet payload.

CREATE DATABASE IF NOT EXISTS bronze
  COMMENT 'ADR-0041 offline lakehouse — immutable raw tier (export of equipment_*_raw)';

CREATE DATABASE IF NOT EXISTS gold
  COMMENT 'ADR-0041 offline lakehouse — reporting rollups (equipment_runtime_*, cq_logs)';

-- ─────────────────────────────────────────────────────────────────────────────
-- bronze.equipment_values_raw  (source: TimescaleDB equipment_values_raw, ADR-0036 §3.6 B1)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE EXTERNAL TABLE IF NOT EXISTS bronze.equipment_values_raw (
  ts_value                    timestamp,
  id_site                     int,
  id_area                     int,
  id_equipment                int,
  net_production_incr         double,
  gross_production_incr       double,
  scrap_incr                  double,
  net_production_val          double,
  gross_production_val        double,
  scrap_val                   double,
  speed                       float,
  state                       int,
  mode                        int,
  sub_mode                    string,
  tp_equipment                smallint,
  id_production_order         bigint,
  signal_quality              smallint,
  faults                      string,   -- jsonb serialized as text; query via json_parse/json_extract
  analogs                     string,
  id_order                    string,
  conversion_factor           float,
  number_cavities             int,
  id_team                     int,
  box_code                    string,
  transaction_code            string,
  ts_value_production         date,
  ideal_production_speed      int,
  id_shift                    int,
  id_equipment_line_connected int,
  position_in_equipment_line  smallint,
  is_equipment_line_infeed    smallint,
  is_equipment_line_outfeed   smallint,
  process_scrap_incr          double,
  process_scrap_val           double,
  check_number                bigint,
  id_shift_hour               int,
  id_equipment_line_infeed    int,
  id_equipment_line_outfeed   int,
  ingested_at                 timestamp,  -- B1 lineage
  source_seq                  bigint      -- B1 lineage; part of Bronze PK (id_equipment, ts_value, source_seq)
)
PARTITIONED BY (id_enterprise int, dt date)
STORED AS PARQUET
LOCATION 's3://packiot-lake-${env}/bronze/equipment_values_raw/'
TBLPROPERTIES (
  'parquet.compression'            = 'SNAPPY',
  'projection.enabled'             = 'true',
  'projection.id_enterprise.type'  = 'integer',
  'projection.id_enterprise.range' = '1,100000',
  'projection.dt.type'             = 'date',
  'projection.dt.range'            = '2024-01-01,NOW',
  'projection.dt.format'           = 'yyyy-MM-dd',
  'projection.dt.interval'         = '1',
  'projection.dt.interval.unit'    = 'DAYS',
  'storage.location.template'      = 's3://packiot-lake-${env}/bronze/equipment_values_raw/id_enterprise=${id_enterprise}/dt=${dt}/'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- bronze.equipment_events_raw  (source: TimescaleDB equipment_events_raw, ADR-0036 §3.6 B1)
-- id_equipment_event (BIGSERIAL) is dropped in _raw; Bronze PK = (id_equipment, ts_event, source_seq)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE EXTERNAL TABLE IF NOT EXISTS bronze.equipment_events_raw (
  ts_event                timestamp,
  id_equipment            int,
  status                  int,
  txt_downtime_notes      string,
  idle                    string,
  idle_processed          boolean,
  forced_creation_system  boolean,
  fault                   int,
  fault_processed         boolean,
  cd_machine              string,
  cd_category             string,
  cd_subcategory          string,
  change_over             boolean,
  planned_downtime        boolean,
  ts_end                  timestamp,
  duration                int,
  desc_category           string,
  desc_subcategory        string,
  cd_category_client      int,
  cd_subcategory_client   int,
  last_update             timestamp,
  ignore_cost             boolean,
  ingested_at             timestamp,   -- B1 lineage
  source_seq              bigint       -- B1 lineage; part of Bronze PK
)
PARTITIONED BY (id_enterprise int, dt date)
STORED AS PARQUET
LOCATION 's3://packiot-lake-${env}/bronze/equipment_events_raw/'
TBLPROPERTIES (
  'parquet.compression'            = 'SNAPPY',
  'projection.enabled'             = 'true',
  'projection.id_enterprise.type'  = 'integer',
  'projection.id_enterprise.range' = '1,100000',
  'projection.dt.type'             = 'date',
  'projection.dt.range'            = '2024-01-01,NOW',
  'projection.dt.format'           = 'yyyy-MM-dd',
  'projection.dt.interval'         = '1',
  'projection.dt.interval.unit'    = 'DAYS',
  'storage.location.template'      = 's3://packiot-lake-${env}/bronze/equipment_events_raw/id_enterprise=${id_enterprise}/dt=${dt}/'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- gold.equipment_runtime_shift  (source: TimescaleDB Gold rollup — reporting source)
-- Columns are the rollup's own; declare them at P2 from the live table's \d output.
-- Shown here as the projection template all gold.* tables share (same partitioning).
-- Repeat the pattern for equipment_runtime_1hour / _1day / cq_logs.
-- ─────────────────────────────────────────────────────────────────────────────
-- CREATE EXTERNAL TABLE IF NOT EXISTS gold.equipment_runtime_shift ( <rollup columns> )
-- PARTITIONED BY (id_enterprise int, dt date)
-- STORED AS PARQUET
-- LOCATION 's3://packiot-lake-${env}/gold/equipment_runtime_shift/'
-- TBLPROPERTIES ( ...same projection props, storage.location.template pointed at gold/... );
