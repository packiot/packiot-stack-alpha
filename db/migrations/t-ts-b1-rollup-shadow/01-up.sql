-- t-ts-b1-rollup-shadow — ADR-0063 Phase B step 1: plain-PostgreSQL twins of the five
-- continuous aggregates, maintained by the engine, run in SHADOW next to the caggs (2026-10-15).
--
-- WHY
-- Every cagg the engine and its readers use is a plain GROUP BY over silver.equipment_values
-- (or, for equipment_categorical_1hour, over the minute cagg). Nothing in them needs
-- TimescaleDB except time_bucket() (→ date_bin) and last() (→ array_agg ORDER BY … [1]).
-- So instead of repointing ~15 readers one by one (the ADR's plan), each cagg gets a twin
-- `<name>__next`: a plain table with the IDENTICAL columns (CREATE TABLE AS … WITH NO DATA),
-- kept current by silver.rollup_tick(). Cutover (a later migration, after the 7-day zero-diff
-- exit criterion) is DROP the cagg + RENAME the twin, in one transaction: readers keep their
-- name and change nothing.
--
-- HOW IT STAYS CURRENT
--   * live window: every tick recomputes the trailing 20 minutes (+ the current minute) for
--     every equipment, and the hours those minutes belong to;
--   * late data: row triggers on silver.equipment_values mark the minute of any row OLDER than
--     15 minutes (late arrival, replay, repair UPDATE/DELETE) in silver.rollup_invalidation;
--     the tick drains it hour by hour. Fresh rows don't fire the trigger (WHEN clause), so the
--     hot ingest path pays nothing. This is the invalidation TimescaleDB did for us, minus the
--     refresh-window cliff: a cagg refresh policy only looks back start_offset (3 h for the
--     minute caggs), so later corrections never reached it (ADR-0063 A1: 40,109 stale ranges).
--   * who ticks: stream-engine (ROLLUP_SHADOW_ENABLED), not pg_cron — prod's DB image has no
--     pg_cron (runbook D2), and the engine will later refresh right before it reads.
--
-- SHADOW ONLY: nothing reads the twins yet. Reversible: rollback.sql drops everything here.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

-- 1. The twins: identical column names AND types (e.g. cnt_rows is bigint in the minute cagg,
--    numeric in the hour cagg) because they are built from the caggs themselves.
CREATE TABLE IF NOT EXISTS silver.equipment_categorical_1min__next  AS SELECT * FROM silver.equipment_categorical_1min  WITH NO DATA;
CREATE TABLE IF NOT EXISTS silver.equipment_categorical_1hour__next AS SELECT * FROM silver.equipment_categorical_1hour WITH NO DATA;
CREATE TABLE IF NOT EXISTS silver.equipment_metrics_1min__next      AS SELECT * FROM silver.equipment_metrics_1min      WITH NO DATA;
CREATE TABLE IF NOT EXISTS silver.agg_equipment_values_1min__next   AS SELECT * FROM silver.agg_equipment_values_1min   WITH NO DATA;
CREATE TABLE IF NOT EXISTS silver.agg_equipment_values_1hour__next  AS SELECT * FROM silver.agg_equipment_values_1hour  WITH NO DATA;

-- Indexes: what readers filter on (equipment/enterprise + time) and what the refresh deletes by.
CREATE INDEX IF NOT EXISTS equipment_categorical_1min__next_eq_ts  ON silver.equipment_categorical_1min__next  (id_equipment, ts_value DESC);
CREATE INDEX IF NOT EXISTS equipment_categorical_1min__next_ent_ts ON silver.equipment_categorical_1min__next  (id_enterprise, ts_value DESC);
CREATE INDEX IF NOT EXISTS equipment_categorical_1min__next_ts     ON silver.equipment_categorical_1min__next  (ts_value DESC);
CREATE INDEX IF NOT EXISTS equipment_categorical_1hour__next_eq_ts ON silver.equipment_categorical_1hour__next (id_equipment, ts_value DESC);
CREATE INDEX IF NOT EXISTS equipment_categorical_1hour__next_ent_ts ON silver.equipment_categorical_1hour__next (id_enterprise, ts_value DESC);
CREATE INDEX IF NOT EXISTS equipment_categorical_1hour__next_ts    ON silver.equipment_categorical_1hour__next (ts_value DESC);
CREATE INDEX IF NOT EXISTS equipment_metrics_1min__next_eq_b       ON silver.equipment_metrics_1min__next      (id_equipment, bucket DESC);
CREATE INDEX IF NOT EXISTS equipment_metrics_1min__next_ent_b      ON silver.equipment_metrics_1min__next      (id_enterprise, bucket DESC);
CREATE INDEX IF NOT EXISTS equipment_metrics_1min__next_b          ON silver.equipment_metrics_1min__next      (bucket DESC);
CREATE INDEX IF NOT EXISTS agg_equipment_values_1min__next_eq_ts   ON silver.agg_equipment_values_1min__next   (id_equipment, ts_value DESC);
CREATE INDEX IF NOT EXISTS agg_equipment_values_1min__next_ent_ts  ON silver.agg_equipment_values_1min__next   (id_enterprise, ts_value DESC);
CREATE INDEX IF NOT EXISTS agg_equipment_values_1min__next_ts      ON silver.agg_equipment_values_1min__next   (ts_value DESC);
CREATE INDEX IF NOT EXISTS agg_equipment_values_1hour__next_eq_ts  ON silver.agg_equipment_values_1hour__next  (id_equipment, ts_value DESC);
CREATE INDEX IF NOT EXISTS agg_equipment_values_1hour__next_ent_ts ON silver.agg_equipment_values_1hour__next  (id_enterprise, ts_value DESC);
CREATE INDEX IF NOT EXISTS agg_equipment_values_1hour__next_ts     ON silver.agg_equipment_values_1hour__next  (ts_value DESC);

-- 2. Late-data invalidation log: one row per (equipment, minute) that must be recomputed.
CREATE TABLE IF NOT EXISTS silver.rollup_invalidation (
  id_equipment integer     NOT NULL,
  ts_minute    timestamptz NOT NULL,
  marked_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id_equipment, ts_minute)
);

