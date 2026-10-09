-- t-ent5-l90-lead-display — L90's downtime display flag on its configured lead (2026-10-01, applied on staging).
-- Every Bispharma line shows its LEAD machine's stops (event_should_be_displayed = true on the lead,
-- NULL on the other members: 22 lines). L90 was the one inverted case — the flag sat on S1INFEED
-- (non-lead) while its lead_machine S2OUTPUT was NULL — so the lead's 20 stops (36.1 h, Sept) were
-- hidden and the infeed's 45 shown. Then: SELECT serving.refresh_downtime_events_resolved('2026-09-01', now());
UPDATE core.equipments SET event_should_be_displayed = true WHERE id_equipment = 2000330 AND id_enterprise = 5; -- S2OUTPUT (lead)
UPDATE core.equipments SET event_should_be_displayed = NULL WHERE id_equipment = 2000329 AND id_enterprise = 5; -- S1INFEED
