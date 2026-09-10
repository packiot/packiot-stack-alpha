-- t258a — de-shim public, increment A: drop the dead 10-min cagg.
--
-- #258 phase-1 sliver. `public.agg_equipment_values_10min` is a continuous aggregate that
-- is provably dead, hardproofed 2026-09-10 from the LIVE DB (not the stale local checkout):
--   * pg_stat_statements (since 2026-09-04, 6-day window): 0 real queries reference it
--     (its sibling agg_equipment_values_1hour has 3,761 calls, _1min has 414 — those STAY).
--   * 0 refresh/materialization jobs → frozen watermark (nothing maintains it).
--   * 0 dependent views, 0 cagg-on-cagg, 0 function references.
-- So it is a leaf, unmaintained, unconsumed 10-minute rollup — safe to drop.
--
-- (A 10-minute cagg would be queried within any 6-day window if anything used it; 0 calls
-- is unambiguous at that grain, unlike the monthly/weekly grains where a 6-day window
-- can't prove absence — those are deferred to a code-repoint, not a blind drop.)
--
-- Reversible: rollback.sql recreates it from the exact captured definition (data
-- re-materializes from silver/equipment_values on the first refresh if ever needed).

-- APPLIED 2026-09-10 in a maintenance window: cagg DDL contends with the
-- equipment_values invalidation lock held by continuous ingest, so this was run as
-- STOP stream-engine (RMQ buffers) → DROP → START (ingest recovered to 3.6s staleness).
-- Idempotent (IF EXISTS) so a redeploy re-run is a safe no-op.

SET lock_timeout = '30s';

DROP MATERIALIZED VIEW IF EXISTS public.agg_equipment_values_10min;
