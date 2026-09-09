-- t231 · Medallion schema separation — PHASE 1 (BRONZE)
-- DB: packiot_analytics (STAGING). Applied 2026-09-09.
--
-- Move the two dormant ADR-0036 immutable-append landing hypertables into a
-- dedicated `bronze` schema. Both have 0 chunks (BRONZE_RAW_APPEND=false), so
-- this is a pure catalog relocation. TimescaleDB compression + retention jobs
-- re-point to the new schema automatically (proven: jobs 1027-1030 followed).
--
-- Chunks physically live in _timescaledb_internal regardless of the logical
-- hypertable schema, so SET SCHEMA is metadata-only and sub-second.
BEGIN;
CREATE SCHEMA IF NOT EXISTS bronze;
ALTER TABLE public.equipment_values_raw SET SCHEMA bronze;
ALTER TABLE public.equipment_events_raw SET SCHEMA bronze;
COMMIT;

-- NOTE: the stream-engine Bronze writer (writers/equipment_values.go
-- BuildRawAppend / BuildEventMintRaw) targets `<schema>.equipment_values_raw`
-- where <schema> is the routed Dest schema. It is DORMANT on staging
-- (BRONZE_RAW_APPEND unset → false). When it is enabled it must be pointed at
-- `bronze` via Dest.BronzeSchema (t231 PHASE 5 code lift). Until then, no live
-- writer references these tables (verified: 0 view/rewrite dependents).
