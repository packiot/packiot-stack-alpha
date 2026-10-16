-- t252 — FINAL drop of the medallion public compat shims (#251 Stage 3).
--
-- These 21 public.* pass-through views over gold/silver/core were restored by
-- t251 after #249/#250 dropped them PREMATURELY. Every consumer is now fully
-- de-shimmed and deployed:
--   #248             rollup + events            → silver/gold direct
--   #251 P1  (#1194) uns/dq/provision           → silver/gold/core direct
--   #251 P2  (#1195) pocontrol PO write-path     → Schemas{Core,Gold,Silver,Ev,Identity}
--   #251 P1b (#1196) silver-clamp + entity-grains→ gold (the helper-passed EvSchema
--                     the P1 grep missed; caught by the FIRST t252 drop soak, fixed, re-dropped GREEN)
--
-- Pre-drop audit (hardproof, 2026-09-09) — ALL clean:
--   * full-set DROP…RESTRICT dry-run  → 0 DB dependents
--   * pg_proc (prokind='f')           → 0 functions reference a public shim
--   * Superset metadata               → 0 datasets on these public tables
--   * stream-engine / read-api / edge-api → 0 qualified public.<medallion> refs
--     (audited by tracing EVERY d.EvSchema USAGE incl. helper-fn args + string concat,
--      NOT `grep Sprintf` — the P1 miss lesson)
--   * pocontrol multi-schema writes (incl. cross-schema FK gold.production_orders_runtime
--     → core.production_orders) hardproven against the REAL schemas in a rolled-back tx
--   * post-drop soak GREEN: 0 missing-relation errors over 6 min covering silver-clamp +
--     entity-grains + rollup ticks; live ingest + gold grains advancing.
--   * search_path (gold,silver,…,core,public) resolves BARE refs to the real tables.
--
-- Reversible: rollback.sql re-creates every view (identical to t251).
BEGIN;

-- gold facts
DROP VIEW IF EXISTS public.equipment_oee_hourly        RESTRICT;
DROP VIEW IF EXISTS public.equipment_oee_shift         RESTRICT;
DROP VIEW IF EXISTS public.equipment_oee_daily         RESTRICT;
DROP VIEW IF EXISTS public.equipment_oee_weekly        RESTRICT;
DROP VIEW IF EXISTS public.equipment_oee_monthly       RESTRICT;
DROP VIEW IF EXISTS public.equipment_oee_shift_monthly RESTRICT;
DROP VIEW IF EXISTS public.equipment_oee_shift_weekly  RESTRICT;
DROP VIEW IF EXISTS public.area_oee_shift              RESTRICT;
DROP VIEW IF EXISTS public.area_oee_daily              RESTRICT;
DROP VIEW IF EXISTS public.site_oee_daily              RESTRICT;
DROP VIEW IF EXISTS public.site_oee_shift              RESTRICT;
DROP VIEW IF EXISTS public.production_orders_runtime   RESTRICT;

-- silver facts + live grains
DROP VIEW IF EXISTS public.equipment_values        RESTRICT;
DROP VIEW IF EXISTS public.equipment_events        RESTRICT;
DROP VIEW IF EXISTS public.equipment_live_metrics  RESTRICT;
DROP VIEW IF EXISTS public.area_live_day           RESTRICT;
DROP VIEW IF EXISTS public.area_live_shift         RESTRICT;
DROP VIEW IF EXISTS public.site_live_day           RESTRICT;
DROP VIEW IF EXISTS public.equipment_live_day      RESTRICT;
DROP VIEW IF EXISTS public.equipment_live_shift    RESTRICT;

-- core dimension
DROP VIEW IF EXISTS public.production_orders        RESTRICT;

COMMIT;
