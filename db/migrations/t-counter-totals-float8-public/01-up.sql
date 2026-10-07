-- t-counter-totals-float8-public — PROD forward-port of t-counter-totals-float8 (staging applied 2026-10-07).
-- Target: the MAIN pool DB (stream-engine's default/"public" route, prod single-flow): public.equipment_values and,
-- where Bronze raw append exists, public.equipment_values_raw. Same model as staging: new nullable float8 *_total
-- columns (catalog-only, no rewrite), dual-written once COUNTER_TOTALS_PUBLIC=true, readers use
-- coalesce(*_total, *_val). See db/migrations/t-counter-totals-float8/01-up.sql for the full WHY.
--
-- ROLLOUT (user applies on prod; never automatic):
--   1. stream-engine stop window (ADD COLUMN = ACCESS EXCLUSIVE on the table and every chunk), apply this, verify.sql.
--   2. set COUNTER_TOTALS_PUBLIC=true for stream-engine, restart; verify.sql V4 > 0 after a few minutes.
--   Rollback: COUNTER_TOTALS_PUBLIC=false + restart FIRST, then rollback.sql (same window).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE public.equipment_values
  ADD COLUMN IF NOT EXISTS gross_production_total double precision,
  ADD COLUMN IF NOT EXISTS net_production_total   double precision,
  ADD COLUMN IF NOT EXISTS scrap_total            double precision,
  ADD COLUMN IF NOT EXISTS process_scrap_total    double precision;
COMMENT ON COLUMN public.equipment_values.gross_production_total IS 'Exact running gross counter total (float8). Read coalesce(gross_production_total, gross_production_val).';
COMMENT ON COLUMN public.equipment_values.net_production_total   IS 'Exact running net counter total (float8). Read coalesce(net_production_total, net_production_val).';
COMMENT ON COLUMN public.equipment_values.scrap_total            IS 'Exact running scrap counter total (float8). Read coalesce(scrap_total, scrap_val).';
COMMENT ON COLUMN public.equipment_values.process_scrap_total    IS 'Exact running process-scrap counter total (float8). Read coalesce(process_scrap_total, process_scrap_val).';
COMMIT;

BEGIN;
SET LOCAL lock_timeout = '3s';
DO $$ BEGIN
  IF to_regclass('public.equipment_values_raw') IS NOT NULL THEN
    ALTER TABLE public.equipment_values_raw
      ADD COLUMN IF NOT EXISTS gross_production_total double precision,
      ADD COLUMN IF NOT EXISTS net_production_total   double precision,
      ADD COLUMN IF NOT EXISTS scrap_total            double precision,
      ADD COLUMN IF NOT EXISTS process_scrap_total    double precision;
  ELSE
    RAISE NOTICE 'public.equipment_values_raw absent (Bronze raw append not enabled here) — skipped';
  END IF;
END $$;
COMMIT;
