-- t-adr0065-p4-hot-windows — ADR-0065 P4 (D5): shorten the raw hot windows in the retention catalog (2026-10-16).
--
--   bronze.equipment_values_raw / equipment_events_raw  90 d → 14 d  (replay buffer; silver is the archived copy)
--   silver.equipment_values                              90 d → 35 d  (covers the engine's 25-day shift recompute
--                                                                       + slack; older is served cold by the gateway)
--   silver.plc_link_minutes                              90 d → 35 d  (NO DATA spans persist in silver.equipment_events)
-- Unchanged on purpose: silver.equipment_events (5 y), the minute fact (90 d, ADR open question 1), gold.
--
-- SAFE BY CONSTRUCTION: ops.partition_maintain() drops a partition of a relation WITH a cold_copy only when every
-- (tenant, day) in it has a verified ops.cold_export row (P0 gate). bronze/plc_link have no cold copy BY DESIGN
-- (P0 migration header). Applied on staging 2026-10-16 20:04 UTC: 8 silver + 3 bronze partitions dropped, 0 blocked;
-- gateway read-back of a dropped tenant-day = manifest exactly (274,196 rows / 3,159,561 net).
-- PRODUCTION: do not apply before the P1 exporter runs there (prod raw retention is off, PROD_RAW_RETENTION=off).
-- Idempotent; rollback.sql restores the previous windows.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
UPDATE ops.retention_policy rp SET keep = v.keep::interval, updated_at = now()
  FROM (VALUES ('bronze.equipment_values_raw', '14 days'),
               ('bronze.equipment_events_raw', '14 days'),
               ('silver.equipment_values',     '35 days'),
               ('silver.plc_link_minutes',     '35 days')) v(rel, keep)
 WHERE rp.relation = v.rel AND rp.keep IS DISTINCT FROM v.keep::interval;
COMMIT;
