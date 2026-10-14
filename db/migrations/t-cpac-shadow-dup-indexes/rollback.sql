-- rollback for t-cpac-shadow-dup-indexes — recreate the two redundant unique indexes exactly as
-- they were (definitions from pg_get_indexdef on staging, 2026-10-14). Nothing needs them; roll
-- back only to restore the previous catalog byte for byte.
-- NON-TRANSACTIONAL (CREATE INDEX CONCURRENTLY): run without -1. A failed concurrent build
-- leaves an INVALID index that IF NOT EXISTS would then skip: check
--   SELECT relname FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid WHERE NOT i.indisvalid;
-- and DROP INDEX CONCURRENTLY it before re-running.
\set ON_ERROR_STOP 1
SET lock_timeout = '30s';
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS equipment_events_cpac_shadow_key
    ON silver.equipment_events_cpac_shadow USING btree (id_equipment, ts_event);
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS equipment_events_cpac_shadow_id_equipment_ts_event_idx
    ON silver.equipment_events_cpac_shadow USING btree (id_equipment, ts_event);
