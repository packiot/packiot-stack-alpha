-- Rehearsal checks (after fixture.sql and 01-up.sql). Each line: label | got | want.
\set ON_ERROR_STOP 1
CREATE TEMP VIEW t AS SELECT id_production_order AS po, net_production, scrap, downtime
  FROM serving.v_operator_po_details_3;

-- before the Replace: PO 6 owns R1, R2, R3 → only the three in-runtime stops (the gap stops are nobody's)
SELECT 'C1 PO 6 downtime before replace', downtime, 1800 AS want FROM t WHERE po = 6;
-- R2 has no counters yet: the fallback reads values inside the runtime windows (not the 999 in the gap)
-- sum(net) of R1+R3 = 400 is non-zero, so the fallback is not used here
SELECT 'C2 PO 6 produced before replace', net_production, 400 AS want FROM t WHERE po = 6;

-- the Replace (what edge-api does): R2 moves to PO 5
UPDATE production_orders_runtime SET id_production_order = 5 WHERE id_production_order_runtime = 2;
UPDATE production_orders SET status = 4, ts_start = '2026-01-01 03:00+00', ts_end = '2026-01-01 05:00+00' WHERE id_production_order = 5;
-- PO 6 keeps R1 and R3: its SPAN 00:00–08:00 still covers R2 — the old view counted R2's stop here too

SELECT 'C3 PO 6 downtime after replace (R1 + R3)', downtime, 1200 AS want FROM t WHERE po = 6;
SELECT 'C4 PO 5 downtime after replace (R2)', downtime, 600 AS want FROM t WHERE po = 5;
SELECT 'C5 downtime counted once overall', sum(downtime), 1800 AS want FROM t WHERE po IN (5, 6);
SELECT 'C6 PO 6 produced (R1 + R3)', net_production, 400 AS want FROM t WHERE po = 6;
SELECT 'C7 PO 5 produced (R2 values fallback)', net_production, 200 AS want FROM t WHERE po = 5;
SELECT 'C8 PO 6 scrap (R1 + R3)', scrap, 50 AS want FROM t WHERE po = 6;
SELECT 'C9 security_invoker kept', 'security_invoker=on' = ANY (reloptions), true AS want
  FROM pg_class WHERE oid = 'serving.v_operator_po_details_3'::regclass;
SELECT 'C10 readapi_ro grant kept', has_table_privilege('readapi_ro', 'serving.v_operator_po_details_3', 'SELECT'), true AS want;
