-- t-ts-b2-rollup-cutover — ADR-0063 Phase B2: the plain-table twins replace the five continuous aggregates.
--
-- One transaction: DROP the five caggs (hour-on-minute first), RENAME each twin `<cagg>__next` to the
-- cagg's name, and its indexes to match. Readers keep their names and grants (granted to the twins by
-- t-ts-b1-rollup-shadow); silver.rollup_refresh() resolves the names at runtime, so the stream-engine
-- tick carries on against the final tables with no code or function change. Rehearsed on TimescaleDB
-- 2.27.0-pg15 with staging's real definitions (2026-10-15): readers, grants, late and fresh rows OK.
--
-- GATE (enforced below, not a convention): 7 days of hourly R1_rollup_twin_vs_truth invariants
-- recorded by the shadow tick (t-ts-b1-shadow-invariant), >= 160 hours, none failing. Override only on
-- purpose: SET adr0063.b2_gate_override = 'on' in the same session, with the reason in the PR.
--
-- APPLY like t-ts-b4-drop-discrete-1s: DROP MATERIALIZED VIEW contends with the raw hypertable's insert
-- invalidation lock, so quiesce ingest (stop stream-engine; RabbitMQ buffers), apply with a lock retry,
-- start it again, then check COMPUTE freshness (gold computed_at), not only ingest.
-- After it: the shadow-only helpers are dropped (diff/seed need both twin and cagg); R1/R2 recording
-- stops being possible, so silver.rollup_shadow_record becomes a no-op returning 0.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $gate$
DECLARE hours int; failing int;
BEGIN
  IF to_regclass('silver.equipment_categorical_1min__next') IS NULL THEN
    RAISE NOTICE 'twins already renamed: nothing to do';
    RETURN;
  END IF;
  -- distinct hour WINDOWS, not run_at: a stream-engine restart re-records an hour (t-ts-b1-shadow-record-idempotent)
  SELECT count(DISTINCT substring(detail from '\d{4}-\d{2}-\d{2} \d{2}:\d{2}')), count(*) FILTER (WHERE NOT ok) INTO hours, failing
    FROM ops.data_invariant_result
   WHERE source = 'rollup-shadow' AND check_id = 'R1_rollup_twin_vs_truth' AND run_at > now() - interval '7 days';
  IF (hours < 160 OR failing > 0) AND coalesce(current_setting('adr0063.b2_gate_override', true), '') <> 'on' THEN
    RAISE EXCEPTION 'ADR-0063 B2 gate not met: % hourly R1 records in 7 days (want >= 160), % failing (want 0)', hours, failing
      USING HINT = 'wait for the shadow, or SET adr0063.b2_gate_override = ''on'' with a written reason';
  END IF;
  RAISE NOTICE 'B2 gate: % hours recorded, % failing', hours, failing;
END $gate$;

DO $cut$
DECLARE
  t text;
  i record;
BEGIN
  IF to_regclass('silver.equipment_categorical_1min__next') IS NULL THEN RETURN; END IF;
  -- the hour cagg sits on the minute cagg: drop it first
  FOREACH t IN ARRAY ARRAY['equipment_categorical_1hour', 'equipment_categorical_1min', 'equipment_metrics_1min',
                           'agg_equipment_values_1min', 'agg_equipment_values_1hour'] LOOP
    EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS silver.%I', t);
    EXECUTE format('ALTER TABLE silver.%I RENAME TO %I', t || '__next', t);
    FOR i IN SELECT c.relname FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
              WHERE x.indrelid = format('silver.%I', t)::regclass AND c.relname LIKE '%\_\_next\_%' LOOP
      EXECUTE format('ALTER INDEX silver.%I RENAME TO %I', i.relname, replace(i.relname, '__next_', '_'));
    END LOOP;
    -- the caggs' retention lived in TimescaleDB policies (gone with them); ops.retention_policy keeps the
    -- row under the same name, now kind 'plain': ops.apply_retention() DELETEs by time_expr < now() - keep
    UPDATE ops.retention_policy SET kind = 'plain', updated_at = now() WHERE relation = 'silver.' || t AND kind = 'cagg';
  END LOOP;
END $cut$;

-- shadow-only helpers: they compare twin with cagg, and the caggs are gone
DROP FUNCTION IF EXISTS silver.rollup_shadow_diff(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS silver.rollup_seed_old_hours();
CREATE OR REPLACE FUNCTION silver.rollup_shadow_record(p_from timestamptz, p_to timestamptz)
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
  SELECT 0   -- ADR-0063 B2 done: no cagg left to compare with (the tick still calls this hourly)
$f$;

COMMENT ON TABLE silver.equipment_categorical_1min IS
  'Per-minute categorical rollup of silver.equipment_values (ADR-0063 B2: plain table maintained by silver.rollup_tick(), was a TimescaleDB cagg).';
COMMENT ON TABLE silver.equipment_categorical_1hour IS
  'Per-hour categorical rollup over silver.equipment_categorical_1min (ADR-0063 B2: plain table maintained by silver.rollup_tick(), was a TimescaleDB cagg).';
COMMENT ON TABLE silver.equipment_metrics_1min IS
  'Per-minute metrics rollup of silver.equipment_values (ADR-0063 B2: plain table maintained by silver.rollup_tick(), was a TimescaleDB cagg).';
COMMENT ON TABLE silver.agg_equipment_values_1min IS
  'Per-minute value rollup of silver.equipment_values (ADR-0063 B2: plain table maintained by silver.rollup_tick(), was a TimescaleDB cagg).';
COMMENT ON TABLE silver.agg_equipment_values_1hour IS
  'Per-hour value rollup of silver.equipment_values (ADR-0063 B2: plain table maintained by silver.rollup_tick(), was a TimescaleDB cagg).';
COMMIT;
