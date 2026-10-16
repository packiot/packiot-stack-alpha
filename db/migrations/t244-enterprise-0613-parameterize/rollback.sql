-- ============================================================================
-- t244 — enterprise-06/13 parameterization redesign :: Phase 0+1 ROLLBACK
-- Drops every serving.* object + pool table created by 01-expand.sql and
-- reverses the config seed. Legacy objects were never touched, so this fully
-- restores the pre-migration state. Safe to run repeatedly (IF EXISTS guards).
-- ============================================================================
SET client_min_messages = warning;

-- Phase 1 :: generic compute functions
DROP FUNCTION IF EXISTS serving.data_sync(integer, integer);
DROP FUNCTION IF EXISTS serving.downtime_sync(integer);
DROP FUNCTION IF EXISTS serving.report_shift(integer, date, date);
DROP FUNCTION IF EXISTS serving.production_data_sync(integer);
DROP FUNCTION IF EXISTS serving.sap_site_report(integer, integer);
DROP FUNCTION IF EXISTS serving.sap_report_data_sync(integer);
DROP FUNCTION IF EXISTS serving.overview_takt(integer);
DROP FUNCTION IF EXISTS serving.overview_scrap_rate(integer);

-- Phase 1 :: pool target table (empty on staging; DROP is lossless there — on prod
-- verify 0 rows / no dependents before running, per the #235 DROP...RESTRICT method).
DROP TABLE IF EXISTS customer_reports.production_data_sync;

-- Phase 0 :: config resolver + accessors
DROP FUNCTION IF EXISTS serving.report_cutover(integer);
DROP FUNCTION IF EXISTS serving.report_areas_excluded(integer);
DROP FUNCTION IF EXISTS serving.report_sites(integer, text);
DROP FUNCTION IF EXISTS serving.report_tz(integer, text);
DROP FUNCTION IF EXISTS serving.report_config(integer);

-- Phase 0 :: config seed
-- Strip the 'reports' sub-object we added (non-destructive to other descriptor keys)...
UPDATE core.client_descriptors
   SET descriptor = descriptor - 'reports', updated_at = now()
 WHERE id_enterprise IN (6, 13) AND descriptor ? 'reports';
-- ...and delete any minimal rows this migration itself created (reports was the sole key).
DELETE FROM core.client_descriptors
 WHERE id_enterprise IN (6, 13) AND status = 'draft' AND descriptor = '{}'::jsonb;
