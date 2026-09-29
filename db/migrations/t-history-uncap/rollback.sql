-- Rollback: restore the pre-fix values from the snapshot (step 2's NULLs included, since every
-- NULLed row was first uncapped in step 1 and therefore snapshotted).
BEGIN;
UPDATE gold.equipment_oee_hourly g SET oee = b.oee, oee_p = b.oee_p FROM ops._bkp_history_uncap_20260929 b WHERE b.tbl = 'equipment_oee_hourly' AND g.id_equipment = b.key_id AND g.ts_value::timestamptz = b.ts_value;
UPDATE gold.equipment_oee_shift g SET oee = b.oee, oee_p = b.oee_p FROM ops._bkp_history_uncap_20260929 b WHERE b.tbl = 'equipment_oee_shift' AND g.id_equipment = b.key_id AND g.ts_value::timestamptz = b.ts_value;
UPDATE gold.equipment_oee_daily g SET oee = b.oee, oee_p = b.oee_p FROM ops._bkp_history_uncap_20260929 b WHERE b.tbl = 'equipment_oee_daily' AND g.id_equipment = b.key_id AND g.ts_value::timestamptz = b.ts_value;
UPDATE gold.equipment_oee_weekly g SET oee = b.oee, oee_p = b.oee_p FROM ops._bkp_history_uncap_20260929 b WHERE b.tbl = 'equipment_oee_weekly' AND g.id_equipment = b.key_id AND g.ts_value::timestamptz = b.ts_value;
UPDATE gold.equipment_oee_monthly g SET oee = b.oee, oee_p = b.oee_p FROM ops._bkp_history_uncap_20260929 b WHERE b.tbl = 'equipment_oee_monthly' AND g.id_equipment = b.key_id AND g.ts_value::timestamptz = b.ts_value;
UPDATE gold.area_oee_shift g SET oee = b.oee, oee_p = b.oee_p FROM ops._bkp_history_uncap_20260929 b WHERE b.tbl = 'area_oee_shift' AND g.id_area = b.key_id AND g.ts_value::timestamptz = b.ts_value;
UPDATE gold.site_oee_shift g SET oee = b.oee, oee_p = b.oee_p FROM ops._bkp_history_uncap_20260929 b WHERE b.tbl = 'site_oee_shift' AND g.id_site = b.key_id AND g.ts_value::timestamptz = b.ts_value;
UPDATE gold.area_oee_daily g SET oee = b.oee, oee_p = b.oee_p FROM ops._bkp_history_uncap_20260929 b WHERE b.tbl = 'area_oee_daily' AND g.id_area = b.key_id AND g.ts_value::timestamptz = b.ts_value;
DELETE FROM silver.data_quality_event WHERE rule = 'OEE_GT_1' AND bucket_ts < '2026-08-31' AND detected_at::date = DATE '2026-09-29';
COMMIT;
