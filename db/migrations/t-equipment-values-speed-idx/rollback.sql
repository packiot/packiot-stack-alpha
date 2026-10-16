-- no-op data; drop only if the live-status job is reverted
DROP INDEX IF EXISTS silver.equipment_values_id_equipment_ts_value_speed_idx;
