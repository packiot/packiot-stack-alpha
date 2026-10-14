-- rollback for t-timescale-job-execution-logging — back to the default (off: only failures logged).
-- Rows already in the job history stay; job 3 ages them out within a month.
-- Also remove the -c flag from terraform/staging/user_data/db_init.sh, or a recreate turns it on again.
\set ON_ERROR_STOP 1
ALTER SYSTEM RESET timescaledb.enable_job_execution_logging;
SELECT pg_reload_conf();