CREATE OR REPLACE FUNCTION silver.rollup_invalidate_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    INSERT INTO silver.rollup_invalidation (id_equipment, ts_minute)
    VALUES (OLD.id_equipment, date_bin('1 minute', OLD.ts_value, timestamptz '2000-01-01 00:00:00+00'))
    ON CONFLICT DO NOTHING;
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    INSERT INTO silver.rollup_invalidation (id_equipment, ts_minute)
    VALUES (NEW.id_equipment, date_bin('1 minute', NEW.ts_value, timestamptz '2000-01-01 00:00:00+00'))
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END $f$;

-- Only rows OLDER than the live window fire (the tick recomputes the last 20 minutes anyway).
DROP TRIGGER IF EXISTS rollup_invalidate_ins ON silver.equipment_values;
CREATE TRIGGER rollup_invalidate_ins AFTER INSERT ON silver.equipment_values
  FOR EACH ROW WHEN (NEW.ts_value < now() - interval '15 minutes')
  EXECUTE FUNCTION silver.rollup_invalidate_row();
DROP TRIGGER IF EXISTS rollup_invalidate_upd ON silver.equipment_values;
CREATE TRIGGER rollup_invalidate_upd AFTER UPDATE ON silver.equipment_values
  FOR EACH ROW WHEN (OLD.ts_value < now() - interval '15 minutes' OR NEW.ts_value < now() - interval '15 minutes')
  EXECUTE FUNCTION silver.rollup_invalidate_row();
DROP TRIGGER IF EXISTS rollup_invalidate_del ON silver.equipment_values;
CREATE TRIGGER rollup_invalidate_del AFTER DELETE ON silver.equipment_values
  FOR EACH ROW WHEN (OLD.ts_value < now() - interval '15 minutes')
  EXECUTE FUNCTION silver.rollup_invalidate_row();

