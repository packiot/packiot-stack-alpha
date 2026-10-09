-- t231 · Medallion schema separation — PHASE 5 (CLEANUP / CONTRACT)
-- DB: packiot_analytics (STAGING). DO NOT run on prod (packiot40 forward-port).
--
-- This phase repoints the remaining hard-coded `public.` writers/readers off the
-- expand/contract shim names, so a fresh apply targets the medallion homes and a
-- future step can DROP the shims. The stream-engine (ingest facts→silver, raw→
-- bronze), analytics-sync (equipment_events→silver), bake.go / port-parity /
-- mirror-worker (facts→silver) source lifts ship in the same PR and take effect
-- on their next deploy; until then they traverse the shim views (proven safe).
--
-- APPLIED here (safe, idempotent): the one live DB procedure that hard-codes the
-- gold shim names. purge_analytics_plain is a TimescaleDB user-defined action
-- (job_id, config signature) that DELETEs 90-day-old rows. It referenced the
-- public gold SHIM views (equipment_oee_hourly/_shift); repoint to gold directly.
-- equipment_events_cpac_shadow STAYS in public (a side table, not a moved grain).
CREATE OR REPLACE PROCEDURE public.purge_analytics_plain(IN job_id integer, IN config jsonb)
LANGUAGE plpgsql AS $procedure$
  BEGIN
    DELETE FROM gold.equipment_oee_hourly          WHERE ts_value < now() - interval '90 days';
    DELETE FROM gold.equipment_oee_shift           WHERE ts_value < now() - interval '90 days';
    DELETE FROM public.equipment_events_cpac_shadow WHERE ts_event < now() - interval '90 days';
  END;
$procedure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- DEFERRED — the shim DROPs (the true "contract") are NOT executed here.
-- Per the writer-audit lesson (#186): drop a compatibility surface ONLY after
-- every writer/reader is CONFIRMED off it via a zero-writer log-watch. That
-- requires the code lifts in this PR to be DEPLOYED first (stream-engine +
-- analytics-sync + bake/port-parity/mirror), then a window with no
-- `public.equipment_*` / `public.<grain>` reference in any service log.
--
-- When that gate is met, a follow-up migration runs:
--
--   -- gold shims (created in 03):
--   DROP VIEW public.equipment_oee_shift, public.equipment_oee_hourly,
--     public.equipment_oee_daily, public.equipment_oee_weekly,
--     public.equipment_oee_monthly, public.equipment_oee_shift_weekly,
--     public.equipment_oee_shift_monthly, public.area_oee_daily,
--     public.area_oee_shift, public.site_oee_daily, public.site_oee_shift,
--     public.production_orders_runtime;
--   -- silver shims (created in 04):
--   DROP VIEW public.equipment_values, public.equipment_events,
--     public.equipment_live_metrics;
--
-- Until then the shims are the live compatibility surface and MUST remain.
-- ─────────────────────────────────────────────────────────────────────────────
