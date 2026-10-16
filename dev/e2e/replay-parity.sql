-- dev/e2e/replay-parity.sql — ADR-0060 P3 exit check: the live pipeline reproduces the seed.
-- For every replayed equipment, gross/net/scrap written at "now" by decoder → stream-engine must equal the seed's
-- values for the same window one week earlier (seed-replay's lag). Window: the 5 minutes ending 1 minute ago (rows
-- still in flight), so replay must have run ≥ 7 minutes: the first samples after a (re)birth are a session edge.
-- Gross and net are what replay feeds in: they must match within two samples (replay ticks every 5 s, so live rows
-- sit a few seconds off the seed's and one row can cross each window edge). Scrap is partly DERIVED by the pipeline
-- (and on line L6 the seed's scrap is itself wrong: docs/dev/contracts.md §4 F10): divergences are listed
-- for information, not failed. Writes nothing. Exit: the final SELECT is 'PASS'.
\set ON_ERROR_STOP 1
BEGIN;  -- temp views only; ROLLBACK at the end, nothing persists
CREATE TEMP VIEW w AS SELECT now() - interval '6 minutes' AS t0, now() - interval '1 minute' AS t1;
CREATE TEMP VIEW parity AS
WITH live AS (
  SELECT id_equipment, sum(gross_production_incr) g, sum(net_production_incr) n, sum(scrap_incr) s, count(*) c
    FROM silver.equipment_values, w WHERE ts_value > w.t0 AND ts_value <= w.t1 GROUP BY 1),
seed AS (
  SELECT id_equipment, sum(gross_production_incr) g, sum(net_production_incr) n, sum(scrap_incr) s, count(*) c,
         max(greatest(abs(gross_production_incr), abs(net_production_incr))) step
    FROM silver.equipment_values, w
   WHERE ts_value > w.t0 - interval '7 days' AND ts_value <= w.t1 - interval '7 days' GROUP BY 1)
SELECT coalesce(l.id_equipment, s.id_equipment) id_equipment, s.c seed_rows, l.c live_rows,
       s.g seed_gross, l.g live_gross, s.n seed_net, l.n live_net, s.s seed_scrap, l.s live_scrap,
       (abs(coalesce(l.g,0) - coalesce(s.g,0)) <= 2 * coalesce(s.step,0)
        AND abs(coalesce(l.n,0) - coalesce(s.n,0)) <= 2 * coalesce(s.step,0)) ok,
       abs(coalesce(l.s,0) - coalesce(s.s,0)) <= 2 * coalesce(s.step,0) AS scrap_ok
  FROM live l FULL JOIN seed s USING (id_equipment);
SELECT t0, t1 FROM w;
SELECT 'FAIL (gross/net)' AS kind, * FROM parity WHERE NOT ok
UNION ALL SELECT 'info (scrap only)', * FROM parity WHERE ok AND NOT scrap_ok ORDER BY 1, 2;
SELECT CASE WHEN count(*) > 0 AND bool_and(ok) THEN 'PASS' ELSE 'FAIL' END AS replay_parity,
       count(*) AS equipments, count(*) FILTER (WHERE ok) AS matching
  FROM parity;
ROLLBACK;
