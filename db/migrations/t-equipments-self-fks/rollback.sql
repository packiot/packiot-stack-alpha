-- rollback for t-equipments-self-fks: back to the live staging shape of 2026-10-06 — no FKs on lead/gross/scrap/
-- id_parentequipment, and the (no-op) self-FK equipments_id_equipment_foreign restored. Data is not touched.
-- NOTE: on a DB built from db/init (13/14 declare inline REFERENCES), equipments_gross/scrap_machine_fkey pre-existed
-- this migration under the same auto-generated names; this rollback drops them there too.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE core.equipments DROP CONSTRAINT IF EXISTS equipments_lead_machine_fkey;
ALTER TABLE core.equipments DROP CONSTRAINT IF EXISTS equipments_gross_machine_fkey;
ALTER TABLE core.equipments DROP CONSTRAINT IF EXISTS equipments_scrap_machine_fkey;
ALTER TABLE core.equipments DROP CONSTRAINT IF EXISTS equipments_id_parentequipment_fkey;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'core.equipments'::regclass AND conname = 'equipments_id_equipment_foreign') THEN
    ALTER TABLE core.equipments ADD CONSTRAINT equipments_id_equipment_foreign FOREIGN KEY (id_equipment)
      REFERENCES core.equipments (id_equipment) ON UPDATE RESTRICT ON DELETE RESTRICT;
  END IF;
END $$;
COMMIT;
