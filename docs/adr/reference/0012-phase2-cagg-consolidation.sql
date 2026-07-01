-- ADR-0012 Phase 2: CAgg naming consolidation + compression enablement.
-- Sandbox lab — proves the migration pattern before authoring the knex
-- migration for real staging DB.
--
-- Pathologies simulated:
--   1. Three parallel naming schemes for the same aggregate (agg_*, ca_agg_*, mv_agg_*_full_hot)
--   2. Uncompressed legacy CAggs alongside compressed newer ones
--   3. Refresh policy misconfiguration (schedule too infrequent → invalidation backlog)
--
-- Migration executed:
--   1. Drop the retired mv_*_full_hot design (0 rows on prod, 0 consumers)
--   2. Rename ca_agg_* → ca_* (drop the redundant "agg" middle token)
--   3. Rename agg_* → ca_* (with backward-compat view shim)
--   4. Enable compression on any newly-consolidated ca_* that lacks it
--   5. Tune refresh policy schedule_interval (fix the backlog condition)

\echo ''
\echo '========== PHASE 2 LAB SETUP =========='

-- Clean slate for re-runs
DROP MATERIALIZED VIEW IF EXISTS ca_lab_equipment_values_1min CASCADE;
DROP MATERIALIZED VIEW IF EXISTS ca_agg_lab_equipment_values_1min CASCADE;
DROP MATERIALIZED VIEW IF EXISTS agg_lab_equipment_values_1min CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_agg_lab_equipment_values_1min_full_hot CASCADE;
DROP TABLE IF EXISTS lab_equipment_values CASCADE;

-- 1. Mini hypertable mimicking real equipment_values
CREATE TABLE lab_equipment_values (
    ts_value      timestamptz NOT NULL,
    id_enterprise integer NOT NULL,
    id_equipment  integer NOT NULL,
    value         double precision
);
SELECT create_hypertable('lab_equipment_values', 'ts_value', chunk_time_interval => INTERVAL '1 hour');

-- 2. Insert 5000 rows spanning 3 hours across 10 equipments
INSERT INTO lab_equipment_values
SELECT
    now() - (interval '2 seconds' * n),
    1,
    1 + (n % 10),
    (random() * 100)
FROM generate_series(1, 5000) n;

\echo 'Ingested rows:'
SELECT COUNT(*) FROM lab_equipment_values;

\echo ''
\echo '========== PATHOLOGY: 3 parallel CAggs, same data, different names =========='

-- Legacy naming (uncompressed by default)
CREATE MATERIALIZED VIEW agg_lab_equipment_values_1min
WITH (timescaledb.continuous) AS
SELECT time_bucket(interval '1 minute', ts_value) AS ts_bucket,
       id_equipment,
       AVG(value)  AS avg_value,
       COUNT(*)    AS row_count
FROM lab_equipment_values
GROUP BY 1, 2
WITH NO DATA;

-- Newer naming (still not compressed)
CREATE MATERIALIZED VIEW ca_agg_lab_equipment_values_1min
WITH (timescaledb.continuous) AS
SELECT time_bucket(interval '1 minute', ts_value) AS ts_bucket,
       id_equipment,
       AVG(value)  AS avg_value,
       COUNT(*)    AS row_count
FROM lab_equipment_values
GROUP BY 1, 2
WITH NO DATA;

-- Retired design (mv_*_full_hot naming from a superseded caching layer)
CREATE MATERIALIZED VIEW mv_agg_lab_equipment_values_1min_full_hot
WITH (timescaledb.continuous) AS
SELECT time_bucket(interval '1 minute', ts_value) AS ts_bucket,
       id_equipment,
       AVG(value)  AS avg_value,
       COUNT(*)    AS row_count
FROM lab_equipment_values
GROUP BY 1, 2
WITH NO DATA;

-- Populate all three
CALL refresh_continuous_aggregate('agg_lab_equipment_values_1min', NULL, NULL);
CALL refresh_continuous_aggregate('ca_agg_lab_equipment_values_1min', NULL, NULL);
CALL refresh_continuous_aggregate('mv_agg_lab_equipment_values_1min_full_hot', NULL, NULL);

