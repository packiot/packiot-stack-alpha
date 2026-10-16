-- Revert the L5 net source to the lead. Drop the column only after the
-- stream-engine that reads it has been rolled back too.
BEGIN;
UPDATE core.equipments SET net_machine = NULL
 WHERE id_enterprise IN (3, 2000003) AND tp_equipment = 3 AND nm_equipment = 'L5';
-- ALTER TABLE core.equipments DROP COLUMN net_machine;
COMMIT;
