-- Rollback t-bispharma-mock-rated-speeds (STAGING).
-- Restores ent-5 machine production_speed from the backup, then drops the backup table.

BEGIN;

DO $$
BEGIN
  IF to_regclass('ops._bkp_ent5_production_speed') IS NOT NULL THEN
    UPDATE core.equipments e
       SET production_speed = b.production_speed
      FROM ops._bkp_ent5_production_speed b
     WHERE e.id_equipment = b.id_equipment;
    DROP TABLE ops._bkp_ent5_production_speed;
  ELSE
    RAISE NOTICE 'no backup table — nothing restored';
  END IF;
END $$;

COMMIT;
