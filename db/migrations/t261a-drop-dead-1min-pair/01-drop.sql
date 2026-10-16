-- t261a — drop the dead port-parity 1min pair (EvSchema-plane necessity pass, #261).
--
-- equipment_values_1min (table, 0 rows) → its only reader is the view
-- agg_equipment_values_1min_t, whose only reference is the stream-engine port-parity
-- CLI (cmd/port-parity) — a NON-deployed manual tool that is ALREADY BROKEN against
-- the current schema (its hourSnapshotSQL also reads public.ca_agg_equipment_values_1hour,
-- dropped in #239, and public.production_targets, re-homed). 0 live query hits on either
-- object (pg_stat_statements since reset). So this is a dead legacy pair, not a live shim.
--
-- Dropping them removes 1 of the 9 EvSchema-public objects from the eventual plane
-- re-home (#261) and clears a dangling feeder. Reversible (both are empty / definitional).
-- Kept: equipment_events_low_speed (also empty) — it is leg 3 of the multi-leg serving
-- view v_events_2 (whose leg 2 = live equipment_events_man), and an empty UNION leg is
-- harmless; dropping it would need a view redefinition, deferred with the #261 cutover.

DROP VIEW  IF EXISTS public.agg_equipment_values_1min_t;  -- reader (dependent) first
DROP TABLE IF EXISTS public.equipment_values_1min;
