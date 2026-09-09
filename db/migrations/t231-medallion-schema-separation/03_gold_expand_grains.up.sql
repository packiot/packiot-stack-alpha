-- t231 · Medallion schema separation — PHASE 3 (GOLD, EXPAND)
-- DB: packiot_analytics (STAGING). Applied 2026-09-09.
--
-- Move the computed OEE grains into a `gold` schema and leave an auto-updatable
-- public shim VIEW at each old name (expand/contract). All gold objects are
-- PLAIN tables, so SET SCHEMA is a trivial catalog op. Continuous aggregates,
-- bi.* views, serving functions and TSDB policies follow by OID (no edit).
--
-- SHIM-SAFETY (hardproofed): every writer of these grains uses a form that
-- traverses an auto-updatable view —
--   * rollup piot_create_equipment_oee_*  : INSERT ... ON CONFLICT DO NOTHING (bare)
--   * edge-api production-targets DAO      : INSERT ... ON CONFLICT (id_equipment, ts_value) DO UPDATE
--   * analytics-sync replicate/replay      : plain INSERT ... SELECT / UPDATE ... FROM
-- No writer uses `ON CONFLICT ON CONSTRAINT <name>` (the only form that cannot
-- traverse a view). Proven live: gold.equipment_oee_hourly.computed_at advanced
-- through the shim during a rollup tick.
--
-- LOCK DISCIPLINE: the hot grains (equipment_oee_hourly / _daily) are written by
-- ~20s line-lead rollup transactions holding RowExclusiveLock. SET SCHEMA needs
-- ACCESS EXCLUSIVE, so run each move with lock_timeout + retry so it queues and
-- grabs the lock the instant the rollup txn commits (sub-second hold). These are
-- rollup OUTPUTS, not live ingest — a brief queued stall on the rollup is benign.
--
-- Apply each table in its OWN transaction (not one big txn) to minimise lock
-- hold and contention. Pseudocode for the runner:
--   for t in <grains>:
--     retry (lock_timeout='30s'):
--       BEGIN;
--       ALTER TABLE public.<t> SET SCHEMA gold;
--       CREATE VIEW public.<t> AS SELECT * FROM gold.<t>;
--       COMMIT;
--
-- GOLD SET = computed OEE grains only. Target-CONFIG tables (oee_targets,
-- production_targets, scrap_targets) and Hasura serving materializations
-- (h_piot_oee_*) STAY in public — they are inputs/serving, not computed grains.

CREATE SCHEMA IF NOT EXISTS gold;

SET lock_timeout = '30s';
-- equipment_oee_shift
BEGIN; ALTER TABLE public.equipment_oee_shift SET SCHEMA gold;
CREATE VIEW public.equipment_oee_shift AS SELECT * FROM gold.equipment_oee_shift; COMMIT;
-- equipment_oee_hourly (hot)
BEGIN; ALTER TABLE public.equipment_oee_hourly SET SCHEMA gold;
CREATE VIEW public.equipment_oee_hourly AS SELECT * FROM gold.equipment_oee_hourly; COMMIT;
-- equipment_oee_daily (hot)
BEGIN; ALTER TABLE public.equipment_oee_daily SET SCHEMA gold;
CREATE VIEW public.equipment_oee_daily AS SELECT * FROM gold.equipment_oee_daily; COMMIT;
-- equipment_oee_weekly
BEGIN; ALTER TABLE public.equipment_oee_weekly SET SCHEMA gold;
CREATE VIEW public.equipment_oee_weekly AS SELECT * FROM gold.equipment_oee_weekly; COMMIT;
-- equipment_oee_monthly
BEGIN; ALTER TABLE public.equipment_oee_monthly SET SCHEMA gold;
CREATE VIEW public.equipment_oee_monthly AS SELECT * FROM gold.equipment_oee_monthly; COMMIT;
-- equipment_oee_shift_weekly
BEGIN; ALTER TABLE public.equipment_oee_shift_weekly SET SCHEMA gold;
CREATE VIEW public.equipment_oee_shift_weekly AS SELECT * FROM gold.equipment_oee_shift_weekly; COMMIT;
-- equipment_oee_shift_monthly
BEGIN; ALTER TABLE public.equipment_oee_shift_monthly SET SCHEMA gold;
CREATE VIEW public.equipment_oee_shift_monthly AS SELECT * FROM gold.equipment_oee_shift_monthly; COMMIT;
-- area_oee_daily
BEGIN; ALTER TABLE public.area_oee_daily SET SCHEMA gold;
CREATE VIEW public.area_oee_daily AS SELECT * FROM gold.area_oee_daily; COMMIT;
-- area_oee_shift
BEGIN; ALTER TABLE public.area_oee_shift SET SCHEMA gold;
CREATE VIEW public.area_oee_shift AS SELECT * FROM gold.area_oee_shift; COMMIT;
-- site_oee_daily
BEGIN; ALTER TABLE public.site_oee_daily SET SCHEMA gold;
CREATE VIEW public.site_oee_daily AS SELECT * FROM gold.site_oee_daily; COMMIT;
-- site_oee_shift
BEGIN; ALTER TABLE public.site_oee_shift SET SCHEMA gold;
CREATE VIEW public.site_oee_shift AS SELECT * FROM gold.site_oee_shift; COMMIT;
-- production_orders_runtime (PO OEE grain)
BEGIN; ALTER TABLE public.production_orders_runtime SET SCHEMA gold;
CREATE VIEW public.production_orders_runtime AS SELECT * FROM gold.production_orders_runtime; COMMIT;

-- CONTRACT (drop the public shims) is DEFERRED to t231 PHASE 5, after the
-- stream-engine deploy repoints the rollup + analytics-sync + bake.go off the
-- `public.` grain names (writer-audit lesson #186: never drop the compat surface
-- until every writer is confirmed off it).
