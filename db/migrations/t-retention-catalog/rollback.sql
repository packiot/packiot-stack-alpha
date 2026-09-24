-- Rollback t-retention-catalog: restore the EXACT pre-migration live state captured
-- 2026-09-23 (timescaledb_information.jobs + purge_analytics_plain body).
-- WARNING: re-enables the 90 d DELETE of gold.equipment_oee_shift/_hourly.

CREATE OR REPLACE PROCEDURE public.purge_analytics_plain(IN job_id integer, IN config jsonb)
LANGUAGE plpgsql AS $procedure$
  BEGIN
    DELETE FROM gold.equipment_oee_hourly           WHERE ts_value < now() - interval '90 days';
    DELETE FROM gold.equipment_oee_shift            WHERE ts_value < now() - interval '90 days';
    DELETE FROM silver.equipment_events_cpac_shadow WHERE ts_event < now() - interval '90 days';
  END;
$procedure$;

-- policies that existed before (re-set to their old drop_after)
SELECT remove_retention_policy(r::regclass, if_exists => true)
  FROM unnest(ARRAY['bronze.equipment_values_raw','bronze.equipment_events_raw','silver.equipment_events',
                    'silver.ca_equipment_boxes_1s','silver.equipment_metrics_1min','silver.equipment_categorical_1min',
                    'silver.agg_equipment_values_1hour','silver.equipment_categorical_1hour']) r;
SELECT add_retention_policy('bronze.equipment_values_raw', drop_after => interval '2 years');
SELECT add_retention_policy('bronze.equipment_events_raw', drop_after => interval '2 years');
SELECT add_retention_policy('silver.equipment_events',     drop_after => interval '2 years');
-- (silver.equipment_values, agg_1min, ca_discrete_changes_1s were 90 d before and after — untouched)

DROP PROCEDURE IF EXISTS ops.apply_retention();
DROP VIEW  IF EXISTS ops.retention_drift;
DROP TABLE IF EXISTS ops.retention_run;
DROP TABLE IF EXISTS ops.retention_policy;
