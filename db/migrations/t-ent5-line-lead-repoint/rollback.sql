-- rollback t-ent5-line-lead-repoint: restore the original (non-reporting) leads.
BEGIN;
UPDATE core.equipments l SET lead_machine = c.id_equipment
  FROM core.equipments cur, core.equipments c
 WHERE l.id_enterprise = 5 AND l.tp_equipment = 3 AND cur.id_equipment = l.lead_machine
   AND c.id_parentequipment = l.id_equipment
   AND ((cur.nm_equipment = 'S1INFEED'   AND c.nm_equipment = 'S6OUTPUT')
     OR (cur.nm_equipment = 'TAMPADEIRA' AND c.nm_equipment = 'IMPRESSAO'));
COMMIT;
