-- verify for t-data-invariants-v12. Read-only: RAISEs unless the live procedure carries the settled-day K8 on top of v11.
\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
DO $v$
DECLARE src text := (SELECT prosrc FROM pg_proc WHERE oid = 'ops.job_data_invariants(int, jsonb)'::regprocedure);
BEGIN
  IF src NOT LIKE '%b1.ts_value <= now() AND b1.ts_value > now() - interval ''7 days''%' THEN RAISE EXCEPTION 'v12 K8 settled-day cutoff not live (ops.job_data_invariants)'; END IF;
  IF src NOT LIKE '%K8_day_hour_rows_ne_day_hours%' THEN RAISE EXCEPTION 'v11 K8 missing'; END IF;
  IF src NOT LIKE '%K7_day_time_gt_day_length%' THEN RAISE EXCEPTION 'v10 K7 missing — v12 must be v11 + K8 cutoff'; END IF;
  IF src NOT LIKE '%sv.g_bkts = sv.bkts%' THEN RAISE EXCEPTION 'v9 C6 missing'; END IF;
  IF src NOT LIKE '%I1_equipment_without_device_binding%' THEN RAISE EXCEPTION 'v8 checks missing (I1)'; END IF;
  RAISE NOTICE 'v12 K8 settled-day cutoff live, md5 %', md5(src);
END $v$;
ROLLBACK;
-- After the next run (every 30 min) — expected: one row per tenant in scope, ok = t also between 00:00 UTC
-- and the end of the tenants' production day (v11 failed there on the still-running day).
SELECT 'K8 latest rows (>= 1)', count(*) FROM ops.data_invariant_latest WHERE check_id = 'K8_day_hour_rows_ne_day_hours';
SELECT id_enterprise, run_at, observed, ok, detail FROM ops.data_invariant_latest WHERE check_id = 'K8_day_hour_rows_ne_day_hours' ORDER BY 1;
