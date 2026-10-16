-- verify for t-data-sync-po-start-date. Read-only. Every line prints label|value; the expected value is in the label.
\set ON_ERROR_STOP 1

SELECT 'V1 serving.data_sync body reads po.ts_start_tz: f',
       position('ts_start_tz' IN prosrc) > 0 FROM pg_proc WHERE oid = 'serving.data_sync(integer, integer)'::regprocedure;
SELECT 'V2 serving.data_sync UpdatedDate falls back to po.ts_start: t',
       position('coalesce(po.ts_start,po.last_update,eqvs.ts_creation)' IN prosrc) > 0
  FROM pg_proc WHERE oid = 'serving.data_sync(integer, integer)'::regprocedure;
-- the RETURNS TABLE contract sync06 inserts from must be byte-identical to t244c
SELECT 'V3 result signature unchanged: t',
       pg_get_function_result('serving.data_sync(integer, integer)'::regprocedure) =
       'TABLE(site character varying, line character varying, shift character varying, shiftstartdate timestamp with time zone, job bigint, item character varying, totalavailablehrsinmin numeric, dtimehrsplannedinmin numeric, dtimehrsunplannedinmin numeric, unplanneddt_proinmin numeric, unplanneddt_resinmin numeric, unplanneddt_mntinmin numeric, setuphoursinmin numeric, runhoursinmin numeric, presscnt bigint, packcnt bigint, jobstatus character varying, jobstartdate timestamp with time zone, jobcompleteddate timestamp with time zone, createddate timestamp with time zone, updateddate timestamp with time zone, packiotid character varying, supervisorapproval boolean, supervisorapproveddate timestamp with time zone, supervisornotes jsonb, nm_user_validation character varying, id_validation bigint, ts_creation timestamp with time zone, to_delete boolean, last_update timestamp with time zone, packml_topic character varying, last_update_prod_data timestamp with time zone)';
-- what still mentions the *_tz columns inside the database (functions + views); the drop step must reach 0 here
SELECT 'V4 in-DB functions still mentioning ts_start_tz/ts_end_tz: 0',
       count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND p.prosrc ~ 'ts_(start|end)_tz';
SELECT 'V5 views depending on core.production_orders.ts_start_tz/ts_end_tz: 0',
       count(DISTINCT v.ev_class) FROM pg_depend d
       JOIN pg_rewrite v ON v.oid = d.objid
       JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
       WHERE d.refobjid = 'core.production_orders'::regclass AND a.attname IN ('ts_start_tz', 'ts_end_tz')
         AND v.ev_class <> 'core.production_orders'::regclass;
