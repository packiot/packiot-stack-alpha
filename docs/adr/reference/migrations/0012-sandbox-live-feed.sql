-- ADR-0012 sandbox live feed — shadow insertions for packiot_refactor.
--
-- Pulls live data from packiot_shadow (same Postgres instance) into the
-- design sandbox so the refactored canonical schema is proven under
-- REAL inserts, not just generate_series fixtures:
--
--   packiot_shadow.public.*  ──postgres_fdw (loopback socket)──▶
--   packiot_refactor.public.*  ──TimescaleDB add_job (1 min)──▶
--   ca_equipment_values_1min (canonical CAgg, ADR-0012 naming)
--
-- Why pull-based fdw instead of a third sink on shadow-mirror /
-- oeecloud-worker: both services are hard-wired single-shadow-sink
-- (PG_SHADOW_DB_NAME / POSTGRES_SHADOW_DB_NAME) and packiot_shadow
-- already aggregates BOTH live feeds (data plane via oeecloud-worker,
-- control plane via shadow-mirror). One in-DB incremental pull gets
-- the sandbox everything with zero changes to running services.
-- ADR-0013's rejection of trigger+dblink applies to the production
-- mirror design, not to disposable lab tooling — recorded here so the
-- distinction survives.
--
-- Also fixes the Phase-1 / ADR-0012 naming drift: Phase 1 renamed
-- agg_equipment_values_1min_t → equipment_values_1min, but the ADR's
-- naming table says the canonical CAgg name is ca_equipment_values_1min.
-- The demo-era objects are replaced by a REAL CAgg + façades here.
--
-- Idempotent. Sandbox-only (packiot_refactor). Requires: superuser
-- (postgres), timescaledb ≥2.x, postgres_fdw contrib.

-- ============================================================
-- 1. Loopback FDW into packiot_shadow (unix socket, trust auth)
-- ============================================================
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'shadow_src_srv') THEN
    CREATE SERVER shadow_src_srv FOREIGN DATA WRAPPER postgres_fdw
      OPTIONS (host '/var/run/postgresql', dbname 'packiot_shadow');
    CREATE USER MAPPING FOR postgres SERVER shadow_src_srv OPTIONS (user 'postgres');
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS shadow_src;
DO $$ BEGIN
  IF to_regclass('shadow_src.equipment_values') IS NULL THEN
    IMPORT FOREIGN SCHEMA public
      LIMIT TO (equipment_values, equipment_events_man, production_orders,
                production_orders_runtime, uns_equipment_current_metrics)
      FROM SERVER shadow_src_srv INTO shadow_src;
  END IF;
END $$;

-- ============================================================
-- 2. Retire the Phase-1 demo CAgg-naming objects (drift fix)
-- ============================================================
DO $$ BEGIN
  -- Phase-1 compat view over the demo table
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname='agg_equipment_values_1min_t' AND relkind='v') THEN
    DROP VIEW public.agg_equipment_values_1min_t;
  END IF;
  -- Phase-1 demo rename target (3-col fake shape)
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname='equipment_values_1min' AND relkind='r') THEN
    DROP TABLE public.equipment_values_1min;
  END IF;
  -- Hasura-parity stub of the real 1-min aggregate (31-col, empty)
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname='agg_equipment_values_1min' AND relkind='r') THEN
    DROP TABLE public.agg_equipment_values_1min;
  END IF;
END $$;

-- ============================================================
-- 3. Live writer targets (shape cloned from packiot_shadow)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.equipment_values
  (LIKE shadow_src.equipment_values);
SELECT create_hypertable('public.equipment_values', 'ts_value',
                         chunk_time_interval => INTERVAL '1 day',
                         if_not_exists => TRUE);
-- Same idempotency key as prod/staging (UNIQUE(ts_value, id_equipment))
CREATE UNIQUE INDEX IF NOT EXISTS equipment_values_ts_equipment_key
  ON public.equipment_values (ts_value, id_equipment);

CREATE TABLE IF NOT EXISTS public.equipment_events_man
  (LIKE shadow_src.equipment_events_man);
-- Mirror-worker idempotency key (matches 0012-phase3-writer-tables.sql)
CREATE UNIQUE INDEX IF NOT EXISTS equipment_events_man_ts_event_key
  ON public.equipment_events_man (ts_event);

CREATE TABLE IF NOT EXISTS public.production_orders
  (LIKE shadow_src.production_orders);
CREATE TABLE IF NOT EXISTS public.production_orders_runtime
  (LIKE shadow_src.production_orders_runtime);
