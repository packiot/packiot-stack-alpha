-- t258 — drop the dim/grain public→core/silver compat shim VIEWS (medallion
-- de-shim completion, #258 increment 1).
--
-- These 9 public views are pure pass-throughs kept for the cutover:
--   public.equipments/sites/shift_hours/topic_routing → core.<same>
--   public.packml_register                            → core.topic_routing (legacy col shape)
--   public.equipment_live_{hour,job,month,week}        → silver.<same>
--
-- WHY SAFE TO DROP (hardproofed on staging 2026-09-13):
--   * search_path = "$user", gold, silver, bronze, identity, config, ops, serving,
--     customer_reports, core, public — so a BARE `equipments` resolves to
--     core.equipments; ONLY an explicit `public.equipments` hits a shim.
--   * Code grep (all services): the only public.<shim> refs are the manual
--     port-parity CLI (not a deployed step; repointed to core.* in the same PR)
--     and one rollup unit test (ephemeral fixture schema, unaffected).
--   * LIVE proof: pg_stat_statements reset, then across 289 distinct statements of
--     live traffic (rollup + read-api + all consumers), ZERO queries referenced any
--     of these public shims. #250 already dropped public.production_orders with the
--     same discipline — its stale stat entry confirmed the reset was needed.
--   * No DB object depends on any of the 9 (pg_depend: 0 dependents) → plain DROP.
--
-- This ONLY drops the shim VIEWS; the real core.*/silver.* objects are untouched.
-- Fully reversible via rollback.sql (recreates the exact view defs). Post-apply,
-- SOAK ≥ the slowest consumer cadence and watch logs for 42P01 before considering
-- it settled — a low-frequency external reader (BI/report) would surface late.
--
-- NOTE: the 4 public continuous aggregates (agg_equipment_values_1min/1hour,
-- ca_discrete_changes_1s, ca_equipment_boxes_1s) are LOAD-BEARING (read-api grain
-- map + uns.go + CPAC deriver) and are NOT touched here — their migration to silver
-- needs consumer-repointing + parity and is tracked as #258 increment 2.

DROP VIEW IF EXISTS public.equipments;
DROP VIEW IF EXISTS public.sites;
DROP VIEW IF EXISTS public.shift_hours;
DROP VIEW IF EXISTS public.topic_routing;
DROP VIEW IF EXISTS public.packml_register;
DROP VIEW IF EXISTS public.equipment_live_hour;
DROP VIEW IF EXISTS public.equipment_live_job;
DROP VIEW IF EXISTS public.equipment_live_month;
DROP VIEW IF EXISTS public.equipment_live_week;
