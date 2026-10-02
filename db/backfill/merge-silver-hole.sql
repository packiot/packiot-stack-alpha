-- merge-silver-hole.sql — step 2 of scripts/analytics-silver-hole-backfill.sh (2026-09-29, staging).
-- Additive: inserts the staged legacy rows into the empty silver window (existing rows win), then
-- refreshes every continuous aggregate over silver.equipment_values for the window (minute
-- level before the hierarchical hourly one). Rollback: DELETE FROM silver.equipment_values WHERE
-- id_enterprise = 3 AND ts_value >= '2026-08-27 17:58+00' AND ts_value < '2026-09-01 00:30+00'
-- AND ingested_at >= <applied_at printed below>.
\set ON_ERROR_STOP 1
SET statement_timeout = '30min';
BEGIN;
SELECT now() AS applied_at \gset
\echo applied_at: :applied_at
DO $$
DECLARE cols text; sel text; n bigint;
BEGIN
  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum),
         string_agg(CASE WHEN a.attname = 'ingested_at' THEN 'now()'
                         WHEN a.attname = 'source_seq'  THEN 'NULL'
                         -- legacy stores a smallint quality code here, analytics a date: no meaningful mapping
                         WHEN a.attname = 'ts_value_production_quality' THEN 'NULL'
                         ELSE format('s.%I::%s', a.attname, format_type(a.atttypid, a.atttypmod)) END, ', ' ORDER BY a.attnum)
    INTO cols, sel
    FROM pg_attribute a WHERE a.attrelid = 'silver.equipment_values'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
  EXECUTE format('INSERT INTO silver.equipment_values (%s) SELECT %s FROM ops.bf2_silver_values s ON CONFLICT DO NOTHING', cols, sel);
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'inserted % rows', n;
END $$;
COMMIT;
CALL refresh_continuous_aggregate('silver.ca_discrete_changes_1s',     '2026-08-27 17:00+00', '2026-09-01 01:00+00');
CALL refresh_continuous_aggregate('silver.ca_equipment_boxes_1s',      '2026-08-27 17:00+00', '2026-09-01 01:00+00');
CALL refresh_continuous_aggregate('silver.agg_equipment_values_1min',  '2026-08-27 17:00+00', '2026-09-01 01:00+00');
CALL refresh_continuous_aggregate('silver.equipment_metrics_1min',     '2026-08-27 17:00+00', '2026-09-01 01:00+00');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', '2026-08-27 17:00+00', '2026-09-01 01:00+00');
CALL refresh_continuous_aggregate('silver.agg_equipment_values_1hour', '2026-08-27 17:00+00', '2026-09-01 01:00+00');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1hour','2026-08-27 17:00+00', '2026-09-01 01:00+00');
SELECT 'silver_rows', count(*), round(sum(gross_production_incr)) FROM silver.equipment_values WHERE id_enterprise=3 AND ts_value >= '2026-08-27 17:58+00' AND ts_value < '2026-09-01 00:30+00';
SELECT 'cat1h_rows', count(*), round(sum(gross_production_incr)) FROM silver.equipment_categorical_1hour WHERE id_enterprise=3 AND ts_value >= '2026-08-27 17:00+00' AND ts_value < '2026-09-01 01:00+00';
