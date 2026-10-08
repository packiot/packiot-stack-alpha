-- rollback t-adr0062-p3b-report-label-safe-cast — put each pre body back under its public name.
-- core.try_int4/try_int8 stay unless nothing uses them (stream-engine sap13_body.sql does once deployed:
-- roll that back first, then drop them by hand).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $rb$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS pre_sig, p.proname AS pre, oidvectortypes(p.proargtypes) AS args
             FROM pg_proc p
            WHERE p.pronamespace = 'serving'::regnamespace
              AND p.proname IN ('report_shift_pre_p3b', 'sap_site_report_pre_p3b', 'sap_report_data_sync_pre_p3b') LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS serving.%I(%s)', left(r.pre, -8), r.args);
    EXECUTE format('ALTER FUNCTION %s RENAME TO %I', r.pre_sig, left(r.pre, -8));
  END LOOP;
END
$rb$;

COMMIT;
