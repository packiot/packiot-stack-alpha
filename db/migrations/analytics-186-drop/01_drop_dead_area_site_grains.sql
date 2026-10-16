-- 01_drop_dead_area_site_grains.sql  (#186)
--
-- Drop the necessity-proven-DEAD area/site HOUR/WEEK/MONTH oee grains, their
-- *_live_* UNS derivatives, and the six seed procs that populate them.
--
-- ── NECESSITY (triple-signal, agent-audited 2026-09-06) ──────────────────────
-- CODE: the only refs were the stream-engine writers (now removed — writer-stop
--   deployed in the PR that added this file) + the rename migration. Zero readers
--   in any repo (read-api datasets.go exposes only equipment-level live/oee; the
--   sole live area/site consumer, front4 mission control via
--   h_piot_get_mission_control_area_uns_2, reads only the DAY/SHIFT chain).
-- DB DEPS: pg_depend/pg_rewrite → 0 views/matviews/rules/FKs on any of these 12
--   tables. Rename compat shims already dropped.
-- USAGE: reads attributable only to the writer pipeline; site_live_* never even
--   populated (idx_scan=0, n_live_tup=0).
--
-- ── ORDERING (safety) ────────────────────────────────────────────────────────
-- MUST run only AFTER the writer-stop (entity_grains.go/uns.go/current_rest.go)
-- is DEPLOYED — otherwise the running worker writes to a dropped table and errors
-- every tick. The day-recalc flag for area/site is re-sourced from the tier-below
-- day grain in that deploy, so area/site day+shift freshness is preserved.
--
-- Reversible only by restore-from-backup (these are derived aggregates,
-- recomputable by re-seeding + a rollup pass if ever needed). Idempotent via
-- IF EXISTS. Run against packiot_analytics.

\set ON_ERROR_STOP on
BEGIN;

-- Seed procs first (they reference the tables in their bodies).
DROP FUNCTION IF EXISTS piot_create_area_runtime_1hour();
DROP FUNCTION IF EXISTS piot_create_area_runtime_1week();
DROP FUNCTION IF EXISTS piot_create_area_runtime_1month();
DROP FUNCTION IF EXISTS piot_create_site_runtime_1hour();
DROP FUNCTION IF EXISTS piot_create_site_runtime_1week();
DROP FUNCTION IF EXISTS piot_create_site_runtime_1month();

-- UNS live derivatives (pure sinks, no dependents).
DROP TABLE IF EXISTS area_live_hour;
DROP TABLE IF EXISTS area_live_week;
DROP TABLE IF EXISTS area_live_month;
DROP TABLE IF EXISTS site_live_hour;
DROP TABLE IF EXISTS site_live_week;
DROP TABLE IF EXISTS site_live_month;

-- The dead oee grains.
DROP TABLE IF EXISTS area_oee_hourly;
DROP TABLE IF EXISTS area_oee_weekly;
DROP TABLE IF EXISTS area_oee_monthly;
DROP TABLE IF EXISTS site_oee_hourly;
DROP TABLE IF EXISTS site_oee_weekly;
DROP TABLE IF EXISTS site_oee_monthly;

COMMIT;
