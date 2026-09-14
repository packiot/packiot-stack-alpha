-- refresh-equipment_values-cutover.sql — RE-RUN after EVERY historian backfill/append.
-- Must be a TOP-LEVEL statement (pg_duckdb cannot scan the `equipment_values` parquet inside a
-- function). Wire into the append job's post-run hook:
--   docker exec hist-gateway psql -U postgres -d postgres -f /path/refresh-equipment_values-cutover.sql
-- A missing/stale cutover row for an in-historian enterprise re-introduces the
-- hot/cold double-count in equipment_values_all.
-- t271: only ev_promoted enterprises get a cutover row (a non-promoted row would
-- wrongly clip that tenant's HOT history, since its cold is no longer served).
INSERT INTO ev_union_boundary (id_enterprise, cutover_ts, refreshed_at)
SELECT h.id_enterprise, max(h.ts_value), now()
  FROM equipment_values h
  JOIN promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.ev_promoted
 WHERE h.id_enterprise IS NOT NULL
 GROUP BY h.id_enterprise
ON CONFLICT (id_enterprise)
  DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();
-- prune any boundary row whose enterprise is no longer ev_promoted
DELETE FROM ev_union_boundary
 WHERE id_enterprise NOT IN (SELECT id_enterprise FROM promoted_enterprise WHERE ev_promoted);
SELECT id_enterprise, cutover_ts FROM ev_union_boundary ORDER BY id_enterprise;
