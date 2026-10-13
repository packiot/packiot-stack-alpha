-- verify for t-data-invariants-v10. Read-only: RAISEs unless the live procedure carries K7 on top of v9.
\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
DO $v$
DECLARE src text := (SELECT prosrc FROM pg_proc WHERE oid = 'ops.job_data_invariants(int, jsonb)'::regprocedure);
BEGIN
  IF src NOT LIKE '%K7_day_time_gt_day_length%' THEN RAISE EXCEPTION 'v10 K7 not live (ops.job_data_invariants)'; END IF;
  IF src NOT LIKE '%sv.g_bkts = sv.bkts%' THEN RAISE EXCEPTION 'v9 C6 missing — v10 must be v9 + K7'; END IF;
  IF src NOT LIKE '%I1_equipment_without_device_binding%' THEN RAISE EXCEPTION 'v8 checks missing (I1)'; END IF;
  RAISE NOTICE 'v10 K7 live, md5 %', md5(src);
END $v$;
ROLLBACK;
-- After the next run (every 30 min) — expected: one row per tenant in scope, ok = t unless a day exceeds its length.
SELECT 'K7 latest rows (>= 1)', count(*) FROM ops.data_invariant_latest WHERE check_id = 'K7_day_time_gt_day_length';
