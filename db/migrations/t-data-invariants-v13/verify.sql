-- verify for t-data-invariants-v13. Read-only: RAISEs unless the live procedure carries the every-grain O3 on top of v12.
\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
DO $v$
DECLARE src text := (SELECT prosrc FROM pg_proc WHERE oid = 'ops.job_data_invariants(int, jsonb)'::regprocedure);
BEGIN
  IF src NOT LIKE '%FROM gold.equipment_oee_daily d JOIN core.equipments q USING (id_equipment)%' THEN RAISE EXCEPTION 'v13 O3 day grain not live (ops.job_data_invariants)'; END IF;
  IF src NOT LIKE '%FROM gold.equipment_oee_monthly m JOIN core.equipments q USING (id_equipment)%' THEN RAISE EXCEPTION 'v13 O3 month grain not live'; END IF;
  IF src NOT LIKE '%b1.ts_value <= now() AND b1.ts_value > now() - interval ''7 days''%' THEN RAISE EXCEPTION 'v12 K8 settled-day cutoff missing — v13 must be v12 + O3'; END IF;
  IF src NOT LIKE '%K7_day_time_gt_day_length%' THEN RAISE EXCEPTION 'v10 K7 missing'; END IF;
  IF src NOT LIKE '%I1_equipment_without_device_binding%' THEN RAISE EXCEPTION 'v8 checks missing (I1)'; END IF;
  RAISE NOTICE 'v13 O3 every-grain live, md5 %', md5(src);
END $v$;
ROLLBACK;
-- After the next run (every 30 min) — expected: observed = 0, ok = t (the stranded-flag sweep clears every counted row hourly).
SELECT check_id, run_at, observed, ok FROM ops.data_invariant_latest WHERE check_id = 'O3_stranded_flags';
