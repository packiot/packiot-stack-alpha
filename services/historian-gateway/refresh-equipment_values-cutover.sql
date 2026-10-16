-- refresh-equipment_values-cutover.sql — RE-RUN after EVERY historian backfill/append.
-- Wired into the append job's post-run hook (scripts/historian-staging-run-append.sh):
--   docker exec -i hist-gateway psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -f - < this file
-- A missing/stale cutover row for an in-historian enterprise re-introduces the
-- hot/cold double-count in equipment_values_all.
-- t271: only ev_promoted enterprises get a cutover row (a non-promoted row would
-- wrongly clip that tenant's HOT history, since its cold is no longer served).
--
-- 2026-10-02: cutover_ts = max(ts_value) per enterprise is read from the Parquet FOOTERS
-- (parquet_metadata row-group statistics), not from cold.equipment_values. That view is a
-- cleaning view with window functions over all history (lag() per equipment, count() OVER per
-- hour), so max() through it made DuckDB sort + spill the whole archive (10.5 GB parquet,
-- 336M CPACK rows): from 2026-09-29 the spill exceeded the gateway's temp space ("Out of Memory
-- Error: failed to offload data block") every night, the hook stopped, and the boundary stayed
-- at 09-28 → equipment_values_all double-counted. Footers: ~100 s, constant memory.
-- Same rows as the view: it has no WHERE, every parquet row is served with its ts_value, and
-- the glob below is the view's glob (10-historian-gateway.sh). Timestamp statistics are exact.
-- A file without ts_value statistics fails the run (error()) instead of under-reporting max.
\getenv bucket HISTORIAN_BUCKET
\if :{?bucket}
\else
  \warn 'HISTORIAN_BUCKET is not set in the gateway container'
  SELECT historian_bucket_unset;
\endif
SELECT format($q$
  SELECT regexp_extract(file_name, 'enterprise=([0-9]+)', 1)::INTEGER AS id_enterprise,
         max(stats_max::TIMESTAMP) AS cold_max,
         max(CASE WHEN stats_max IS NULL THEN error('no ts_value statistics in ' || file_name) END) AS guard
    FROM parquet_metadata('s3://%s/equipment_values/*/*/*/*-legacy.parquet')
   WHERE path_in_schema = 'ts_value'
   GROUP BY 1$q$, :'bucket') AS ev_stats_q \gset

INSERT INTO ev_union_boundary (id_enterprise, cutover_ts, refreshed_at)
SELECT s.id_enterprise, s.cold_max, now()
  FROM (SELECT (r['id_enterprise'])::int AS id_enterprise, (r['cold_max'])::timestamp AS cold_max
          FROM duckdb.query(:'ev_stats_q') r) s
  JOIN promoted_enterprise p ON p.id_enterprise = s.id_enterprise AND p.ev_promoted
 WHERE s.cold_max IS NOT NULL
ON CONFLICT (id_enterprise)
  DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();
-- prune any boundary row whose enterprise is no longer ev_promoted
DELETE FROM ev_union_boundary
 WHERE id_enterprise NOT IN (SELECT id_enterprise FROM promoted_enterprise WHERE ev_promoted);
SELECT id_enterprise, cutover_ts FROM ev_union_boundary ORDER BY id_enterprise;
