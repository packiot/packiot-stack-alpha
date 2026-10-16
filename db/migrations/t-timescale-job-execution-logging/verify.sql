-- verify for t-timescale-job-execution-logging. label|value, expected in the label. Read-only.
-- Run in a NEW session after 01-up.sql (a session picks up a reload at its next command).
\set ON_ERROR_STOP 1
SELECT 'V1 setting: on', current_setting('timescaledb.enable_job_execution_logging');
SELECT 'V2 source / pending restart: configuration file|f', source, pending_restart
  FROM pg_settings WHERE name = 'timescaledb.enable_job_execution_logging';
SELECT 'V3 job-history retention policy still scheduled: 1', count(*)
  FROM timescaledb_information.jobs WHERE proc_name = 'policy_job_stat_history_retention' AND scheduled;
-- V4 needs ~2 minutes after the reload (jobs 1003/1057 run every minute):
SELECT 'V4 successful runs logged in the last 10 min (wait 2 min): > 0', count(*)
  FROM timescaledb_information.job_history WHERE succeeded AND start_time > now() - interval '10 minutes';
