-- t275 — complete schema documentation (COMMENT ON SCHEMA for every app schema).
--
-- Supersedes t-tidy-schema-docs: re-asserts every medallion/app schema comment
-- (idempotent), corrects the renamed auth→identity, and fills the two that the
-- "why does public still exist" audit found undocumented (customer_reports, public).
-- COMMENT ON SCHEMA is idempotent and shows in psql \dn+, pgweb, and CloudBeaver.

-- ── Medallion data layers ────────────────────────────────────────────────────
COMMENT ON SCHEMA bronze  IS 'Medallion BRONZE — immutable append-only raw landing: equipment_values_raw/events_raw (ADR-0036, flag-gated BRONZE_RAW_APPEND), box_scans (barcode scan ledger, no_mutate trigger). Never UPDATE/DELETE.';
COMMENT ON SCHEMA silver  IS 'Medallion SILVER — merged/deduped facts (equipment_values/events, latest-wins UPSERT) + minute/hour metric & categorical rollup caggs + current-state live grains (equipment_live_*, area/site_live_*) + the data_quality_event alarm plane.';
COMMENT ON SCHEMA gold    IS 'Medallion GOLD — computed OEE grains (equipment_oee_{shift,hourly,daily,weekly,monthly}, area) + per-PO aggregates (production_orders_runtime, po_box_counter). Consumed by serving/bi.';

-- ── Conformed reference data ─────────────────────────────────────────────────
COMMENT ON SCHEMA core    IS 'Conformed dimensions (Kimball): enterprises→sites→areas→equipments hierarchy + production_orders, shifts/shift_hours, topic_routing (SparkPlug routing), products/clients, scrap_targets, client_descriptors. The control-plane reference data.';

-- ── Application planes ───────────────────────────────────────────────────────
COMMENT ON SCHEMA identity IS 'Application IDENTITY + authorization (authZ) keyed to Cognito (id_user_cognito): users, user_roles (permissions/super_user), user_screen_config, user_logs (audit). NOT authentication — Cognito holds credentials. Renamed from auth (t247); iam would collide with AWS IAM.';
COMMENT ON SCHEMA config  IS 'Application CONFIG (i18n + labels): translations, tenant_translations, language_packs, pages, dashboard_config, labels, label_formats.';
COMMENT ON SCHEMA ops     IS 'Application OPS (operational plumbing): idempotency_keys, function_execution_log, capture_observations, mirror_replay_cursor/dlq.';

-- ── Serving tier (query surfaces) ────────────────────────────────────────────
COMMENT ON SCHEMA serving IS 'Serving API — security_invoker views/functions read by read-api under the CALLER''s RLS. Programmatic query surface (also fronts the customer_reports pools via config-driven fns).';
COMMENT ON SCHEMA bi      IS 'BI — security_definer + RLS views for Superset (definer-side tenant fence via current_setting(''app.tenant_id'')).';

-- ── External-contract report surface ─────────────────────────────────────────
COMMENT ON SCHEMA customer_reports IS 'External-consumer report / ERP-contract surface (NOT internal, do NOT redesign unilaterally — external systems read these). Pooled tables written by stream-engine report writers keyed by customer_id: sap_data_sync (Neopac SAP, cust-13, German field shape), production_data_sync + shift (Montebello/Incoplast OEE, cust-6), boxes (source for the SAP transform). Column shapes are dictated by the customers'' SAP/ERP integrations. #244 replaced the per-tenant NAMED legacy objects with these generic pools + config-driven serving.* fns.';

-- ── PostgreSQL default schema (NOT an application domain) ─────────────────────
COMMENT ON SCHEMA public IS 'PostgreSQL default schema — NOT an application data domain and cannot be dropped. Holds ONLY: (1) extensions (timescaledb, dblink, btree_gist, pg_stat_statements); (2) knex migration bookkeeping (knex_migrations*); (3) a few not-yet-relocated LIVE objects — scanned_boxes/sample_boxes (edge-api Samples feature), h_* RETURNS-SETOF row-type carriers, and piot_get_*/h_piot_get_downtimes_* fns still called bare by read-api. Last in search_path (fallback only). All application data lives in bronze/silver/gold/core/identity/config/ops/serving/bi/customer_reports.';
