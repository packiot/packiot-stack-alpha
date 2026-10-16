-- t278d — ROLLBACK: clears every COMMENT set by 01-comments.sql (identity, config, ops).
-- One `IS NULL;` per COMMENT. Idempotent, non-destructive, staging.
-- Scope: ONLY schemas identity, config, ops. Grounded in read-api, stream-engine,
-- sparkplug-decoder, mirror-worker-go and edge-api source (see report).

-- =====================================================================
-- SCHEMAS
-- =====================================================================
COMMENT ON SCHEMA identity IS NULL;
COMMENT ON SCHEMA config IS NULL;
COMMENT ON SCHEMA ops IS NULL;

-- =====================================================================
-- identity
-- =====================================================================

COMMENT ON TABLE identity.users IS NULL;
COMMENT ON COLUMN identity.users.id_user IS NULL;
COMMENT ON COLUMN identity.users.user_email IS NULL;
COMMENT ON COLUMN identity.users.user_name IS NULL;
COMMENT ON COLUMN identity.users.phone_number IS NULL;
COMMENT ON COLUMN identity.users.id_enterprise IS NULL;
COMMENT ON COLUMN identity.users.user_roles IS NULL;
COMMENT ON COLUMN identity.users.user_menu IS NULL;
COMMENT ON COLUMN identity.users.internal_user IS NULL;
COMMENT ON COLUMN identity.users.active IS NULL;
COMMENT ON COLUMN identity.users.id_user_cognito IS NULL;
COMMENT ON COLUMN identity.users.timezone IS NULL;
COMMENT ON COLUMN identity.users.languages IS NULL;

COMMENT ON TABLE identity.user_roles IS NULL;
COMMENT ON COLUMN identity.user_roles.id_user_role IS NULL;
COMMENT ON COLUMN identity.user_roles.nm_user_role IS NULL;
COMMENT ON COLUMN identity.user_roles.id_enterprise IS NULL;
COMMENT ON COLUMN identity.user_roles.permissions IS NULL;
COMMENT ON COLUMN identity.user_roles.super_user IS NULL;

COMMENT ON TABLE identity.user_screen_config IS NULL;
COMMENT ON COLUMN identity.user_screen_config.id_enterprise IS NULL;
COMMENT ON COLUMN identity.user_screen_config.id_user IS NULL;
COMMENT ON COLUMN identity.user_screen_config.screen IS NULL;
COMMENT ON COLUMN identity.user_screen_config.config IS NULL;
COMMENT ON COLUMN identity.user_screen_config.updated_at IS NULL;

COMMENT ON TABLE identity.user_logs IS NULL;
COMMENT ON COLUMN identity.user_logs.id_user_logs IS NULL;
COMMENT ON COLUMN identity.user_logs.ts_event IS NULL;
COMMENT ON COLUMN identity.user_logs.ts_log IS NULL;
COMMENT ON COLUMN identity.user_logs.id_enterprise IS NULL;
COMMENT ON COLUMN identity.user_logs.id_equipment IS NULL;
COMMENT ON COLUMN identity.user_logs.nm_user IS NULL;
COMMENT ON COLUMN identity.user_logs.cd_user IS NULL;
COMMENT ON COLUMN identity.user_logs.category IS NULL;
COMMENT ON COLUMN identity.user_logs.subcategory IS NULL;
COMMENT ON COLUMN identity.user_logs.description IS NULL;
COMMENT ON COLUMN identity.user_logs.ip IS NULL;
COMMENT ON COLUMN identity.user_logs.payload IS NULL;
COMMENT ON COLUMN identity.user_logs.id_site IS NULL;
COMMENT ON COLUMN identity.user_logs.id_area IS NULL;

-- =====================================================================
-- config
-- =====================================================================

COMMENT ON TABLE config.translations IS NULL;
COMMENT ON COLUMN config.translations.language_tag IS NULL;
COMMENT ON COLUMN config.translations.app IS NULL;
COMMENT ON COLUMN config.translations.namespace IS NULL;
COMMENT ON COLUMN config.translations.key IS NULL;
COMMENT ON COLUMN config.translations.value IS NULL;
COMMENT ON COLUMN config.translations.updated_at IS NULL;
COMMENT ON COLUMN config.translations.updated_by IS NULL;

COMMENT ON TABLE config.tenant_translations IS NULL;
COMMENT ON COLUMN config.tenant_translations.id_enterprise IS NULL;
COMMENT ON COLUMN config.tenant_translations.language_tag IS NULL;
COMMENT ON COLUMN config.tenant_translations.app IS NULL;
COMMENT ON COLUMN config.tenant_translations.namespace IS NULL;
COMMENT ON COLUMN config.tenant_translations.key IS NULL;
COMMENT ON COLUMN config.tenant_translations.value IS NULL;
COMMENT ON COLUMN config.tenant_translations.updated_at IS NULL;
COMMENT ON COLUMN config.tenant_translations.updated_by IS NULL;

