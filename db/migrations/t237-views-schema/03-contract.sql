-- t237 P-views · CONTRACT — drop the 15 public shim views once every pool has
-- recycled onto the widened path (pgbouncer restarted) and the gate confirmed the
-- moved views resolve from serving/customer_reports. No dual-DB reader resolves these
-- view names against prod (they are DEST-only report/refdata views), so no shim needs
-- to survive. NOTE: serving.events_timeline_full reads `v_events_2` unqualified and now
-- resolves it via `serving` on the path — the shim is safe to drop.
--
-- Final state: the 15 views live solely in serving/customer_reports; public holds none
-- of the 15 names. Intra-set dependents (v_sap_*, v_entities_per_user_role_operator)
-- bind their bases by OID and are unaffected by the shim drop.
BEGIN;
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
COMMIT;
