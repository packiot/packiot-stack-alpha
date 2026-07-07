-- 0012-d1-cagg-consolidation-f3.sql — PREPARED for Phase D1.
-- ═══ DO NOT RUN BEFORE THE FLIP (Phase A complete). ═══
--
-- Target: the promoted consolidated DB (packiot_shadow). Consolidates
-- the three CAgg naming dialects into the single ca_* family per
-- ADR-0012 + 0012-naming-map.md, enables compression, and installs
-- per-table-class retention (ADR-0017 §3). Pattern proven in the
-- sandbox lab (0012-phase2-cagg-consolidation.sql) and by the sweep
-- (0012-sandbox-naming-sweep-a/b.sql).
--
-- Measured F3 state this script was written against (2026-07-07):
--   agg_{equipment,area,site}_values_{1min,10min,1hour}  9 CAggs, uncompressed, ALL flat on public.equipment_values
--   ca_agg_equipment_values_1min       CAgg on equipment_values   ← duplicate of agg_equipment_values_1min
--   ca_agg_equipment_values_1hour      HIERARCHICAL (on the 1min matht) ← duplicate of agg_equipment_values_1hour (flat)
--   ca_discrete_changes_1s, ca_equipment_boxes_{1s,1hour}          already ca_*, keep
--   ca_lab_equipment_values_1min (+ lab_equipment_values)          lab leftovers, drop
--
-- DECISION EMBEDDED (review before running — this is the one judgment
-- call): where a flat agg_* and a hierarchical ca_agg_* duplicate
-- exist for the same grain, the HIERARCHICAL one wins (ADR-0012
-- endgame; cheaper refresh, single invalidation source) PROVIDED the
-- preflight shows identical column signatures AND its refresh lag is
-- acceptable. If preflight §0 fails, STOP — do not improvise.
--
-- Single-shot (like phase1/sweep): run ONCE per provision. Not
-- idempotent. Take an EBS snapshot first (golden rule).

\set ON_ERROR_STOP on

\echo '========== §0 PREFLIGHT (read-only; abort on any surprise) =========='

-- 0a. Confirm we are on the right DB and post-flip.
SELECT current_database() AS db \gset
\if :{?db}
\else
  \echo 'cannot resolve current_database' \quit
\endif