CREATE TABLE IF NOT EXISTS public.uns_equipment_current_metrics
  (LIKE shadow_src.uns_equipment_current_metrics);

-- ============================================================
-- 4. Canonical CAgg — ca_equipment_values_1min (ADR-0012 naming)
-- ============================================================
-- Aggregation semantics: sums for increments, avg for speed, last()
-- for state-like columns. Approximates the prod 1-min CAgg; exact
-- OEE-parity math is ADR-0014 territory, not this lab's concern.
CREATE MATERIALIZED VIEW IF NOT EXISTS ca_equipment_values_1min
WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '1 minute', ts_value) AS ts_value,
       id_enterprise, id_site, id_area, id_equipment, tp_equipment,
       SUM(net_production_incr)   AS net_production_incr,
       SUM(gross_production_incr) AS gross_production_incr,
       SUM(scrap_incr)            AS scrap_incr,
       last(state, ts_value)      AS state,
       last(mode,  ts_value)      AS mode,
       AVG(speed)                 AS speed,
       last(id_order, ts_value)          AS id_order,
       last(conversion_factor, ts_value) AS conversion_factor,
       last(number_cavities, ts_value)   AS number_cavities,
       MIN(signal_quality)               AS signal_quality,
       last(net_production_val, ts_value)   AS net_production_val,
       last(gross_production_val, ts_value) AS gross_production_val,
       last(scrap_val, ts_value)            AS scrap_val,
       last(id_shift, ts_value)      AS id_shift,
       last(id_team, ts_value)       AS id_team,
       last(id_shift_hour, ts_value) AS id_shift_hour,
       last(box_code, ts_value)         AS box_code,
       last(transaction_code, ts_value) AS transaction_code,
       last(id_production_order, ts_value) AS id_production_order,
       last(ts_value_production, ts_value) AS ts_value_production,
       last(id_equipment_line_connected, ts_value)  AS id_equipment_line_connected,
       last(position_in_equipment_line, ts_value)   AS position_in_equipment_line,
       last(is_equipment_line_infeed, ts_value)     AS is_equipment_line_infeed,
       last(is_equipment_line_outfeed, ts_value)    AS is_equipment_line_outfeed,
       last(ideal_production_speed, ts_value)       AS ideal_production_speed
FROM public.equipment_values
GROUP BY 1, 2, 3, 4, 5, 6
WITH NO DATA;

-- Façades: every historical name for this aggregate keeps resolving.
-- Casts restore the Hasura-parity stub's column types exactly.
CREATE OR REPLACE VIEW public.agg_equipment_values_1min AS
SELECT ts_value, id_enterprise, id_site, id_area, id_equipment,
       tp_equipment::smallint,
       net_production_incr::double precision,
       gross_production_incr::double precision,
       scrap_incr::double precision,
       state, mode, speed::double precision,
       id_order::text, conversion_factor,
       number_cavities, signal_quality::smallint,
       net_production_val::double precision,
       gross_production_val::double precision,
       scrap_val::double precision,
       id_shift, id_team, id_shift_hour,
       box_code::varchar, transaction_code::varchar,
       id_production_order::bigint, ts_value_production,
       id_equipment_line_connected,
       position_in_equipment_line::smallint,
       is_equipment_line_infeed::smallint,
       is_equipment_line_outfeed::smallint,
       ideal_production_speed
FROM ca_equipment_values_1min;

CREATE OR REPLACE VIEW public.agg_equipment_values_1min_t AS
SELECT * FROM ca_equipment_values_1min;

-- Phase-1 demo shim (3-col shape) — kept so the Phase-1 rename lesson
-- stays reproducible; net increment stands in for the demo 'val'.
CREATE OR REPLACE VIEW public.equipment_values_1min AS
SELECT ts_value, id_equipment,
       net_production_incr::double precision AS val
FROM ca_equipment_values_1min;

-- ============================================================
-- 5. Sync state + procedure
-- ============================================================
CREATE SCHEMA IF NOT EXISTS refactor_sync;

CREATE TABLE IF NOT EXISTS refactor_sync.state (
    table_name text PRIMARY KEY,
    last_ts    timestamptz NOT NULL DEFAULT '-infinity',
    last_run   timestamptz
);
INSERT INTO refactor_sync.state (table_name)
VALUES ('equipment_values'), ('equipment_events_man')
ON CONFLICT (table_name) DO NOTHING;

CREATE TABLE IF NOT EXISTS refactor_sync.log (
    ts          timestamptz NOT NULL DEFAULT now(),
    rows_values bigint,
    rows_events bigint,
    rows_po     bigint
);

