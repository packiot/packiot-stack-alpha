-- 03-purge-nonstate-event-pollution.sql — REFACTORED schemas only
-- (shadow_go_port in packiot, public in packiot_analytics). Never legacy.
--
-- One-time cleanup paired with the BuildEventMint status_type=4 gate. Before
-- the gate, BuildEventMint minted a raw open (ts_end NULL) equipment_events row
-- per StateCurrent sample for EVERY equipment, but the events deriver
-- (ADR-0014 P3a) only cleans status_type=4. So status_type!=4 equipment
-- (lines/sectors + non-state machines) accumulated thousands of open events
-- that the running_time compute counted to now() — eq=51 (L8) reached 6914 open
-- events → 44,182 h/day vs legacy's 13.6, overflowing the week rollup (#34/#41).
--
-- This purges exactly that pollution: non-forced, still-open events on
-- status_type!=4 equipment. Legitimate rows (forced_creation_system line
-- aggregation, deriver-closed intervals with ts_end) are untouched. Run AFTER
-- the gate is deployed so it doesn't regenerate. Sed __SCH__ per schema.

DELETE FROM __SCH__.equipment_events ev
USING public.equipments e
WHERE ev.id_equipment = e.id_equipment
  AND COALESCE(e.status_type, 0) <> 4
  AND ev.forced_creation_system = false
  AND ev.ts_end IS NULL;
