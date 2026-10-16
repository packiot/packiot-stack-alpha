-- Rollback. ORDER: first repoint read-api's downtimes-events dataset back to
-- serving.downtime_events_v2 and deploy, THEN run this (else read-api errors on a missing v3).
SELECT delete_job(job_id) FROM timescaledb_information.jobs WHERE proc_name='job_refresh_downtime_events_resolved';
DROP PROCEDURE IF EXISTS serving.job_refresh_downtime_events_resolved(int, jsonb);
DROP FUNCTION  IF EXISTS serving.downtime_events_v3(integer,text,text,text,text,timestamp,timestamp,boolean);
DROP FUNCTION  IF EXISTS serving.refresh_downtime_events_resolved(timestamptz, timestamptz);
DROP TABLE     IF EXISTS serving.downtime_events_resolved;
DROP TABLE     IF EXISTS serving.downtime_events_resolved_meta;