\echo ''
\echo '=== 3 CAggs, all same data, wasteful compute ==='
SELECT 'agg_*'::text AS scheme, COUNT(*) FROM agg_lab_equipment_values_1min
UNION ALL
SELECT 'ca_agg_*', COUNT(*) FROM ca_agg_lab_equipment_values_1min
UNION ALL
SELECT 'mv_agg_*_full_hot', COUNT(*) FROM mv_agg_lab_equipment_values_1min_full_hot;

\echo ''
\echo '========== PHASE 2 MIGRATION =========='

BEGIN;

-- Step 1: retire mv_*_full_hot (superseded design, 0 consumers on prod)
DROP MATERIALIZED VIEW mv_agg_lab_equipment_values_1min_full_hot CASCADE;

-- Step 2: rename ca_agg_* → ca_* (drop redundant "agg" middle)
ALTER MATERIALIZED VIEW ca_agg_lab_equipment_values_1min
  RENAME TO ca_lab_equipment_values_1min;
-- Backward-compat view for anything still referencing the old name
CREATE VIEW ca_agg_lab_equipment_values_1min AS
  SELECT * FROM ca_lab_equipment_values_1min;

-- Step 3: enable compression on ca_lab_equipment_values_1min
ALTER MATERIALIZED VIEW ca_lab_equipment_values_1min SET (timescaledb.compress = true);

-- Step 4: retire the legacy agg_* CAgg
-- (In real prod: first repoint any consumers to ca_*, then drop.)
-- For the lab, we leave a shim view so old names still resolve.
DROP MATERIALIZED VIEW agg_lab_equipment_values_1min CASCADE;
CREATE VIEW agg_lab_equipment_values_1min AS
  SELECT * FROM ca_lab_equipment_values_1min;

-- Step 5: proper refresh policy on the canonical ca_*
SELECT add_continuous_aggregate_policy('ca_lab_equipment_values_1min',
    start_offset      => INTERVAL '1 hour',
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '30 seconds',  -- aggressive vs invalidation backlog
    if_not_exists     => true);

COMMIT;

\echo ''
\echo '=== After consolidation: one canonical CAgg + backward-compat shims ==='
SELECT relname AS name,
       CASE relkind WHEN 'r' THEN 'TABLE' WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATVIEW' END AS kind
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public'
  AND relname ~ 'lab_equipment_values'
ORDER BY relname;

\echo ''
\echo '=== Backward-compat verification: old + new names return same rows ==='
SELECT (SELECT COUNT(*) FROM ca_lab_equipment_values_1min)      AS via_canonical,
       (SELECT COUNT(*) FROM ca_agg_lab_equipment_values_1min)  AS via_ca_agg_shim,
       (SELECT COUNT(*) FROM agg_lab_equipment_values_1min)     AS via_agg_shim;

\echo ''
\echo '=== Compression status on the canonical CAgg ==='
SELECT hypertable_name, compression_enabled
FROM timescaledb_information.hypertables
WHERE hypertable_name LIKE '%lab%' OR hypertable_name LIKE '_materialized_hypertable_%';

\echo ''
\echo '=== Refresh policy on canonical CAgg ==='
SELECT j.application_name, j.schedule_interval, j.proc_name
FROM timescaledb_information.jobs j
WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
  AND j.hypertable_name LIKE '%_materialized_hypertable_%'
ORDER BY j.job_id DESC
LIMIT 3;

\echo ''
\echo '========== DIAGNOSTIC: the "75 GB invalidation queue" recipe =========='
\echo 'On prod, agg_equipment_values_1min_t_invalidation is 75 GB. The queries below'
\echo 'are what youd run to diagnose + fix it (without any DML, informational only):'
\echo ''
\echo '  -- 1. How far behind is the refresh?'
\echo '  SELECT j.application_name, j.schedule_interval, s.total_runs, s.total_failures,'
\echo '         s.last_run_status, s.last_run_started_at'
\echo '  FROM timescaledb_information.jobs j'
\echo '  LEFT JOIN timescaledb_information.job_stats s ON j.job_id = s.job_id'
\echo '  WHERE j.hypertable_name = ''_materialized_hypertable_NNN''  -- from agg_equipment_values_1min_t;'
\echo ''
\echo '  -- 2. Is the invalidation log growing faster than refresh drains it?'
\echo '  SELECT COUNT(*) FROM _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log;'
\echo ''
\echo '  -- 3. Fix — either shorten schedule_interval OR add more workers:'
\echo '  SELECT alter_job(NNN, schedule_interval => INTERVAL ''1 minute'');'
