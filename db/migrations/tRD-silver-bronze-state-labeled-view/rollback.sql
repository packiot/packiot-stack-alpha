-- Rollback for tRD-silver-bronze-state-labeled-view.
-- Drops the additive lookup table + labeled views and restores the prior
-- (t278/t279-era) column comments captured verbatim on 2026-09-13.

BEGIN;

DROP VIEW IF EXISTS silver.equipment_values_labeled;
DROP VIEW IF EXISTS silver.equipment_events_labeled;
DROP TABLE IF EXISTS silver.machine_state;

-- Restore prior comments (verbatim as read before this migration).
COMMENT ON COLUMN silver.equipment_values.state IS
'PackML machine state (6=RUNNING, 10=STOPPED, ...) at sample time.';
COMMENT ON COLUMN silver.equipment_events.status IS
'Machine/event status code at ts_event (e.g. 10=STOPPED).';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.status IS
'Derived machine/event status code.';
COMMENT ON COLUMN silver.equipment_events_man.status IS
'Machine/event status code.';
COMMENT ON COLUMN silver.equipment_events_low_speed.status IS
'Machine/event status code.';
COMMENT ON COLUMN bronze.equipment_events_raw.status IS
'Event/machine status code at ts_event (e.g. 10=STOPPED).';
COMMENT ON COLUMN bronze.equipment_values_raw.state IS
'PackML machine state (e.g. 6=RUNNING, 10=STOPPED) at sample time.';
COMMENT ON COLUMN silver.data_quality_event.severity IS
'Severity level (e.g. info, warn, critical).';

COMMIT;
