-- refresh-downtime-resolved-history.sql — step 3 of the T1 legacy-history backfill.
-- serving.downtime_events_v3 (front4 Downtimes) reads the MATERIALIZED table
-- serving.downtime_events_resolved, which job 1072 refreshes only for the last 3 days.
-- After backfilling silver.equipment_events(+_man), materialize history once.
--
--   psql -d packiot_analytics -v from=2021-09-24 -v to=2026-06-01 -f db/backfill/refresh-downtime-resolved-history.sql
--
-- Month by month via \gexec: each generated statement runs separately, so under psql's
-- default autocommit every month is its OWN short transaction (the refresh DELETEs +
-- INSERTs its window; one 5-year window would hold locks + WAL far too long).
-- Idempotent (the function replaces its window). Resolved rows pick up shift
-- (gold.equipment_oee_shift) and PO attribution (production_orders_runtime) — both
-- backfilled first, so historical downtimes are attributed exactly like live ones.
\set ON_ERROR_STOP 1
SELECT format('SELECT %L AS month, serving.refresh_downtime_events_resolved(%L::timestamptz, %L::timestamptz) AS auto_rows',
              to_char(m, 'YYYY-MM'),
              greatest(m, :'from'::timestamptz),
              least(m + interval '1 month', :'to'::timestamptz))
  FROM generate_series(date_trunc('month', :'from'::timestamptz),
                       :'to'::timestamptz - interval '1 second', interval '1 month') m
 ORDER BY m
\gexec
