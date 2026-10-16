-- refresh-po-cutover.sql — RE-RUN after EVERY historian production_orders backfill/append.
-- Must be a TOP-LEVEL statement (pg_duckdb cannot scan the `production_orders` parquet inside a
-- function). Wire into the append job's post-run hook:
--   docker exec hist-gateway psql -U postgres -d packiot_historian -f /path/refresh-po-cutover.sql
-- A missing/stale cutover row for an in-historian enterprise re-introduces the
-- hot/cold double-count in silver.production_orders.
-- Cold-anchored (EV-style): legacy holds the deep PO history, analytics (hot FDW) the recent tail;
-- COLD owns ts_start <= cutover, HOT owns ts_start > cutover. Only po_promoted enterprises get a row
-- (a non-promoted row would wrongly clip that tenant's HOT history).
INSERT INTO po_union_boundary (id_enterprise, cutover_ts, refreshed_at)
SELECT h.id_enterprise, max(h.ts_start), now()
  FROM cold.production_orders h
  JOIN promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.po_promoted
 WHERE h.id_enterprise IS NOT NULL
 GROUP BY h.id_enterprise
ON CONFLICT (id_enterprise)
  DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();
-- prune any boundary row whose enterprise is no longer po_promoted
DELETE FROM po_union_boundary
 WHERE id_enterprise NOT IN (SELECT id_enterprise FROM promoted_enterprise WHERE po_promoted);
SELECT id_enterprise, cutover_ts FROM po_union_boundary ORDER BY id_enterprise;