CREATE OR REPLACE PROCEDURE refactor_sync.run(job_id int DEFAULT NULL,
                                              config jsonb DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_cur timestamptz;
    n_val bigint; n_evt bigint; n_po bigint;
BEGIN
    -- Incremental: equipment_values (2-min late-arrival rewind; the
    -- unique key makes re-pulls idempotent)
    SELECT last_ts INTO v_cur FROM refactor_sync.state
     WHERE table_name = 'equipment_values';
    INSERT INTO public.equipment_values
    SELECT * FROM shadow_src.equipment_values s
     WHERE s.ts_value > v_cur - INTERVAL '2 minutes'
    ON CONFLICT (ts_value, id_equipment) DO NOTHING;
    GET DIAGNOSTICS n_val = ROW_COUNT;
    UPDATE refactor_sync.state
       SET last_ts = GREATEST(last_ts,
             COALESCE((SELECT max(ts_value) FROM public.equipment_values), last_ts)),
           last_run = now()
     WHERE table_name = 'equipment_values';

    -- Incremental: equipment_events_man
    SELECT last_ts INTO v_cur FROM refactor_sync.state
     WHERE table_name = 'equipment_events_man';
    INSERT INTO public.equipment_events_man
    SELECT * FROM shadow_src.equipment_events_man s
     WHERE s.ts_event > v_cur - INTERVAL '2 minutes'
    ON CONFLICT (ts_event) DO NOTHING;
    GET DIAGNOSTICS n_evt = ROW_COUNT;
    UPDATE refactor_sync.state
       SET last_ts = GREATEST(last_ts,
             COALESCE((SELECT max(ts_event) FROM public.equipment_events_man), last_ts)),
           last_run = now()
     WHERE table_name = 'equipment_events_man';

    -- Small control-plane tables: full refresh (≤1k rows each)
    TRUNCATE public.production_orders,
             public.production_orders_runtime,
             public.uns_equipment_current_metrics;
    INSERT INTO public.production_orders
      SELECT * FROM shadow_src.production_orders;
    GET DIAGNOSTICS n_po = ROW_COUNT;
    INSERT INTO public.production_orders_runtime
      SELECT * FROM shadow_src.production_orders_runtime;
    INSERT INTO public.uns_equipment_current_metrics
      SELECT * FROM shadow_src.uns_equipment_current_metrics;

    INSERT INTO refactor_sync.log (rows_values, rows_events, rows_po)
    VALUES (n_val, n_evt, n_po);
    -- Keep the log bounded
    DELETE FROM refactor_sync.log WHERE ts < now() - INTERVAL '7 days';
END $$;

-- ============================================================
-- 6. Schedule (TimescaleDB user-defined action, runs in THIS db)
-- ============================================================
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs
                  WHERE proc_schema = 'refactor_sync' AND proc_name = 'run') THEN
    PERFORM add_job('refactor_sync.run', INTERVAL '1 minute');
  END IF;
END $$;

-- CAgg refresh policy on the canonical aggregate
SELECT add_continuous_aggregate_policy('ca_equipment_values_1min',
    start_offset      => NULL,          -- backfill-friendly: whole range
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute',
    if_not_exists     => TRUE);

-- ============================================================
-- 7. First sync + verification
-- ============================================================
CALL refactor_sync.run();
CALL refresh_continuous_aggregate('ca_equipment_values_1min', NULL, NULL);

\echo ''
\echo '=== live-feed verification ==='
SELECT 'equipment_values'        AS tbl, count(*) FROM public.equipment_values
UNION ALL SELECT 'equipment_events_man', count(*) FROM public.equipment_events_man
UNION ALL SELECT 'production_orders',    count(*) FROM public.production_orders
UNION ALL SELECT 'production_orders_runtime', count(*) FROM public.production_orders_runtime
UNION ALL SELECT 'uns_equipment_current_metrics', count(*) FROM public.uns_equipment_current_metrics
UNION ALL SELECT 'ca_equipment_values_1min', count(*) FROM ca_equipment_values_1min;

\echo '=== façades resolve ==='
SELECT (SELECT count(*) FROM public.agg_equipment_values_1min)   AS via_agg,
       (SELECT count(*) FROM public.agg_equipment_values_1min_t) AS via_agg_t,
       (SELECT count(*) FROM public.equipment_values_1min)       AS via_demo_shim;

\echo '=== sync job registered ==='
SELECT job_id, schedule_interval, proc_schema || '.' || proc_name AS proc
FROM timescaledb_information.jobs
WHERE proc_schema = 'refactor_sync' OR
      (proc_name = 'policy_refresh_continuous_aggregate');
