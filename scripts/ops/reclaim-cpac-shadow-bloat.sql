-- reclaim-cpac-shadow-bloat.sql — give back the space silver.equipment_events_cpac_shadow
-- accumulated from 8.6 M no-op updates (92 MB heap for ~2.6 MB of live tuples; 2026-10-14).
--
-- RUN ONLY AFTER: (1) #1772 is deployed (the no-op guard; otherwise the heap regrows at
-- ~400-600 dead tuples per minute), (2) db/migrations/t-cpac-shadow-dup-indexes (so the rewrite
-- does not rebuild two redundant 40 MB indexes), (3) scripts/ops/repair-cpac-shadow-stale-open.sql
-- (its ~12 k updates leave dead tuples this also reclaims).
--
-- WHY VACUUM FULL: plain (auto)VACUUM only marks the space reusable inside the file; with the
-- guard the table stops growing and would reuse it, but stays 92 MB + 52 MB of indexes for good.
-- pg_repack is not installed on the staging DB (pg_extension: btree_gist, dblink,
-- pg_stat_statements, plpgsql, timescaledb). The table is a PLAIN table, not a hypertable
-- (relkind r; not in timescaledb_information.hypertables), so there is no chunk-wise
-- alternative to consider and VACUUM FULL is the standard tool.
--
-- LOCK / DURATION: ACCESS EXCLUSIVE on the shadow table for the whole rewrite. It reads the 92 MB
-- heap, writes ~3 MB, and rebuilds the PK and ts_event indexes over ~27 k rows: about 1-3 s on the
-- 2-vCPU host. Blocked meanwhile: the CPACK shadow deriver tick (it waits, then runs) and the
-- comparator. Nothing client-facing reads this table. lock_timeout makes it give up instead of
-- queueing behind a running tick: retry. Disk: needs ~5 MB free.
--
--   docker exec -i timescaledb psql -U postgres -d packiot_analytics -X < reclaim-cpac-shadow-bloat.sql
\set ON_ERROR_STOP 1
SET lock_timeout = '5s';
SET statement_timeout = '2min';
\echo == before
SELECT pg_size_pretty(pg_relation_size('silver.equipment_events_cpac_shadow')) AS heap,
       pg_size_pretty(pg_indexes_size('silver.equipment_events_cpac_shadow')) AS indexes,
       (SELECT count(*) FROM silver.equipment_events_cpac_shadow) AS live_rows;
\timing on
VACUUM (FULL, ANALYZE) silver.equipment_events_cpac_shadow;
\timing off
\echo == after (expected: heap ~3-4 MB, indexes ~2 MB, same live_rows)
SELECT pg_size_pretty(pg_relation_size('silver.equipment_events_cpac_shadow')) AS heap,
       pg_size_pretty(pg_indexes_size('silver.equipment_events_cpac_shadow')) AS indexes,
       (SELECT count(*) FROM silver.equipment_events_cpac_shadow) AS live_rows;
