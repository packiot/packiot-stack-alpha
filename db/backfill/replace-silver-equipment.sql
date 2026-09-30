-- replace-silver-equipment.sql — per-equipment silver REPLACE from staged legacy rows (2026-09-29, staging).
-- Used for the CPACK L8-PTH (74) / L10-PTH (78) recovery: the factory tee sends those two counters
-- SATURATED at 32767 (legacy reads the same PLC correctly), so silver only holds the 0..32767 half
-- of every 65536 cycle. An additive ON CONFLICT merge would double-count that half (different
-- ts_value grid than legacy), so the window is backed up, deleted and re-inserted from the stage.
--   psql -v eqs=74,78 -v from_ts="'2026-09-01 00:30+00'" -v to_ts="'2026-09-29 23:00+00'" \
--        -v stage=bf_pth_silver_values -v bkp=_bkp_pth_silver_20260929 -f replace-silver-equipment.sql
-- Rollback: DELETE the window for :eqs, INSERT ... SELECT * FROM ops.:bkp, refresh the same caggs.
\set ON_ERROR_STOP 1
SET statement_timeout = '30min';
SET lock_timeout = '20s';
BEGIN;
SELECT 'before', id_equipment, count(*), round(sum(gross_production_incr)) gross, round(sum(net_production_incr)) net
  FROM silver.equipment_values WHERE id_equipment IN (:eqs) AND ts_value >= :from_ts AND ts_value < :to_ts GROUP BY 2 ORDER BY 2;
SELECT 'staged', id_equipment, count(*), round(sum(gross_production_incr)) gross, round(sum(net_production_incr)) net
  FROM ops.:stage GROUP BY 2 ORDER BY 2;
CREATE TABLE ops.:bkp AS
  SELECT * FROM silver.equipment_values WHERE id_equipment IN (:eqs) AND ts_value >= :from_ts AND ts_value < :to_ts;
DELETE FROM silver.equipment_values WHERE id_equipment IN (:eqs) AND ts_value >= :from_ts AND ts_value < :to_ts;
SELECT set_config('bf.stage', 'ops.' || :'stage', true);
DO $$
DECLARE cols text; sel text; n bigint;
BEGIN
  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum),
         string_agg(CASE WHEN a.attname = 'ingested_at' THEN 'now()'
                         WHEN a.attname = 'source_seq'  THEN 'NULL'
                         WHEN a.attname = 'ts_value_production_quality' THEN 'NULL'
                         ELSE format('s.%I::%s', a.attname, format_type(a.atttypid, a.atttypmod)) END, ', ' ORDER BY a.attnum)
    INTO cols, sel
    FROM pg_attribute a WHERE a.attrelid = 'silver.equipment_values'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
  EXECUTE format('INSERT INTO silver.equipment_values (%s) SELECT %s FROM %s s', cols, sel, current_setting('bf.stage'));
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'inserted % rows', n;
END $$;
SELECT 'after', id_equipment, count(*), round(sum(gross_production_incr)) gross, round(sum(net_production_incr)) net
  FROM silver.equipment_values WHERE id_equipment IN (:eqs) AND ts_value >= :from_ts AND ts_value < :to_ts GROUP BY 2 ORDER BY 2;
COMMIT;
SELECT date_trunc('hour', :from_ts::timestamptz) AS rf, date_trunc('hour', :to_ts::timestamptz) + interval '1 hour' AS rt \gset
CALL refresh_continuous_aggregate('silver.ca_discrete_changes_1s',     :'rf', :'rt');
CALL refresh_continuous_aggregate('silver.ca_equipment_boxes_1s',      :'rf', :'rt');
CALL refresh_continuous_aggregate('silver.agg_equipment_values_1min',  :'rf', :'rt');
CALL refresh_continuous_aggregate('silver.equipment_metrics_1min',     :'rf', :'rt');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', :'rf', :'rt');
CALL refresh_continuous_aggregate('silver.agg_equipment_values_1hour', :'rf', :'rt');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1hour',:'rf', :'rt');
SELECT 'cat1h', id_equipment, round(sum(gross_production_incr)) FROM silver.equipment_categorical_1hour
 WHERE id_equipment IN (:eqs) AND ts_value >= :'rf' AND ts_value < :'rt' GROUP BY 2 ORDER BY 2;
