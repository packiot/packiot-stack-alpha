-- ADR-0063 C2 (staging): housekeeping jobs move from TimescaleDB's job scheduler (add_job) to pg_cron.
-- §13.2: pg_cron runs them as the owner, top-level CALL may COMMIT (ops.job_data_invariants does).
-- Environment-specific on purpose (an ops script, not a migration): staging has pg_cron installed in the
-- `packiot` database and schedules into packiot_analytics with cron.schedule_in_database; production gets
-- pg_cron with its Phase C image (no pg_cron in today's timescale/timescaledb image).
--
--   psql -h <db> -U postgres -d packiot_analytics -f scripts/ops/adr0063-c2-pgcron-jobs.sql
--   undo: psql ... -v undo=1 -f scripts/ops/adr0063-c2-pgcron-jobs.sql
--
-- Order: schedule in pg_cron FIRST, then unschedule the TimescaleDB copies (an overlap runs an idempotent
-- job twice; a gap would skip one). purge_analytics_plain is staging-only (prod excludes it by design).
\set ON_ERROR_STOP 1
\if :{?undo}
\c packiot
SELECT cron.unschedule(jobname) FROM cron.job WHERE jobname IN
  ('analytics-partition-maintain', 'analytics-purge-plain', 'analytics-downtime-resolved', 'analytics-data-invariants');
\c packiot_analytics
SELECT alter_job(job_id, scheduled => true) FROM timescaledb_information.jobs
 WHERE proc_name IN ('purge_analytics_plain', 'job_refresh_downtime_events_resolved', 'job_data_invariants');
\echo 'undone: TimescaleDB jobs scheduled again, pg_cron jobs removed'
\else
\c packiot
SELECT cron.schedule_in_database('analytics-partition-maintain', '20 3 * * *',
       $$SELECT * FROM ops.partition_maintain()$$, 'packiot_analytics');
SELECT cron.schedule_in_database('analytics-purge-plain', '10 3 * * *',
       $$CALL public.purge_analytics_plain(NULL, NULL)$$, 'packiot_analytics');
SELECT cron.schedule_in_database('analytics-downtime-resolved', '*/2 * * * *',
       $$CALL serving.job_refresh_downtime_events_resolved(NULL, NULL)$$, 'packiot_analytics');
SELECT cron.schedule_in_database('analytics-data-invariants', '*/30 * * * *',
       $$CALL ops.job_data_invariants(NULL, NULL)$$, 'packiot_analytics');
\c packiot_analytics
SELECT alter_job(job_id, scheduled => false) FROM timescaledb_information.jobs
 WHERE proc_name IN ('purge_analytics_plain', 'job_refresh_downtime_events_resolved', 'job_data_invariants');
\echo 'done: 4 pg_cron jobs scheduled; 3 TimescaleDB jobs unscheduled (kept, not deleted)'
\endif
