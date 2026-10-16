-- rollback for t-deriver-phantom-running-cleanup: re-insert the deleted phantom rows and
-- restore the old ts_end/duration of the re-chained rows from the ops backups.
BEGIN;
SET LOCAL statement_timeout = 0;

INSERT INTO silver.equipment_events
SELECT * FROM ops._bkp_phantom_running_live_20260929
ON CONFLICT (id_equipment, ts_event) DO NOTHING;

INSERT INTO silver.equipment_events_cpac_shadow
SELECT * FROM ops._bkp_phantom_running_shadow_20260929
ON CONFLICT (id_equipment, ts_event) DO NOTHING;

UPDATE silver.equipment_events ev SET ts_end = b.ts_end, duration = b.duration
  FROM ops._bkp_phantom_rechain_20260929 b
 WHERE b.src = 'live' AND ev.id_equipment = b.id_equipment AND ev.ts_event = b.ts_event;

UPDATE silver.equipment_events_cpac_shadow ev SET ts_end = b.ts_end, duration = b.duration
  FROM ops._bkp_phantom_rechain_20260929 b
 WHERE b.src = 'shadow' AND ev.id_equipment = b.id_equipment AND ev.ts_event = b.ts_event;

SELECT (SELECT count(*) FROM ops._bkp_phantom_running_live_20260929)   AS live_restored,
       (SELECT count(*) FROM ops._bkp_phantom_running_shadow_20260929) AS shadow_restored,
       (SELECT count(*) FROM ops._bkp_phantom_rechain_20260929)        AS rechain_restored;
COMMIT;
-- Drop the ops._bkp_phantom_* tables only after the rollback has been verified.
SELECT serving.refresh_downtime_events_resolved(date_trunc('month', now()) - interval '1 month', now());