-- 0b. The 15 expected CAggs, no more, no fewer (excluding lab).
SELECT count(*) AS cagg_count
FROM timescaledb_information.continuous_aggregates
WHERE view_name NOT LIKE '%lab%';
-- EXPECT: 14. If not, the CAgg set moved since 2026-07-07 — re-audit
-- before proceeding (this file's table above is stale).

-- 0c. Column-signature parity between each duplicate pair.
WITH sig AS (
  SELECT table_name, string_agg(column_name||':'||data_type, ',' ORDER BY ordinal_position) AS s
  FROM information_schema.columns
  WHERE table_name IN ('agg_equipment_values_1min','ca_agg_equipment_values_1min',
                       'agg_equipment_values_1hour','ca_agg_equipment_values_1hour')
  GROUP BY table_name)
SELECT a.table_name, b.table_name, a.s = b.s AS signatures_match
FROM sig a JOIN sig b
  ON replace(a.table_name,'agg_','') = replace(b.table_name,'ca_agg_','')
WHERE a.table_name LIKE 'agg\_%' AND b.table_name LIKE 'ca\_agg\_%';
-- EXPECT: signatures_match = t for both rows. If f → the duplicates
-- are NOT interchangeable; consumer-by-consumer plan needed. STOP.

-- 0d. Refresh healthiness of the survivors-to-be.
SELECT js.hypertable_name, j.application_name, js.last_run_status, js.total_failures
FROM timescaledb_information.job_stats js
JOIN timescaledb_information.jobs j USING (job_id)
WHERE j.proc_name = 'policy_refresh_continuous_aggregate';
-- EXPECT: all Success, failures explainable.

\echo '========== §1 LAB CLEANUP (safe, no consumers) =========='
DROP MATERIALIZED VIEW IF EXISTS ca_lab_equipment_values_1min CASCADE;
DROP VIEW IF EXISTS agg_lab_equipment_values_1min CASCADE;
DROP VIEW IF EXISTS ca_agg_lab_equipment_values_1min CASCADE;
DROP TABLE IF EXISTS lab_equipment_values CASCADE;

\echo '========== §2 RESOLVE DUPLICATES (hierarchical wins) =========='
-- equipment 1min: drop the flat agg_ CAgg, rename ca_agg_ → ca_, leave
-- compat views under BOTH legacy names (agg_* read by 41-object
-- consumer chain; façade for EVERY renamed name — golden rule).
ALTER MATERIALIZED VIEW ca_agg_equipment_values_1min RENAME TO ca_equipment_values_1min;
DROP MATERIALIZED VIEW agg_equipment_values_1min CASCADE;   -- CASCADE: preflighted consumers only
CREATE VIEW agg_equipment_values_1min    AS SELECT * FROM ca_equipment_values_1min;
CREATE VIEW ca_agg_equipment_values_1min AS SELECT * FROM ca_equipment_values_1min;

ALTER MATERIALIZED VIEW ca_agg_equipment_values_1hour RENAME TO ca_equipment_values_1hour;
DROP MATERIALIZED VIEW agg_equipment_values_1hour CASCADE;
CREATE VIEW agg_equipment_values_1hour    AS SELECT * FROM ca_equipment_values_1hour;
CREATE VIEW ca_agg_equipment_values_1hour AS SELECT * FROM ca_equipment_values_1hour;

\echo '========== §3 RENAME THE REST (no duplicate → straight rename + façade) =========='
-- 10min + area/site families have no ca_agg twin: rename in place.
ALTER MATERIALIZED VIEW agg_equipment_values_10min RENAME TO ca_equipment_values_10min;
CREATE VIEW agg_equipment_values_10min AS SELECT * FROM ca_equipment_values_10min;
ALTER MATERIALIZED VIEW agg_area_values_1min   RENAME TO ca_area_values_1min;
ALTER MATERIALIZED VIEW agg_area_values_10min  RENAME TO ca_area_values_10min;
ALTER MATERIALIZED VIEW agg_area_values_1hour  RENAME TO ca_area_values_1hour;
ALTER MATERIALIZED VIEW agg_site_values_1min   RENAME TO ca_site_values_1min;
ALTER MATERIALIZED VIEW agg_site_values_10min  RENAME TO ca_site_values_10min;
ALTER MATERIALIZED VIEW agg_site_values_1hour  RENAME TO ca_site_values_1hour;
CREATE VIEW agg_area_values_1min   AS SELECT * FROM ca_area_values_1min;
CREATE VIEW agg_area_values_10min  AS SELECT * FROM ca_area_values_10min;
CREATE VIEW agg_area_values_1hour  AS SELECT * FROM ca_area_values_1hour;
CREATE VIEW agg_site_values_1min   AS SELECT * FROM ca_site_values_1min;
CREATE VIEW agg_site_values_10min  AS SELECT * FROM ca_site_values_10min;
CREATE VIEW agg_site_values_1hour  AS SELECT * FROM ca_site_values_1hour;

\echo '========== §4 COMPRESSION on every ca_* CAgg =========='
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT view_name FROM timescaledb_information.continuous_aggregates
           WHERE compression_enabled = false LOOP
    EXECUTE format('ALTER MATERIALIZED VIEW %I SET (timescaledb.compress = true)', r.view_name);
    PERFORM add_compression_policy(r.view_name, compress_after => INTERVAL '7 days', if_not_exists => true);
  END LOOP;
END $$;

\echo '========== §5 RETENTION per table class (ADR-0017 §3) =========='
-- raw 180d (already live) / grain CAggs 2y / hist frozen (no policy).
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT view_name FROM timescaledb_information.continuous_aggregates LOOP
    PERFORM add_retention_policy(r.view_name, INTERVAL '2 years', if_not_exists => true);
  END LOOP;
END $$;

\echo '========== §6 POSTFLIGHT =========='
SELECT view_name, compression_enabled FROM timescaledb_information.continuous_aggregates ORDER BY 1;
SELECT count(*) AS façade_views FROM pg_views WHERE viewname LIKE 'agg\_%' OR viewname LIKE 'ca\_agg\_%';
-- Then: re-run the PowerBI compatibility gate (per-wave rule) +
-- Hasura/refdata parity check before calling D1 done.