COMMENT ON TABLE config.language_packs IS NULL;
COMMENT ON COLUMN config.language_packs.language_tag IS NULL;
COMMENT ON COLUMN config.language_packs.id_language_pack IS NULL;
COMMENT ON COLUMN config.language_packs.language_pack_desktop IS NULL;
COMMENT ON COLUMN config.language_packs.language_pack_mobile IS NULL;
COMMENT ON COLUMN config.language_packs.language_pack_operator IS NULL;
COMMENT ON COLUMN config.language_packs.language_pack_overview IS NULL;
COMMENT ON COLUMN config.language_packs.language_pack_operator40 IS NULL;

COMMENT ON TABLE config.pages IS NULL;
COMMENT ON COLUMN config.pages.id_page IS NULL;
COMMENT ON COLUMN config.pages.list_of_enterprises IS NULL;
COMMENT ON COLUMN config.pages.page_info IS NULL;
COMMENT ON COLUMN config.pages.default_piot_page IS NULL;

COMMENT ON TABLE config.dashboard_config IS NULL;
COMMENT ON COLUMN config.dashboard_config.id_enterprise IS NULL;
COMMENT ON COLUMN config.dashboard_config.dashboard_id IS NULL;
COMMENT ON COLUMN config.dashboard_config.config IS NULL;
COMMENT ON COLUMN config.dashboard_config.version IS NULL;
COMMENT ON COLUMN config.dashboard_config.updated_at IS NULL;

COMMENT ON TABLE config.labels IS NULL;
COMMENT ON COLUMN config.labels.id_label IS NULL;
COMMENT ON COLUMN config.labels.id_enterprise IS NULL;
COMMENT ON COLUMN config.labels.id_equipment IS NULL;
COMMENT ON COLUMN config.labels.name IS NULL;
COMMENT ON COLUMN config.labels.template IS NULL;

COMMENT ON TABLE config.label_formats IS NULL;
COMMENT ON COLUMN config.label_formats.id_enterprise IS NULL;
COMMENT ON COLUMN config.label_formats.label_key IS NULL;
COMMENT ON COLUMN config.label_formats.archetype IS NULL;
COMMENT ON COLUMN config.label_formats.order_field IS NULL;
COMMENT ON COLUMN config.label_formats.qty_field IS NULL;
COMMENT ON COLUMN config.label_formats.workcenter_field IS NULL;
COMMENT ON COLUMN config.label_formats.date_field IS NULL;
COMMENT ON COLUMN config.label_formats.time_field IS NULL;
COMMENT ON COLUMN config.label_formats.tz IS NULL;
COMMENT ON COLUMN config.label_formats.bucket IS NULL;

-- =====================================================================
-- ops
-- =====================================================================

COMMENT ON TABLE ops.idempotency_keys IS NULL;
COMMENT ON COLUMN ops.idempotency_keys.idempotency_key IS NULL;
COMMENT ON COLUMN ops.idempotency_keys.response_status IS NULL;
COMMENT ON COLUMN ops.idempotency_keys.response_body IS NULL;
COMMENT ON COLUMN ops.idempotency_keys.created_at IS NULL;

COMMENT ON TABLE ops.capture_observations IS NULL;
COMMENT ON COLUMN ops.capture_observations.id_capture_observation IS NULL;
COMMENT ON COLUMN ops.capture_observations.id_enterprise IS NULL;
COMMENT ON COLUMN ops.capture_observations.topic IS NULL;
COMMENT ON COLUMN ops.capture_observations.count_index IS NULL;
COMMENT ON COLUMN ops.capture_observations.metric_suffix IS NULL;
COMMENT ON COLUMN ops.capture_observations.first_seen_ts IS NULL;
COMMENT ON COLUMN ops.capture_observations.last_seen_ts IS NULL;
COMMENT ON COLUMN ops.capture_observations.observed_count IS NULL;

COMMENT ON TABLE ops.mirror_replay_cursor IS NULL;
COMMENT ON COLUMN ops.mirror_replay_cursor.source IS NULL;
COMMENT ON COLUMN ops.mirror_replay_cursor.last_log_id IS NULL;
COMMENT ON COLUMN ops.mirror_replay_cursor.last_run_at IS NULL;

COMMENT ON TABLE ops.mirror_replay_dlq IS NULL;
COMMENT ON COLUMN ops.mirror_replay_dlq.id IS NULL;
COMMENT ON COLUMN ops.mirror_replay_dlq.source IS NULL;
COMMENT ON COLUMN ops.mirror_replay_dlq.source_log_id IS NULL;
COMMENT ON COLUMN ops.mirror_replay_dlq.category IS NULL;
COMMENT ON COLUMN ops.mirror_replay_dlq.subcategory IS NULL;
COMMENT ON COLUMN ops.mirror_replay_dlq.payload IS NULL;
COMMENT ON COLUMN ops.mirror_replay_dlq.error IS NULL;
COMMENT ON COLUMN ops.mirror_replay_dlq.retry_attempts IS NULL;
COMMENT ON COLUMN ops.mirror_replay_dlq.last_retry_at IS NULL;
COMMENT ON COLUMN ops.mirror_replay_dlq.created_at IS NULL;
