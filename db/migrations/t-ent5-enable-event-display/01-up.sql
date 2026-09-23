-- t-ent5-enable-event-display — make ent5 (Bispharma) derived downtimes visible in the UI.
--
-- ent5 is a counters-only, line-metered tenant. Its per-line downtime STOPS are synthesized by
-- the count-silence deriver (ADR-0010, stream-engine CPAC_EVENT_LIVE_ENTERPRISES=5) onto each
-- line's gross_machine (S1INFEED) member — that is where consumed-count silence = a line stop.
--
-- Those members were onboarded with event_should_be_displayed=false (correct back when ent5 had
-- no events at all). But serving.refresh_downtime_events_resolved — the job that materializes the
-- table the Downtimes UI reads (serving.downtime_events_v3) — filters `eq.event_should_be_displayed
-- = true`. So every ent5 stop was dropped and the Downtimes page showed "No rows" / empty Pareto,
-- even though the stops exist and the members already have the correct parent = their tp=3 line.
--
-- Enabling the flag lets those stops resolve to their parent line (id_line) and appear on the
-- Downtimes/Mission-Control views. The flag is display-only (61 usages across the schema, all in
-- downtime-event display paths) — it does NOT feed any OEE calculation, which reads the gold
-- aggregates. Idempotent.
UPDATE core.equipments
   SET event_should_be_displayed = true
 WHERE id_enterprise = 5
   AND event_should_be_displayed IS DISTINCT FROM true
   AND id_equipment IN (
        SELECT gross_machine
          FROM core.equipments
         WHERE id_enterprise = 5 AND tp_equipment = 3 AND gross_machine IS NOT NULL);

-- Re-materialize the resolved table for the visible window so the fix takes effect immediately
-- (otherwise the 2-min TimescaleDB job would only backfill the last 3 days).
SELECT serving.refresh_downtime_events_resolved(date_trunc('month', now()) - interval '1 month', now());
