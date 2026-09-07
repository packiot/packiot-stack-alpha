-- refresh-hist-cutover.sql — RE-RUN after EVERY historian backfill/append.
-- Must be a TOP-LEVEL statement (pg_duckdb cannot scan the `hist` parquet inside a
-- function). Wire into the append job's post-run hook:
--   docker exec hist-gateway psql -U postgres -d postgres -f /path/refresh-hist-cutover.sql
-- A missing/stale cutover row for an in-historian enterprise re-introduces the
-- hot/cold double-count in ev_all.
INSERT INTO hist_cutover (id_enterprise, cutover_ts, refreshed_at)
SELECT id_enterprise, max(ts_value), now()
  FROM hist
 WHERE id_enterprise IS NOT NULL
 GROUP BY id_enterprise
ON CONFLICT (id_enterprise)
  DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();
SELECT id_enterprise, cutover_ts FROM hist_cutover ORDER BY id_enterprise;
