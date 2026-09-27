-- Revert L3 to lead-only reads. Drop the columns only after the stream-engine that
-- reads them has been rolled back too.
BEGIN;
UPDATE core.equipments SET gross_counter = NULL, net_counter = NULL, net_machine = NULL
 WHERE id_enterprise IN (3, 2000003) AND tp_equipment = 3 AND nm_equipment = 'L3';
-- ALTER TABLE core.equipments DROP CONSTRAINT equipments_counter_roles_chk,
--   DROP COLUMN gross_counter, DROP COLUMN net_counter;
COMMIT;
