-- t244 Phase-5 (PARTIAL) · drop the fully-replaced INTERNAL "06" family
-- (Montebello/Incoplast, ent 6). Replaced by serving.{report_shift,data_sync,
-- downtime_sync,production_data_sync}; read-api + stream-engine repointed + deployed
-- (0 errors); back4-api (the only other consumer) is NOT on the staging box.
-- DROP…RESTRICT = the zero-DB-dependent proof (#235 method).
--
-- KEPT (serving.* still leans on them — residual debt, separate follow-up):
--   report_shift_enterprsie_06 (serving.data_sync joins it), v_13_overview_* stubs
--   (serving.overview_*). HELD (Neopac external SAP contract, gated): all "13"/SAP
--   objects (v_sap_report_data_sync_customer_13(_deb), v_13_site_deb_sap_report,
--   equipment_boxes_cust_13). PROD drop of everything stays gated.
BEGIN;
DROP VIEW  IF EXISTS customer_reports.v_piot_production_data_sync_cust6;         -- → serving.production_data_sync
DROP FUNCTION IF EXISTS public.get_data_sync_enterprsie_06b(integer);           -- → serving.data_sync
DROP FUNCTION IF EXISTS public.get_downtime_sync_enterprsie_06();               -- → serving.downtime_sync
DROP FUNCTION IF EXISTS public.get_report_shift_enterprsie_06c(date, date);     -- → serving.report_shift
DROP TABLE IF EXISTS public.data_sync_enterprise_06b RESTRICT;                  -- SETOF carrier (dead after its fn)
DROP TABLE IF EXISTS public.downtime_sync_enterprise_06 RESTRICT;               -- SETOF carrier
DROP TABLE IF EXISTS public.production_data_sync_enterprise_06 RESTRICT;        -- old sync06 target (now writes the pool)
COMMIT;
