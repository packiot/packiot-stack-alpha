-- t278f rollback — restore the t275 wording for the 3 schemas.
COMMENT ON SCHEMA bi IS 'BI — security_definer + RLS views for Superset (definer-side tenant fence via current_setting(''app.tenant_id'')).';
COMMENT ON SCHEMA serving IS 'Serving API — security_invoker views/functions read by read-api under the CALLER''s RLS. Programmatic query surface (also fronts the customer_reports pools via config-driven fns).';
COMMENT ON SCHEMA ops IS 'Application OPS (operational plumbing): idempotency_keys, function_execution_log, capture_observations, mirror_replay_cursor/dlq.';
