-- ============================================================================
-- t244c :: Piece A+B contract — DROP residual legacy objects (RESTRICT).
-- Safe ONLY after 01/02/03 made every serving.* fn self-contained (proven:
-- 0 serving fns reference any of these). RESTRICT order: independents first,
-- then the SAP view dependency chain top-down (main13 -> _deb -> equipment_boxes)
-- so no drop ever sees a live dependent. IF EXISTS makes this re-runnable.
-- ============================================================================
SET client_min_messages = warning;

-- Piece B: empty never-computed stub tables (no writer, no dependents)
DROP TABLE IF EXISTS public.v_13_overview_takt RESTRICT;
DROP TABLE IF EXISTS public.v_13_overview_partial_scrap_rate RESTRICT;

-- Piece A: orphaned SAP report views (read-api repointed to serving.*)
DROP VIEW IF EXISTS customer_reports.v_13_site_deb_sap_report RESTRICT;
DROP VIEW IF EXISTS customer_reports.v_sap_report_data_sync_customer_13 RESTRICT;      -- top of chain (no dependents)
DROP VIEW IF EXISTS customer_reports.v_sap_report_data_sync_customer_13_deb RESTRICT;  -- now inlined into serving.sap_report_data_sync
DROP VIEW IF EXISTS customer_reports.equipment_boxes_cust_13 RESTRICT;                 -- now inlined to customer_reports.boxes
