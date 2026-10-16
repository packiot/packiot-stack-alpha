-- transplant phase `policies` for a TimescaleDB-FREE staging (ADR-0063 end state, 2026-10-16). build.py ships this as
-- 10-policies.sql when staging has no timescaledb; 10-policies.sql (TimescaleDB jobs) is the pre-ADR-0063 path.
-- Nothing is scheduled INSIDE the database: staging runs these from pg_cron (scripts/ops/adr0063-c2-pgcron-jobs.sql);
-- the prod server has no pg_cron (D2 image), so the prod DB host runs them from systemd timers
-- (scripts/ops/analytics-housekeeping.sh + systemd/analytics-housekeeping-*.timer, docs/runbooks/go-live-bispharma.md):
--   partition-maintain 03:20 · downtime-resolved */2 min · data-invariants */30 min.
--   purge_analytics_plain is NOT scheduled on prod (decided 2026-10-09: it deletes data; prod has no cold tier).
-- This phase runs each once, so the new DB is ready before the timers exist, and proves raw retention is off.
\set ON_ERROR_STOP 0
-- partitions ahead (the dump carries staging's at dump time; this adds up to 60 days ahead and drops only past keep)
SELECT 'partition_maintain', * FROM ops.partition_maintain();
CALL serving.job_refresh_downtime_events_resolved(NULL, NULL);
CALL ops.job_data_invariants(NULL, NULL);
-- guards — each want 0
SELECT 'timescaledb in this database (want 0)', count(*) FROM pg_extension WHERE extname = 'timescaledb';
SELECT 'raw retention, live TimescaleDB policies (want 0)', count(*)
  FROM ops.ts_retention_live() l JOIN ops.retention_policy p ON p.relation = l.relation WHERE p.tier = 'hot_raw';
SELECT 'raw partitioned relations with a keep (want 0)', count(*)
  FROM ops.pc_state s JOIN ops.retention_policy p ON p.relation = s.rel WHERE p.tier = 'hot_raw' AND p.keep IS NOT NULL;
SELECT 'partitioned relations without a future partition (want 0)', count(*)
  FROM ops.pc_state s
 WHERE s.swapped_at IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b
        WHERE i.inhparent = s.rel::regclass AND NOT b.hi_max AND b.hi > now() + interval '30 days');
