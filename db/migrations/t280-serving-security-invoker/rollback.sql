-- t280 rollback — restore definer semantics on the serving.* views.
-- (security_invoker=off is the PG default; this reverts the co-enforcement flip.)
ALTER VIEW serving.production_information            SET (security_invoker = off);
ALTER VIEW serving.v_entities_per_user_role          SET (security_invoker = off);
ALTER VIEW serving.v_entities_per_user_role_operator SET (security_invoker = off);
ALTER VIEW serving.v_events_2                        SET (security_invoker = off);
ALTER VIEW serving.v_menu_per_user_role              SET (security_invoker = off);
ALTER VIEW serving.v_operator_entities_2             SET (security_invoker = off);
ALTER VIEW serving.v_operator_po_details_3           SET (security_invoker = off);
ALTER VIEW serving.v_operator_po_list_setup_4        SET (security_invoker = off);
ALTER VIEW serving.v_report_downtimes                SET (security_invoker = off);
