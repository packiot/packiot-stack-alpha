-- t-ent5-lead-event-display — show the downtime events the count-silence deriver
-- now mints on NET-ONLY line leads (stream-engine CPACConfig.LeadActivity, live
-- instance CPAC_EVENT_LIVE_ENTERPRISES=5).
--
-- 8 of 23 Bispharma lines (L18 + BISNAGOSP L56/L57/L58/L60/L71/L72/L73) have NO
-- gross_machine: their only meter is the lead_machine's NET counter
-- (TAMPADEIRA / M67x / M68x). The gross-only deriver minted nothing for them.
-- With LeadActivity the stops land on those leads, but the leads were onboarded
-- with event_should_be_displayed NULL, and serving.refresh_downtime_events_resolved
-- (the Downtimes page, serving.downtime_events_v3) and serving.v_events_2 filter
-- `event_should_be_displayed = true` — so the stops would still be hidden.
--
-- Scope: ONLY leads of lines with gross_machine IS NULL. Lines with a
-- gross_machine already display that member's stops (t-ent5-enable-event-display);
-- L90's lead S2OUTPUT is deliberately left hidden so the Downtimes page does not
-- list L90 twice (S1INFEED + S2OUTPUT both resolve to id_line L90).
-- Display-only flag: feeds no OEE calculation. Idempotent. Apply AFTER the
-- stream-engine deploy that carries LeadActivity.
UPDATE core.equipments
   SET event_should_be_displayed = true
 WHERE id_enterprise = 5
   AND event_should_be_displayed IS DISTINCT FROM true
   AND id_equipment IN (
        SELECT lead_machine
          FROM core.equipments
         WHERE id_enterprise = 5 AND tp_equipment = 3
           AND gross_machine IS NULL
           AND downtime_from_lead_machine
           AND COALESCE(lead_machine, 0) > 0);

SELECT serving.refresh_downtime_events_resolved(date_trunc('month', now()) - interval '1 month', now());
