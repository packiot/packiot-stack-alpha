BEGIN;
SELECT delete_job(job_id) FROM timescaledb_information.jobs WHERE proc_schema = 'ops' AND proc_name = 'job_data_invariants';
DROP PROCEDURE IF EXISTS ops.job_data_invariants(int, jsonb);
DROP VIEW IF EXISTS ops.data_invariant_latest;
DROP TABLE IF EXISTS ops.data_invariant_result;
COMMIT;
