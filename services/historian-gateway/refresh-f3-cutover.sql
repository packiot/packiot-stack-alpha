-- refresh-f3-cutover.sql — ADR-0065 P2: recompute f3_union_boundary from the analytics manifest (ops.cold_export via
-- live.cold_export). Run after every nightly cold export (scripts/historian-cold-export.sh post-run hook) and at the
-- end of 20-f3-cold.sql. Top-level statements only (postgres_fdw; no DuckDB scan involved).
--   cutover_ts = least(newest verified day end, first unverified day start) per tenant
-- A tenant with no verified row has no boundary → hot serves all of it (as before P2).
\set ON_ERROR_STOP 1
BEGIN;
CREATE TEMP TABLE _f3b ON COMMIT DROP AS
SELECT id_enterprise,
       least(max(period_hi) FILTER (WHERE verified_at IS NOT NULL),
             coalesce(min(period_lo) FILTER (WHERE verified_at IS NULL), 'infinity'::timestamptz)) AS cutover_ts
  FROM live.cold_export
 WHERE relation = 'silver.equipment_values'
 GROUP BY id_enterprise
HAVING max(period_hi) FILTER (WHERE verified_at IS NOT NULL) IS NOT NULL;
INSERT INTO public.f3_union_boundary (id_enterprise, cutover_ts, refreshed_at)
SELECT id_enterprise, cutover_ts, now() FROM _f3b
ON CONFLICT (id_enterprise) DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();
DELETE FROM public.f3_union_boundary b WHERE NOT EXISTS (SELECT 1 FROM _f3b x WHERE x.id_enterprise = b.id_enterprise);
COMMIT;
SELECT 'f3_union_boundary', id_enterprise, cutover_ts FROM public.f3_union_boundary ORDER BY 2;
