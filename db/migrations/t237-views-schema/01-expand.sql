-- t237 P-views · EXPAND — move the 15 remaining public *views* to their real homes:
--   10 operator/refdata views → `serving`, 5 SAP/cust_13 report views → `customer_reports`.
-- Leave a same-named auto-updatable public shim view over each moved base to bridge
-- in-flight (unqualified) pooled connections until pgbouncer recycles onto the widened
-- search_path (02). Views are metadata: SET SCHEMA is a catalog-only OID flip.
--
-- Reversibility: fully symmetric (no data; views are derived). See rollback.sql.
--
-- Consumer census (why this phase is DEPLOY-FREE — no Go/service change):
--   * read-api reads ALL 15 UNQUALIFIED (main.go v_operator_*, datasets.go
--     v_entities/v_menu/v_report_downtimes, external*.go v_13_/v_sap_/v_piot_) — no
--     `public.v_*` hard-code anywhere → search_path-absorbed once serving +
--     customer_reports join the path (02) and pgbouncer recycles.
--   * stream-engine has 0 real SQL refs (only comments naming equipment_boxes_cust_13 /
--     the retired upsert_equipment_boxes_cust_13 function).
--   * serving.events_timeline_full reads `v_events_2` UNQUALIFIED → absorbed via the
--     path (bridged by the public shim during the recycle window).
--   * Superset repo datasets are all on the `bi` schema; NO bi view/dataset depends on
--     any of the 15 (pg_depend clean) → Superset unaffected.
--   * Intra-set view→view deps (equipment_boxes_cust_13 ← v_sap_*; v_operator_entities_2
--     ← v_entities_per_user_role_operator; v_sap_*_deb ← v_sap_*) bind by OID and all
--     move together → dependents stay valid across the flip.
--   * All 15 views are owner=postgres, security_invoker=off (definer/superuser; tenant
--     scoping is the read-api WHERE id_enterprise=$1, not view RLS) → plain shims match.
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE SCHEMA IF NOT EXISTS serving;
CREATE SCHEMA IF NOT EXISTS customer_reports;

-- Move bases (catalog-only OID flip; dependents follow by OID regardless of order).
ALTER VIEW public.production_information               SET SCHEMA serving;
ALTER VIEW public.v_entities_per_user_role             SET SCHEMA serving;
ALTER VIEW public.v_entities_per_user_role_operator    SET SCHEMA serving;
ALTER VIEW public.v_events_2                            SET SCHEMA serving;
ALTER VIEW public.v_menu_per_user_role                 SET SCHEMA serving;
ALTER VIEW public.v_operator_entities_2                SET SCHEMA serving;
ALTER VIEW public.v_operator_po_details_3              SET SCHEMA serving;
ALTER VIEW public.v_operator_po_list_setup_4           SET SCHEMA serving;
ALTER VIEW public.v_po_box_totals                      SET SCHEMA serving;
ALTER VIEW public.v_report_downtimes                   SET SCHEMA serving;

ALTER VIEW public.equipment_boxes_cust_13              SET SCHEMA customer_reports;
ALTER VIEW public.v_13_site_deb_sap_report             SET SCHEMA customer_reports;
ALTER VIEW public.v_piot_production_data_sync_cust6    SET SCHEMA customer_reports;
ALTER VIEW public.v_sap_report_data_sync_customer_13   SET SCHEMA customer_reports;
ALTER VIEW public.v_sap_report_data_sync_customer_13_deb SET SCHEMA customer_reports;

-- Same-named public shim views bridge any connection still on the old path (no serving/
-- customer_reports yet) until pgbouncer recycles. Each references only its own moved base.
CREATE VIEW public.production_information               AS SELECT * FROM serving.production_information;
CREATE VIEW public.v_entities_per_user_role             AS SELECT * FROM serving.v_entities_per_user_role;
CREATE VIEW public.v_entities_per_user_role_operator    AS SELECT * FROM serving.v_entities_per_user_role_operator;
CREATE VIEW public.v_events_2                            AS SELECT * FROM serving.v_events_2;
CREATE VIEW public.v_menu_per_user_role                 AS SELECT * FROM serving.v_menu_per_user_role;
CREATE VIEW public.v_operator_entities_2                AS SELECT * FROM serving.v_operator_entities_2;
CREATE VIEW public.v_operator_po_details_3              AS SELECT * FROM serving.v_operator_po_details_3;
CREATE VIEW public.v_operator_po_list_setup_4           AS SELECT * FROM serving.v_operator_po_list_setup_4;
CREATE VIEW public.v_po_box_totals                      AS SELECT * FROM serving.v_po_box_totals;
CREATE VIEW public.v_report_downtimes                   AS SELECT * FROM serving.v_report_downtimes;

CREATE VIEW public.equipment_boxes_cust_13              AS SELECT * FROM customer_reports.equipment_boxes_cust_13;
CREATE VIEW public.v_13_site_deb_sap_report             AS SELECT * FROM customer_reports.v_13_site_deb_sap_report;
CREATE VIEW public.v_piot_production_data_sync_cust6    AS SELECT * FROM customer_reports.v_piot_production_data_sync_cust6;
CREATE VIEW public.v_sap_report_data_sync_customer_13   AS SELECT * FROM customer_reports.v_sap_report_data_sync_customer_13;
CREATE VIEW public.v_sap_report_data_sync_customer_13_deb AS SELECT * FROM customer_reports.v_sap_report_data_sync_customer_13_deb;

COMMIT;
