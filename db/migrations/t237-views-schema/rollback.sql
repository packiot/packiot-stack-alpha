-- t237 P-views · ROLLBACK — symmetric reverse of expand/contract (no data at risk;
-- views are derived). Safe whether or not the contract already dropped the shims.
BEGIN;
SET LOCAL lock_timeout = '3s';

-- Drop any surviving shim views so the names are free in public.
DROP VIEW IF EXISTS public.production_information;
DROP VIEW IF EXISTS public.v_entities_per_user_role;
DROP VIEW IF EXISTS public.v_entities_per_user_role_operator;
DROP VIEW IF EXISTS public.v_events_2;
DROP VIEW IF EXISTS public.v_menu_per_user_role;
DROP VIEW IF EXISTS public.v_operator_entities_2;
DROP VIEW IF EXISTS public.v_operator_po_details_3;
DROP VIEW IF EXISTS public.v_operator_po_list_setup_4;
DROP VIEW IF EXISTS public.v_po_box_totals;
DROP VIEW IF EXISTS public.v_report_downtimes;
DROP VIEW IF EXISTS public.equipment_boxes_cust_13;
DROP VIEW IF EXISTS public.v_13_site_deb_sap_report;
DROP VIEW IF EXISTS public.v_piot_production_data_sync_cust6;
DROP VIEW IF EXISTS public.v_sap_report_data_sync_customer_13;
DROP VIEW IF EXISTS public.v_sap_report_data_sync_customer_13_deb;

-- Move the bases back to public (OID-safe; dependents follow).
ALTER VIEW serving.production_information               SET SCHEMA public;
ALTER VIEW serving.v_entities_per_user_role             SET SCHEMA public;
ALTER VIEW serving.v_entities_per_user_role_operator    SET SCHEMA public;
ALTER VIEW serving.v_events_2                            SET SCHEMA public;
ALTER VIEW serving.v_menu_per_user_role                 SET SCHEMA public;
ALTER VIEW serving.v_operator_entities_2                SET SCHEMA public;
ALTER VIEW serving.v_operator_po_details_3              SET SCHEMA public;
ALTER VIEW serving.v_operator_po_list_setup_4           SET SCHEMA public;
ALTER VIEW serving.v_po_box_totals                      SET SCHEMA public;
ALTER VIEW serving.v_report_downtimes                   SET SCHEMA public;

ALTER VIEW customer_reports.equipment_boxes_cust_13              SET SCHEMA public;
ALTER VIEW customer_reports.v_13_site_deb_sap_report             SET SCHEMA public;
ALTER VIEW customer_reports.v_piot_production_data_sync_cust6    SET SCHEMA public;
ALTER VIEW customer_reports.v_sap_report_data_sync_customer_13   SET SCHEMA public;
ALTER VIEW customer_reports.v_sap_report_data_sync_customer_13_deb SET SCHEMA public;

COMMIT;

-- Narrow the search_path back to the pre-P-views value.
ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, barcode, app, public;

-- Then restart stack-pgbouncer-1 to recycle pools onto the narrowed path.
