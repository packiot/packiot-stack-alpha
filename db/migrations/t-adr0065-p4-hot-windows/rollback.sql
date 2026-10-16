-- rollback t-adr0065-p4-hot-windows — restore the 90-day raw windows. Partitions already dropped are NOT restored
-- (the cold copy in the historian serves them); this only stops further drops at the shorter windows.
\set ON_ERROR_STOP 1
BEGIN;
UPDATE ops.retention_policy SET keep = interval '90 days', updated_at = now()
 WHERE relation IN ('bronze.equipment_values_raw', 'bronze.equipment_events_raw', 'silver.equipment_values',
                    'silver.plc_link_minutes');
COMMIT;
