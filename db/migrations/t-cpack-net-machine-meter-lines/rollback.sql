BEGIN;
UPDATE core.equipments SET net_machine = NULL
 WHERE id_enterprise IN (3, 2000003) AND tp_equipment = 3 AND nm_equipment IN ('L4', 'L6', 'L8', 'L10');
COMMIT;
