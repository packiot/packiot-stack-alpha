-- Revert: hide ent5 gross_machine member events again.
UPDATE core.equipments
   SET event_should_be_displayed = false
 WHERE id_enterprise = 5
   AND id_equipment IN (
        SELECT gross_machine FROM core.equipments
         WHERE id_enterprise = 5 AND tp_equipment = 3 AND gross_machine IS NOT NULL);
SELECT serving.refresh_downtime_events_resolved(date_trunc('month', now()) - interval '1 month', now());
