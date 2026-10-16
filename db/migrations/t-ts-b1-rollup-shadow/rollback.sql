-- t-ts-b1-rollup-shadow — rollback. Removes the shadow entirely; the caggs were never touched.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
DROP TRIGGER IF EXISTS rollup_invalidate_ins ON silver.equipment_values;
DROP TRIGGER IF EXISTS rollup_invalidate_upd ON silver.equipment_values;
DROP TRIGGER IF EXISTS rollup_invalidate_del ON silver.equipment_values;
DROP FUNCTION IF EXISTS silver.rollup_tick(interval, integer);
DROP FUNCTION IF EXISTS silver.rollup_shadow_diff(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS silver.rollup_seed_old_hours();
DROP PROCEDURE IF EXISTS silver.rollup_backfill(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS silver.rollup_refresh(timestamptz, timestamptz, integer[]);
DROP FUNCTION IF EXISTS silver.rollup_invalidate_row();
DROP TABLE IF EXISTS silver.rollup_invalidation;
DROP TABLE IF EXISTS silver.equipment_categorical_1min__next;
DROP TABLE IF EXISTS silver.equipment_categorical_1hour__next;
DROP TABLE IF EXISTS silver.equipment_metrics_1min__next;
DROP TABLE IF EXISTS silver.agg_equipment_values_1min__next;
DROP TABLE IF EXISTS silver.agg_equipment_values_1hour__next;
COMMIT;
