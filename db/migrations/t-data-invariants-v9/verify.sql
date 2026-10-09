-- verify for t-data-invariants-v9. Read-only: RAISEs unless the live procedure carries the v9 C6.
\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
DO $v$
DECLARE src text := (SELECT prosrc FROM pg_proc WHERE oid = 'ops.job_data_invariants(int, jsonb)'::regprocedure);
BEGIN
  IF src NOT LIKE '%sv.g_bkts = sv.bkts%' THEN RAISE EXCEPTION 'v9 C6 not live (old guard still in ops.job_data_invariants)'; END IF;
  IF src LIKE '%sv.g_hrs = sv.hrs%' THEN RAISE EXCEPTION 'v8 C6 guard still present'; END IF;
  IF src NOT LIKE '%I1_equipment_without_device_binding%' THEN RAISE EXCEPTION 'v8 checks missing (I1)'; END IF;
  RAISE NOTICE 'v9 C6 live, md5 %', md5(src);
END $v$;
ROLLBACK;
