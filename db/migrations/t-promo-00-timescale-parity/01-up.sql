-- t-promo-00-timescale-parity — PROMOTION PRELUDE (prod only; a no-op where already in place).
--
-- Staging received some TimescaleDB state BY HAND before the analytics-* migrations were codified, so those
-- files assume it: analytics-hardening/01 says "Compression config … already SET on" these caggs, and
-- analytics-cagg-refresh-policies only attached policies to caggs that lacked one ON STAGING. Prod never had
-- the hand steps → the replay stopped at analytics-hardening/01 with
--   ERROR: setup a refresh policy for "ca_discrete_changes_1s" before setting up a columnstore policy
-- (found by the 2026-10-08 promotion rehearsal on a clone of prod).
--
-- This fills exactly that gap, idempotently:
--   1. refresh policies for the caggs that had none (staging's live config, copied 2026-10-08);
--   2. compression settings (segmentby = the entity, orderby ts_value DESC) on every cagg analytics-hardening/01
--      compresses, where not already enabled.
\set ON_ERROR_STOP 1

DO $p$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('ca_discrete_changes_1s', interval '30 minutes', interval '1 minute', interval '15 minutes'),
      ('ca_equipment_boxes_1s',  interval '6 hours',    interval '1 minute', interval '15 minutes')
    ) v(cagg, start_off, end_off, sched) LOOP
    IF to_regclass(r.cagg) IS NULL THEN CONTINUE; END IF;
    IF NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs j
                    WHERE j.proc_name = 'policy_refresh_continuous_aggregate' AND j.hypertable_name = r.cagg) THEN
      PERFORM add_continuous_aggregate_policy(r.cagg::regclass, start_offset => r.start_off, end_offset => r.end_off,
                                              schedule_interval => r.sched, if_not_exists => true);
      RAISE NOTICE 'refresh policy added: %', r.cagg;
    END IF;
  END LOOP;
END
$p$;

DO $c$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('ca_discrete_changes_1s', 'id_equipment'), ('ca_agg_equipment_values_1min', 'id_equipment'),
      ('ca_agg_equipment_values_1hour', 'id_equipment'), ('agg_equipment_values_1min', 'id_equipment'),
      ('agg_equipment_values_10min', 'id_equipment'), ('agg_equipment_values_1hour', 'id_equipment'),
      ('agg_area_values_1min', 'id_area'), ('agg_area_values_10min', 'id_area'), ('agg_area_values_1hour', 'id_area'),
      ('agg_site_values_1min', 'id_site'), ('agg_site_values_10min', 'id_site'), ('agg_site_values_1hour', 'id_site')
    ) v(cagg, segby) LOOP
    IF to_regclass(r.cagg) IS NULL THEN CONTINUE; END IF;
    IF (SELECT compression_enabled FROM timescaledb_information.continuous_aggregates WHERE view_name = r.cagg LIMIT 1) THEN
      CONTINUE;
    END IF;
    EXECUTE format('ALTER MATERIALIZED VIEW %s SET (timescaledb.compress = true, timescaledb.compress_segmentby = %L, timescaledb.compress_orderby = %L)',
                   r.cagg::regclass, r.segby, 'ts_value DESC');
    RAISE NOTICE 'compression enabled: % (segmentby %)', r.cagg, r.segby;
  END LOOP;
END
$c$;
