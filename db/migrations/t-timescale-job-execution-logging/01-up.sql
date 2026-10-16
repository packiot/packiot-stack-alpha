-- t-timescale-job-execution-logging — log every TimescaleDB background-job run (ADR-0063 Phase A5).
--
-- WHY: with timescaledb.enable_job_execution_logging = off (staging, 2026-10-14) the job
-- history (timescaledb_information.job_history) keeps only FAILED runs, so per-run cost
-- is invisible: ADR-0063 had to infer job CPU from bgw_job_stat's cumulative totals.
-- With it on, every run gets a row (start, finish, success). Retention is already
-- bounded by job 3 (Job History Log Retention Policy: 1 month, at most 1000 successes
-- and 1000 failures per job), so the table stays ~31 jobs x 1000 rows.
--
-- HOW: the GUC exists in TimescaleDB 2.27.0 with context `sighup` (pg_settings on
-- staging), so ALTER SYSTEM + pg_reload_conf() applies it to the running scheduler, no
-- restart (tested on 2.27.0: off → 0 history rows in 15 s, on → 3 rows in 15 s, same
-- scheduler pid). The same flag is also on the container command line in
-- terraform/staging/user_data/db_init.sh so a recreated box keeps it.
--
-- ALTER SYSTEM cannot run inside a transaction block, so this file has no BEGIN/COMMIT.
-- Idempotent: setting the same value again is a no-op.
\set ON_ERROR_STOP 1
ALTER SYSTEM SET timescaledb.enable_job_execution_logging = 'on';
SELECT pg_reload_conf();
