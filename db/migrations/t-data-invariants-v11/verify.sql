-- verify for t-data-invariants-v11. Read-only: RAISEs unless the live procedure carries K8 on top of v10.
\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
DO $v$
DECLARE src text := (SELECT prosrc FROM pg_proc WHERE oid = 'ops.job_data_invariants(int, jsonb)'::regprocedure);
BEGIN
  IF src NOT LIKE '%K8_day_hour_rows_ne_day_hours%' THEN RAISE EXCEPTION 'v11 K8 not live (ops.job_data_invariants)'; END IF;
  IF src NOT LIKE '%K7_day_time_gt_day_length%' THEN RAISE EXCEPTION 'v10 K7 missing — v11 must be v10 + K8'; END IF;
  IF src NOT LIKE '%sv.g_bkts = sv.bkts%' THEN RAISE EXCEPTION 'v9 C6 missing'; END IF;
  IF src NOT LIKE '%I1_equipment_without_device_binding%' THEN RAISE EXCEPTION 'v8 checks missing (I1)'; END IF;
  RAISE NOTICE 'v11 K8 live, md5 %', md5(src);
END $v$;
ROLLBACK;
-- After the next run (every 30 min) — expected: one row per tenant in scope; ok = f for the off-the-hour
-- tenants (3, 2000003, 4, 119, 120) until the hourly label repair runs, then ok = t everywhere.
SELECT 'K8 latest rows (>= 1)', count(*) FROM ops.data_invariant_latest WHERE check_id = 'K8_day_hour_rows_ne_day_hours';
SELECT id_enterprise, observed, ok, detail FROM ops.data_invariant_latest WHERE check_id = 'K8_day_hour_rows_ne_day_hours' ORDER BY 1;
