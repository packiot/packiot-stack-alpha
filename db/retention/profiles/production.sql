-- Retention profile: PRODUCTION (long history for client-facing grains).
-- This is also what migration t-retention-catalog seeds. Re-apply to reset a DB to it:
--   psql -d packiot_analytics -f db/retention/profiles/production.sql
-- Then verify: SELECT * FROM ops.retention_drift;  -- want 0 rows
BEGIN;
UPDATE ops.retention_policy SET keep = v.keep::interval, updated_at = now()
FROM (VALUES
  ('silver.equipment_values','90 days'), ('bronze.equipment_values_raw','90 days'), ('bronze.equipment_events_raw','90 days'),
  ('silver.ca_discrete_changes_1s','90 days'), ('silver.ca_equipment_boxes_1s','90 days'),
  ('silver.agg_equipment_values_1min','90 days'), ('silver.equipment_metrics_1min','90 days'),
  ('silver.equipment_categorical_1min','90 days'),
  ('silver.agg_equipment_values_1hour','13 months'), ('silver.equipment_categorical_1hour','13 months'),
  ('gold.equipment_oee_hourly','13 months'),
  ('gold.equipment_oee_shift',NULL), ('gold.equipment_oee_daily',NULL), ('gold.equipment_oee_weekly',NULL),
  ('gold.equipment_oee_monthly',NULL), ('gold.equipment_oee_shift_weekly',NULL), ('gold.equipment_oee_shift_monthly',NULL),
  ('gold.area_oee_shift',NULL), ('gold.area_oee_daily',NULL), ('gold.site_oee_shift',NULL),
  ('silver.equipment_events','5 years'),
  ('bronze.box_scans',NULL), ('gold.po_box_counter',NULL), ('gold.production_orders_runtime',NULL),
  ('core.production_orders',NULL), ('silver.equipment_events_man',NULL),
  ('silver.equipment_events_cpac_shadow','90 days'), ('ops.retention_run','13 months')
) AS v(relation, keep)
WHERE ops.retention_policy.relation = v.relation;
CALL ops.apply_retention();
COMMIT;
