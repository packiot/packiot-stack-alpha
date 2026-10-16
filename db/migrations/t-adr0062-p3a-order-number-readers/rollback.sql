-- rollback t-adr0062-p3a-order-number-readers — drop each wrapper, give the base its public name back,
-- and point v3's fallback at downtime_events_v2 again. Bodies and grants of the bases were never changed.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $rb$
DECLARE r record; def text;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS base_sig, p.proname AS base, oidvectortypes(p.proargtypes) AS args
             FROM pg_proc p
            WHERE p.pronamespace = 'serving'::regnamespace
              AND p.proname IN ('downtime_events_base','downtime_events_v2_base','downtime_events_v3_base',
                                'production_orders_base','production_orders_with_runtimes_base',
                                'overview_job_info_base','data_sync_base','downtime_sync_base') LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS serving.%I(%s)', left(r.base, -5), r.args);
    EXECUTE format('ALTER FUNCTION %s RENAME TO %I', r.base_sig, left(r.base, -5));
  END LOOP;
  IF to_regproc('serving.downtime_events_v3') IS NOT NULL THEN
    def := pg_get_functiondef('serving.downtime_events_v3(integer,text,text,text,text,timestamp,timestamp,boolean)'::regprocedure);
    IF def ~ 'serving\.downtime_events_v2_base\(' THEN
      EXECUTE replace(def, 'serving.downtime_events_v2_base(', 'serving.downtime_events_v2(');
    END IF;
  END IF;
END
$rb$;

COMMIT;