-- 3. Recompute [p_from, p_to) for the minute twins and the hours that range touches.
--    p_equipment NULL = every equipment. Dynamic SQL so each call is planned with its real
--    bounds (chunk exclusion on the hypertable; no generic plan with an OR-NULL filter).
CREATE OR REPLACE FUNCTION silver.rollup_refresh(p_from timestamptz, p_to timestamptz, p_equipment integer[] DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
DECLARE
  o  constant timestamptz := timestamptz '2000-01-01 00:00:00+00';
  m0 timestamptz := date_bin('1 minute', p_from, o);
  m1 timestamptz := date_bin('1 minute', p_to - interval '1 microsecond', o) + interval '1 minute';
  h0 timestamptz := date_bin('1 hour', p_from, o);
  h1 timestamptz := date_bin('1 hour', p_to - interval '1 microsecond', o) + interval '1 hour';
  eq text := CASE WHEN p_equipment IS NULL THEN '' ELSE ' AND id_equipment = ANY ($3)' END;
  n  bigint := 0;
  k  bigint;
BEGIN
  IF p_to <= p_from THEN RETURN 0; END IF;

  -- equipment_categorical_1min (cagg: time_bucket 1 min, no tp filter)
  EXECUTE 'DELETE FROM silver.equipment_categorical_1min__next WHERE ts_value >= $1 AND ts_value < $2' || eq USING m0, m1, p_equipment;
  EXECUTE 'INSERT INTO silver.equipment_categorical_1min__next
    SELECT date_bin(''1 minute'', ev.ts_value, $4), ev.id_equipment, ev.id_enterprise, ev.id_site, ev.id_area, ev.tp_equipment,
           ev.state, ev.mode, ev.id_order, ev.conversion_factor, ev.number_cavities, ev.signal_quality, ev.id_shift, ev.id_team,
           ev.id_shift_hour, ev.id_production_order, ev.ts_value_production, ev.ideal_production_speed,
           sum(ev.net_production_incr::double precision), sum(ev.gross_production_incr::double precision),
           sum(ev.scrap_incr::double precision), sum(ev.speed::double precision), count(ev.speed), count(*),
           max(ev.net_production_val::double precision), max(ev.gross_production_val::double precision),
           max(ev.scrap_val::double precision)
      FROM silver.equipment_values ev
     WHERE ev.ts_value >= $1 AND ev.ts_value < $2' || replace(eq, 'id_equipment', 'ev.id_equipment') || '
     GROUP BY 1, ev.id_equipment, ev.id_enterprise, ev.id_site, ev.id_area, ev.tp_equipment, ev.state, ev.mode, ev.id_order,
              ev.conversion_factor, ev.number_cavities, ev.signal_quality, ev.id_shift, ev.id_team, ev.id_shift_hour,
              ev.id_production_order, ev.ts_value_production, ev.ideal_production_speed'
    USING m0, m1, p_equipment, o;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

  -- equipment_metrics_1min (cagg: tp_equipment IS NOT NULL; column `bucket`)
  EXECUTE 'DELETE FROM silver.equipment_metrics_1min__next WHERE bucket >= $1 AND bucket < $2' || eq USING m0, m1, p_equipment;
  EXECUTE 'INSERT INTO silver.equipment_metrics_1min__next
    SELECT date_bin(''1 minute'', ts_value, $4), id_equipment, id_enterprise, id_site, id_area, tp_equipment,
           sum(net_production_incr::double precision), sum(gross_production_incr::double precision),
           sum(scrap_incr::double precision), sum(speed::double precision), count(speed), count(*),
           max(speed::double precision), max(ideal_production_speed)
      FROM silver.equipment_values
     WHERE tp_equipment IS NOT NULL AND ts_value >= $1 AND ts_value < $2' || eq || '
     GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment'
    USING m0, m1, p_equipment, o;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

  -- agg_equipment_values_1min (cagg: tp_equipment IS NOT NULL; last() → array_agg ORDER BY ts DESC)
  EXECUTE 'DELETE FROM silver.agg_equipment_values_1min__next WHERE ts_value >= $1 AND ts_value < $2' || eq USING m0, m1, p_equipment;
  EXECUTE 'INSERT INTO silver.agg_equipment_values_1min__next
    SELECT date_bin(''1 minute'', ts_value, $4), id_enterprise, id_site, id_area, id_equipment, tp_equipment,
           sum(net_production_incr), sum(gross_production_incr), sum(scrap_incr), max(state), max(mode), avg(speed),
           max(id_order::text), max(conversion_factor), max(number_cavities), max(signal_quality),
           max(net_production_val), max(gross_production_val), max(scrap_val), max(id_shift), max(id_team), max(id_shift_hour),
           (array_agg(box_code ORDER BY ts_value DESC))[1], (array_agg(transaction_code ORDER BY ts_value DESC))[1],
           max(id_production_order), max(ts_value_production), max(id_equipment_line_connected),
           max(position_in_equipment_line), max(is_equipment_line_infeed), max(is_equipment_line_outfeed),
           max(ideal_production_speed)
      FROM silver.equipment_values
     WHERE tp_equipment IS NOT NULL AND ts_value >= $1 AND ts_value < $2' || eq || '
     GROUP BY 1, id_enterprise, id_site, id_area, id_equipment, tp_equipment'
    USING m0, m1, p_equipment, o;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

  -- equipment_categorical_1hour (cagg: over the minute cagg → over the minute twin)
  EXECUTE 'DELETE FROM silver.equipment_categorical_1hour__next WHERE ts_value >= $1 AND ts_value < $2' || eq USING h0, h1, p_equipment;
  EXECUTE 'INSERT INTO silver.equipment_categorical_1hour__next
    SELECT date_bin(''1 hour'', m.ts_value, $4), m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment,
           m.state, m.mode, m.id_order, m.conversion_factor, m.number_cavities, m.signal_quality, m.id_shift, m.id_team,
           m.id_shift_hour, m.id_production_order, m.ts_value_production, m.ideal_production_speed,
           sum(m.net_production_incr), sum(m.gross_production_incr), sum(m.scrap_incr), sum(m.sum_speed),
           sum(m.cnt_speed), sum(m.cnt_rows), max(m.net_production_val), max(m.gross_production_val), max(m.scrap_val)
      FROM silver.equipment_categorical_1min__next m
     WHERE m.ts_value >= $1 AND m.ts_value < $2' || replace(eq, 'id_equipment', 'm.id_equipment') || '
     GROUP BY 1, m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment, m.state, m.mode, m.id_order,
              m.conversion_factor, m.number_cavities, m.signal_quality, m.id_shift, m.id_team, m.id_shift_hour,
              m.id_production_order, m.ts_value_production, m.ideal_production_speed'
    USING h0, h1, p_equipment, o;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

  -- agg_equipment_values_1hour (cagg: over raw, tp_equipment IS NOT NULL, wide GROUP BY)
  EXECUTE 'DELETE FROM silver.agg_equipment_values_1hour__next WHERE ts_value >= $1 AND ts_value < $2' || eq USING h0, h1, p_equipment;
  EXECUTE 'INSERT INTO silver.agg_equipment_values_1hour__next
    SELECT date_bin(''1 hour'', ts_value, $4), id_enterprise, id_site, id_area, id_equipment, tp_equipment,
           sum(net_production_incr), sum(gross_production_incr), sum(scrap_incr), mode, avg(speed),
           id_production_order, conversion_factor, number_cavities, signal_quality,
           max(net_production_val), max(gross_production_val), max(scrap_val), id_shift, id_team, id_shift_hour,
           box_code, transaction_code, ts_value_production, id_equipment_line_connected, position_in_equipment_line,
           is_equipment_line_infeed, is_equipment_line_outfeed
      FROM silver.equipment_values
     WHERE tp_equipment IS NOT NULL AND ts_value >= $1 AND ts_value < $2' || eq || '
     GROUP BY 1, id_enterprise, id_site, id_area, id_equipment, tp_equipment, mode, id_production_order, conversion_factor,
              number_cavities, signal_quality, id_shift, id_team, id_shift_hour, box_code, transaction_code,
              ts_value_production, id_equipment_line_connected, position_in_equipment_line, is_equipment_line_infeed,
              is_equipment_line_outfeed'
    USING h0, h1, p_equipment, o;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

  RETURN n;
END $f$;

-- 4. The tick: live window + a bounded drain of the invalidation log. One runner at a time
--    (a second caller returns immediately). Called every minute by stream-engine.
CREATE OR REPLACE FUNCTION silver.rollup_tick(p_window interval DEFAULT interval '20 minutes', p_drain_limit integer DEFAULT 5000)
RETURNS TABLE (live_rows bigint, drained_minutes integer, drained_hours integer, remaining integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
DECLARE
  o  constant timestamptz := timestamptz '2000-01-01 00:00:00+00';
  t1 timestamptz := date_bin('1 minute', now(), o) + interval '1 minute';   -- includes the current minute
  r  record;
BEGIN
  live_rows := 0; drained_minutes := 0; drained_hours := 0; remaining := 0;
  IF NOT pg_try_advisory_xact_lock(hashtext('silver.rollup_tick')) THEN
    RETURN NEXT; RETURN;
  END IF;
  live_rows := silver.rollup_refresh(t1 - p_window - interval '1 minute', t1, NULL);

  -- Drain: recompute whole hours per equipment (simple and exact; an hour of one equipment is small).
  CREATE TEMP TABLE IF NOT EXISTS rollup_drained (id_equipment integer, ts_minute timestamptz) ON COMMIT DROP;
  TRUNCATE rollup_drained;
  WITH d AS (
    DELETE FROM silver.rollup_invalidation i
     WHERE (i.id_equipment, i.ts_minute) IN (
       SELECT id_equipment, ts_minute FROM silver.rollup_invalidation ORDER BY ts_minute LIMIT p_drain_limit
       FOR UPDATE SKIP LOCKED)
    RETURNING i.id_equipment, i.ts_minute)
  INSERT INTO rollup_drained SELECT id_equipment, ts_minute FROM d;
  GET DIAGNOSTICS drained_minutes = ROW_COUNT;

  FOR r IN
    SELECT date_bin('1 hour', ts_minute, o) AS h, array_agg(DISTINCT id_equipment) AS eqs
      FROM rollup_drained GROUP BY 1 ORDER BY 1
  LOOP
    PERFORM silver.rollup_refresh(r.h, r.h + interval '1 hour', r.eqs);
    drained_hours := drained_hours + 1;
  END LOOP;

  SELECT count(*) INTO remaining FROM silver.rollup_invalidation;
  RETURN NEXT;
END $f$;

-- 5. Backfill one day at a time with a COMMIT between days (a procedure, so a long backfill
--    never holds one huge transaction). Hours older than the raw retention cannot be
--    recomputed — they are copied from the hour caggs by silver.rollup_seed_old_hours().
-- No SET clause: PostgreSQL forbids COMMIT inside a procedure that has one ("invalid
-- transaction termination"); every name below is schema-qualified instead.
CREATE OR REPLACE PROCEDURE silver.rollup_backfill(p_from timestamptz, p_to timestamptz)
LANGUAGE plpgsql AS $p$
DECLARE d timestamptz := pg_catalog.date_bin('1 day', p_from, timestamptz '2000-01-01 00:00:00+00');
BEGIN
  WHILE d < p_to LOOP
    PERFORM silver.rollup_refresh(d, LEAST(d + interval '1 day', p_to), NULL);
    COMMIT;
    d := d + interval '1 day';
  END LOOP;
END $p$;

CREATE OR REPLACE FUNCTION silver.rollup_seed_old_hours() RETURNS bigint
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $f$
DECLARE raw_min timestamptz; n bigint := 0; k bigint;
BEGIN
  SELECT date_bin('1 hour', min(ts_value), timestamptz '2000-01-01 00:00:00+00') INTO raw_min FROM silver.equipment_values;
  IF raw_min IS NULL THEN RETURN 0; END IF;
  DELETE FROM silver.equipment_categorical_1hour__next WHERE ts_value < raw_min;
  INSERT INTO silver.equipment_categorical_1hour__next SELECT * FROM silver.equipment_categorical_1hour WHERE ts_value < raw_min;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  DELETE FROM silver.agg_equipment_values_1hour__next WHERE ts_value < raw_min;
  INSERT INTO silver.agg_equipment_values_1hour__next SELECT * FROM silver.agg_equipment_values_1hour WHERE ts_value < raw_min;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  RETURN n;
END $f$;

-- 6. Shadow diff: per target, (equipment, bucket) fingerprints of the twin vs the cagg vs the
--    TRUTH (the same GROUP BY over raw, computed now). Floats are rounded to 4 decimals so a
--    different summation order is not a mismatch. twin≠truth = a missed invalidation (a bug
--    here); cagg≠truth = the cagg is stale (expected for late data; the reason for Phase B).
CREATE OR REPLACE FUNCTION silver.rollup_shadow_diff(p_from timestamptz, p_to timestamptz)
RETURNS TABLE (target text, buckets_twin bigint, buckets_cagg bigint, twin_vs_truth bigint, cagg_vs_truth bigint)
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $f$
DECLARE o constant timestamptz := timestamptz '2000-01-01 00:00:00+00';
BEGIN
  -- Whole minutes only: the twins/caggs are filtered by BUCKET start, the truth by RAW time,
  -- so an unaligned edge would put a partial minute in the truth alone (a false mismatch,
  -- found by the first test run).
  p_from := date_bin('1 minute', p_from, o);
  p_to   := date_bin('1 minute', p_to - interval '1 microsecond', o) + interval '1 minute';
  -- truth for the minute targets is what rollup_refresh would write now; compute it into temp tables
  CREATE TEMP TABLE IF NOT EXISTS rsd_fp (src text, target text, id_equipment integer, bucket timestamptz, fp text) ON COMMIT DROP;
  TRUNCATE rsd_fp;

  -- categorical_1min: fingerprint = groups + rounded sums
  INSERT INTO rsd_fp
  SELECT s.src, 'equipment_categorical_1min', s.id_equipment, s.ts_value,
         count(*)::text || ':' || round(sum(coalesce(s.net_production_incr,0))::numeric, 4) || ':' || sum(s.cnt_rows) || ':' ||
         md5(string_agg(concat_ws('|', s.state, s.mode, s.id_order, s.id_production_order, s.id_shift, s.id_shift_hour), ',' ORDER BY
             concat_ws('|', s.state, s.mode, s.id_order, s.id_production_order, s.id_shift, s.id_shift_hour)))
    FROM (SELECT 'twin' src, * FROM silver.equipment_categorical_1min__next WHERE ts_value >= p_from AND ts_value < p_to
          UNION ALL
          SELECT 'cagg', * FROM silver.equipment_categorical_1min WHERE ts_value >= p_from AND ts_value < p_to
          UNION ALL
          SELECT 'truth', date_bin('1 minute', ev.ts_value, o), ev.id_equipment, ev.id_enterprise, ev.id_site, ev.id_area, ev.tp_equipment,
                 ev.state, ev.mode, ev.id_order, ev.conversion_factor, ev.number_cavities, ev.signal_quality, ev.id_shift, ev.id_team,
                 ev.id_shift_hour, ev.id_production_order, ev.ts_value_production, ev.ideal_production_speed,
                 sum(ev.net_production_incr::double precision), sum(ev.gross_production_incr::double precision),
                 sum(ev.scrap_incr::double precision), sum(ev.speed::double precision), count(ev.speed), count(*),
                 max(ev.net_production_val::double precision), max(ev.gross_production_val::double precision), max(ev.scrap_val::double precision)
            FROM silver.equipment_values ev WHERE ev.ts_value >= p_from AND ev.ts_value < p_to
           GROUP BY 2, ev.id_equipment, ev.id_enterprise, ev.id_site, ev.id_area, ev.tp_equipment, ev.state, ev.mode, ev.id_order,
                    ev.conversion_factor, ev.number_cavities, ev.signal_quality, ev.id_shift, ev.id_team, ev.id_shift_hour,
                    ev.id_production_order, ev.ts_value_production, ev.ideal_production_speed) s
   GROUP BY s.src, s.id_equipment, s.ts_value;

  -- metrics_1min
  INSERT INTO rsd_fp
  SELECT s.src, 'equipment_metrics_1min', s.id_equipment, s.bucket,
         round(coalesce(s.sum_net,0)::numeric, 4) || ':' || s.cnt_rows || ':' || coalesce(round(s.max_speed::numeric, 4)::text, '-')
    FROM (SELECT 'twin' src, * FROM silver.equipment_metrics_1min__next WHERE bucket >= p_from AND bucket < p_to
          UNION ALL SELECT 'cagg', * FROM silver.equipment_metrics_1min WHERE bucket >= p_from AND bucket < p_to
          UNION ALL
          SELECT 'truth', date_bin('1 minute', ts_value, o), id_equipment, id_enterprise, id_site, id_area, tp_equipment,
                 sum(net_production_incr::double precision), sum(gross_production_incr::double precision), sum(scrap_incr::double precision),
                 sum(speed::double precision), count(speed), count(*), max(speed::double precision), max(ideal_production_speed)
            FROM silver.equipment_values WHERE tp_equipment IS NOT NULL AND ts_value >= p_from AND ts_value < p_to
           GROUP BY 2, id_equipment, id_enterprise, id_site, id_area, tp_equipment) s;

  -- agg_equipment_values_1min
  INSERT INTO rsd_fp
  SELECT s.src, 'agg_equipment_values_1min', s.id_equipment, s.ts_value,
         round(coalesce(s.net_production_incr,0)::numeric, 4) || ':' || coalesce(s.id_production_order::text,'-') || ':' ||
         coalesce(s.state::text,'-') || ':' || coalesce(s.box_code,'-')
    FROM (SELECT 'twin' src, * FROM silver.agg_equipment_values_1min__next WHERE ts_value >= p_from AND ts_value < p_to
          UNION ALL SELECT 'cagg', * FROM silver.agg_equipment_values_1min WHERE ts_value >= p_from AND ts_value < p_to
          UNION ALL
          SELECT 'truth', date_bin('1 minute', ts_value, o), id_enterprise, id_site, id_area, id_equipment, tp_equipment,
                 sum(net_production_incr), sum(gross_production_incr), sum(scrap_incr), max(state), max(mode), avg(speed),
                 max(id_order::text), max(conversion_factor), max(number_cavities), max(signal_quality),
                 max(net_production_val), max(gross_production_val), max(scrap_val), max(id_shift), max(id_team), max(id_shift_hour),
                 (array_agg(box_code ORDER BY ts_value DESC))[1], (array_agg(transaction_code ORDER BY ts_value DESC))[1],
                 max(id_production_order), max(ts_value_production), max(id_equipment_line_connected),
                 max(position_in_equipment_line), max(is_equipment_line_infeed), max(is_equipment_line_outfeed), max(ideal_production_speed)
            FROM silver.equipment_values WHERE tp_equipment IS NOT NULL AND ts_value >= p_from AND ts_value < p_to
           GROUP BY 2, id_enterprise, id_site, id_area, id_equipment, tp_equipment) s;

  RETURN QUERY
  WITH t AS (SELECT f.target, f.id_equipment, f.bucket,
                    max(f.fp) FILTER (WHERE f.src = 'twin')  AS twin,
                    max(f.fp) FILTER (WHERE f.src = 'cagg')  AS cagg,
                    max(f.fp) FILTER (WHERE f.src = 'truth') AS truth
               FROM rsd_fp f GROUP BY 1, 2, 3)
  SELECT t.target,
         count(*) FILTER (WHERE t.twin IS NOT NULL),
         count(*) FILTER (WHERE t.cagg IS NOT NULL),
         count(*) FILTER (WHERE t.twin IS DISTINCT FROM t.truth),
         count(*) FILTER (WHERE t.cagg IS DISTINCT FROM t.truth)
    FROM t GROUP BY t.target ORDER BY t.target;
END $f$;

-- 7. Grants: the twins get the caggs' readers NOW, so the cutover is only a RENAME.
DO $g$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT g.table_name AS cagg, g.grantee, string_agg(g.privilege_type, ', ') AS privs
      FROM information_schema.role_table_grants g
     WHERE g.table_schema = 'silver'
       AND g.table_name IN ('equipment_categorical_1min','equipment_categorical_1hour','equipment_metrics_1min',
                            'agg_equipment_values_1min','agg_equipment_values_1hour')
       AND g.grantee NOT IN ('postgres', 'PUBLIC')
       AND g.privilege_type IN ('SELECT')
     GROUP BY 1, 2
  LOOP
    EXECUTE format('GRANT %s ON silver.%I TO %I', r.privs, r.cagg || '__next', r.grantee);
  END LOOP;
END $g$;

REVOKE ALL ON FUNCTION silver.rollup_refresh(timestamptz, timestamptz, integer[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION silver.rollup_tick(interval, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION silver.rollup_invalidate_row() FROM PUBLIC;
REVOKE ALL ON PROCEDURE silver.rollup_backfill(timestamptz, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION silver.rollup_seed_old_hours() FROM PUBLIC;
REVOKE ALL ON FUNCTION silver.rollup_shadow_diff(timestamptz, timestamptz) FROM PUBLIC;
DO $s$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stream_engine') THEN
    GRANT USAGE ON SCHEMA silver TO stream_engine;
    GRANT EXECUTE ON FUNCTION silver.rollup_tick(interval, integer) TO stream_engine;
  END IF;
END $s$;

COMMENT ON TABLE silver.rollup_invalidation IS
  'ADR-0063 Phase B (t-ts-b1-rollup-shadow): (equipment, minute) pairs whose rollup twins must be recomputed because a row OLDER than the live window was inserted/updated/deleted. Drained by silver.rollup_tick().';
COMMIT;
