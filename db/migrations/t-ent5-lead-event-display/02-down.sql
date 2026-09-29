-- Revert: hide the ent5 net-only lead members' events again (they were NULL before).
UPDATE core.equipments
   SET event_should_be_displayed = NULL
 WHERE id_enterprise = 5
   AND id_equipment IN (
        SELECT lead_machine
          FROM core.equipments
         WHERE id_enterprise = 5 AND tp_equipment = 3
           AND gross_machine IS NULL
           AND downtime_from_lead_machine
           AND COALESCE(lead_machine, 0) > 0);
SELECT serving.refresh_downtime_events_resolved(date_trunc('month', now()) - interval '1 month', now());
