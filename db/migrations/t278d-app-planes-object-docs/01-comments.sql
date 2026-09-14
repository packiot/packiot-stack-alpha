-- t278d — object documentation for the application "planes": identity, config, ops.
-- COMMENT ON TABLE + COLUMN only. Idempotent, non-destructive, staging.
-- Scope: ONLY schemas identity, config, ops. Grounded in read-api, stream-engine,
-- sparkplug-decoder, mirror-worker-go and edge-api source (see report).

-- =====================================================================
-- SCHEMAS
-- =====================================================================
COMMENT ON SCHEMA identity IS 'Application authorization + user profile plane, keyed to AWS Cognito (renamed from `auth` in t247). This is domain authZ, NOT authN — Cognito holds credentials; identity.users.id_user_cognito is the link. Distinct from AWS IAM (cloud-resource layer).';
COMMENT ON SCHEMA config IS 'Tenant configuration plane: i18n (translations/tenant_translations/language_packs), UI page catalog, dashboard baselines, and barcode label templates/format descriptors.';
COMMENT ON SCHEMA ops IS 'Operational plumbing plane: HTTP idempotency cache, live-capture observations (ADR-0045), and the prod->staging mirror-replay cursor + dead-letter queue.';

-- =====================================================================
-- identity
-- =====================================================================

COMMENT ON TABLE identity.users IS 'Application user profiles, keyed to AWS Cognito via id_user_cognito (authZ + profile, NOT credentials). Read by read-api enterprise-config datasets. id_user_firebase was DROPPED (legacy Firebase link, gap at former ordinal 5).';
COMMENT ON COLUMN identity.users.id_user IS 'Surrogate PK (serial). Internal numeric id; the external identity link is id_user_cognito.';
COMMENT ON COLUMN identity.users.user_email IS 'User email address (profile field; not the authoritative identity — see id_user_cognito).';
COMMENT ON COLUMN identity.users.user_name IS 'User display name (profile field).';
COMMENT ON COLUMN identity.users.phone_number IS 'User phone number (profile field).';
COMMENT ON COLUMN identity.users.id_enterprise IS 'Owning tenant (enterprises.id_enterprise). Tenant scope for this user.';
COMMENT ON COLUMN identity.users.user_roles IS 'FK to identity.user_roles.id_user_role — the single role granting this user its permissions/super_user flags. Scalar int despite the plural name.';
COMMENT ON COLUMN identity.users.user_menu IS 'Per-user custom menu/navigation overrides (jsonb). Default {"custom_user": []}.';
COMMENT ON COLUMN identity.users.internal_user IS 'TRUE for Packiot-internal/service accounts (vs. real customer users). Used to exclude internal accounts from tenant-facing views.';
COMMENT ON COLUMN identity.users.active IS 'Soft-delete/enable flag; TRUE = active user.';
COMMENT ON COLUMN identity.users.id_user_cognito IS 'AWS Cognito subject (sub) — the authoritative external identity link. Nullable for legacy/unmigrated rows. This keying is the reason the schema is named identity (Cognito-backed), not auth.';
COMMENT ON COLUMN identity.users.timezone IS 'User-preferred IANA timezone for UI rendering.';
COMMENT ON COLUMN identity.users.languages IS 'User-preferred language tag(s) for i18n resolution.';

COMMENT ON TABLE identity.user_roles IS 'Role definitions: permission set + super-user flag per role, optionally tenant-scoped. Read by read-api (enterprise-config group) to authorize requests; role is server-derived from the verified user, never client-supplied.';
COMMENT ON COLUMN identity.user_roles.id_user_role IS 'Role PK; referenced by identity.users.user_roles.';
COMMENT ON COLUMN identity.user_roles.nm_user_role IS 'Human-readable role name (e.g. admin, operator).';
COMMENT ON COLUMN identity.user_roles.id_enterprise IS 'Owning tenant, or NULL for a global/cross-tenant role.';
COMMENT ON COLUMN identity.user_roles.permissions IS 'jsonb permission map for this role (feature/screen grants).';
COMMENT ON COLUMN identity.user_roles.super_user IS 'TRUE grants elevated/cross-scope access within the tenant.';

COMMENT ON TABLE identity.user_screen_config IS 'Per-user, per-screen UI layout overrides (jsonb). Read/written by read-api /v1/screen-config (GET/PUT) and is the OVERRIDE leg of /v1/dashboard-config (shallow-merged over the config.dashboard_config baseline; override keys win). PK (id_enterprise, id_user, screen).';
COMMENT ON COLUMN identity.user_screen_config.id_enterprise IS 'Tenant fence (server-derived, never client-named — ADR-0027). Default 0.';
COMMENT ON COLUMN identity.user_screen_config.id_user IS 'Owning user identity (text; the Cognito uid / user key), selects a row WITHIN the already-fenced tenant.';
COMMENT ON COLUMN identity.user_screen_config.screen IS 'Screen/dashboard identifier; equals dashboard_id when overriding a dashboard baseline.';
COMMENT ON COLUMN identity.user_screen_config.config IS 'Layout/widget preference document (jsonb, <= 64KB enforced by read-api).';
COMMENT ON COLUMN identity.user_screen_config.updated_at IS 'Last write time (set to now() on upsert).';

COMMENT ON TABLE identity.user_logs IS 'User-action audit trail. edge-api logger.middleware persists one row per mutating request from res.locals.logData (UserLogsDTO {eventType,payload,lineId,enterpriseId}); mapping: category<-eventType, id_equipment<-lineId, nm_user<-userName, payload<-payload, ts_event/ts_log<-timestamp. Extra columns (subcategory, description, id_site, id_area, cd_user, ip) are nullable and not populated by the current edge-api writer. Also the replay TARGET/source for the ops.mirror_* pipeline.';
COMMENT ON COLUMN identity.user_logs.id_user_logs IS 'Surrogate PK (bigserial). The prod counterpart id is what ops.mirror_replay_cursor.last_log_id / mirror_replay_dlq.source_log_id track.';
COMMENT ON COLUMN identity.user_logs.ts_event IS 'Event timestamp (edge-api sets = request time; same value as ts_log).';
COMMENT ON COLUMN identity.user_logs.ts_log IS 'Log-write timestamp (edge-api sets = ts_event). Second timestamp retained from the legacy schema.';
COMMENT ON COLUMN identity.user_logs.id_enterprise IS 'Tenant scope of the action.';
COMMENT ON COLUMN identity.user_logs.id_equipment IS 'Equipment/line the action targeted; edge-api maps this from UserLogsDTO.lineId. Nullable.';
COMMENT ON COLUMN identity.user_logs.nm_user IS 'Acting user name (from UserLogs.userName). Nullable.';
COMMENT ON COLUMN identity.user_logs.cd_user IS 'Legacy numeric user code. Not set by the current edge-api writer (nullable). UNCERTAIN — best guess: legacy user identifier.';
COMMENT ON COLUMN identity.user_logs.category IS 'Action type — edge-api maps this from UserLogsDTO.eventType (e.g. login, upsert-downtime).';
COMMENT ON COLUMN identity.user_logs.subcategory IS 'Finer action classification. Not set by the current edge-api writer (nullable); carried on the mirror DLQ row as category/subcategory of the replayed prod log.';
COMMENT ON COLUMN identity.user_logs.description IS 'Free-text action description. Not populated by the current edge-api writer (nullable).';
COMMENT ON COLUMN identity.user_logs.ip IS 'Source IP of the request. Not populated by the current edge-api writer (nullable).';
COMMENT ON COLUMN identity.user_logs.payload IS 'Full request/action payload (jsonb) from UserLogsDTO.payload.';
COMMENT ON COLUMN identity.user_logs.id_site IS 'Site scope of the action (nullable; not set by current edge-api writer).';
COMMENT ON COLUMN identity.user_logs.id_area IS 'Area scope of the action (nullable; not set by current edge-api writer).';

-- =====================================================================
-- config
-- =====================================================================

COMMENT ON TABLE config.translations IS 'ADR-0048 normalized i18n store: GLOBAL default strings. Keyed (language_tag, app, namespace, key)->value. edge-api i18n DAO UNIONs these (precedence 0) under config.tenant_translations (precedence 1) so a tenant override shadows the global default. Supersedes the config.language_packs jsonb blobs.';
COMMENT ON COLUMN config.translations.language_tag IS 'BCP-47 language tag (e.g. en, pt-BR).';
COMMENT ON COLUMN config.translations.app IS 'Application/surface the string belongs to (e.g. desktop, operator).';
COMMENT ON COLUMN config.translations.namespace IS 'i18next namespace grouping keys within an app. Default ''common''.';
COMMENT ON COLUMN config.translations.key IS 'Translation key within (app, namespace).';
COMMENT ON COLUMN config.translations.value IS 'Translated string.';
COMMENT ON COLUMN config.translations.updated_at IS 'Last upsert time (now()).';
COMMENT ON COLUMN config.translations.updated_by IS 'Actor that last wrote the row (nullable).';

COMMENT ON TABLE config.tenant_translations IS 'ADR-0048 normalized i18n store: PER-TENANT override strings. Same shape as config.translations plus id_enterprise. In edge-api getMergedResource these rows take precedence (pr=1) over global translations (pr=0), resolved via DISTINCT ON (namespace, key). PK (id_enterprise, language_tag, app, namespace, key).';
COMMENT ON COLUMN config.tenant_translations.id_enterprise IS 'Owning tenant whose override this is.';
COMMENT ON COLUMN config.tenant_translations.language_tag IS 'BCP-47 language tag.';
COMMENT ON COLUMN config.tenant_translations.app IS 'Application/surface the string belongs to.';
COMMENT ON COLUMN config.tenant_translations.namespace IS 'i18next namespace. Default ''common''.';
COMMENT ON COLUMN config.tenant_translations.key IS 'Translation key within (app, namespace).';
COMMENT ON COLUMN config.tenant_translations.value IS 'Tenant-overridden translated string.';
COMMENT ON COLUMN config.tenant_translations.updated_at IS 'Last upsert time (now()).';
COMMENT ON COLUMN config.tenant_translations.updated_by IS 'Actor that last wrote the row (nullable).';

COMMENT ON TABLE config.language_packs IS 'LEGACY pre-ADR-0048 i18n: one row per language holding whole-app translation blobs as jsonb (desktop/mobile/operator/overview/operator40). Being exploded into config.translations by edge-api migration (explode_language_packs_to_translations). Still read by edge-node-red GraphQL flow (language_pack_desktop). Prefer config.translations for new reads.';
COMMENT ON COLUMN config.language_packs.language_tag IS 'BCP-47 language tag (PK).';
COMMENT ON COLUMN config.language_packs.id_language_pack IS 'Legacy numeric id of the pack (nullable).';
COMMENT ON COLUMN config.language_packs.language_pack_desktop IS 'Desktop-app translation blob (jsonb).';
COMMENT ON COLUMN config.language_packs.language_pack_mobile IS 'Mobile-app translation blob (jsonb).';
COMMENT ON COLUMN config.language_packs.language_pack_operator IS 'Operator-app translation blob (jsonb).';
COMMENT ON COLUMN config.language_packs.language_pack_overview IS 'Overview-screen translation blob (jsonb).';
COMMENT ON COLUMN config.language_packs.language_pack_operator40 IS 'Operator-4.0 app translation blob (jsonb).';

COMMENT ON TABLE config.pages IS 'Catalog of custom UI pages exposed per tenant. edge-api pages DAO unnests list_of_enterprises to return each enterprise its pages (plus a synthetic Overview when equipment has an overview_version).';
COMMENT ON COLUMN config.pages.id_page IS 'Page PK.';
COMMENT ON COLUMN config.pages.list_of_enterprises IS 'int[] of enterprises this page is exposed to (unnested per-tenant at read time). Default {}.';
COMMENT ON COLUMN config.pages.page_info IS 'Page metadata/definition (jsonb); page_info->>''name'' is the display name (nm_page).';
COMMENT ON COLUMN config.pages.default_piot_page IS 'TRUE = default landing page (sorted first). Default false.';

COMMENT ON TABLE config.dashboard_config IS 'Per-tenant, per-dashboard BASELINE config document (ADR-0029 §D2 / Phase F2). read-api /v1/dashboard-config serves baseline || per-user override (identity.user_screen_config), override keys winning. Highest version per (id_enterprise, dashboard_id) wins. Rendered by the front4 composition engine.';
COMMENT ON COLUMN config.dashboard_config.id_enterprise IS 'Owning tenant (server-derived fence, never client-named).';
COMMENT ON COLUMN config.dashboard_config.dashboard_id IS 'Dashboard identifier within the tenant.';
COMMENT ON COLUMN config.dashboard_config.config IS 'Baseline dashboard config document (jsonb); deep schema validation is owned by the front4 engine, not the DB.';
COMMENT ON COLUMN config.dashboard_config.version IS 'Config version; the highest version for (tenant, dashboard_id) is served. Default 1.';
COMMENT ON COLUMN config.dashboard_config.updated_at IS 'Last write time (now()).';

COMMENT ON TABLE config.labels IS 'Barcode label templates per (id_enterprise, id_equipment). Referenced by production_orders.id_label; consumed on the edge-api PO / label-print path. 0-row on staging = unseeded prod-only data, NOT dead.';
COMMENT ON COLUMN config.labels.id_label IS 'Label template PK (bigserial); referenced by production_orders.id_label.';
COMMENT ON COLUMN config.labels.id_enterprise IS 'Owning tenant.';
COMMENT ON COLUMN config.labels.id_equipment IS 'Equipment this label template applies to.';
COMMENT ON COLUMN config.labels.name IS 'Label template name.';
COMMENT ON COLUMN config.labels.template IS 'Label layout/template definition (nullable). UNCERTAIN format — best guess: printer template body (e.g. ZPL/markup).';

COMMENT ON TABLE config.label_formats IS 'ADR-0014 per-tenant barcode label-adapter DESCRIPTORS driving the stream-engine boxes flow (boxes_adapter.go). One row = one scanner enterprise onboarded with zero code; fields name jsonb keys inside equipment_values.analogs. Two archetypes: delivery and counter.';
COMMENT ON COLUMN config.label_formats.id_enterprise IS 'Owning tenant (customer_id).';
COMMENT ON COLUMN config.label_formats.label_key IS 'Top-level key inside equipment_values.analogs holding this tenant''s label array/object.';
COMMENT ON COLUMN config.label_formats.archetype IS 'Adapter shape: ''delivery'' (per-label date+ISO-8601 duration+workcenter) or ''counter'' (rides producing equipment row, bucket-aggregated).';
COMMENT ON COLUMN config.label_formats.order_field IS 'analogs sub-key for the order number (nullable per archetype).';
COMMENT ON COLUMN config.label_formats.qty_field IS 'analogs sub-key for the quantity/net-production value.';
COMMENT ON COLUMN config.label_formats.workcenter_field IS 'analogs sub-key for the workcenter code (joined to equipments.cd_equipment).';
COMMENT ON COLUMN config.label_formats.date_field IS 'analogs sub-key for the label date (delivery archetype).';
COMMENT ON COLUMN config.label_formats.time_field IS 'analogs sub-key for the label time/ISO-8601 duration (delivery archetype).';
COMMENT ON COLUMN config.label_formats.tz IS 'IANA timezone used to compose the label timestamp. Defaults to UTC when NULL.';
COMMENT ON COLUMN config.label_formats.bucket IS 'time_bucket interval for aggregation (counter archetype only).';

-- =====================================================================
-- ops
-- =====================================================================

COMMENT ON TABLE ops.idempotency_keys IS 'HTTP idempotency cache (ADR-0007). edge-api IdempotencyInterceptor stores the response of a successful POST under the client Idempotency-Key header (sent by mirror-worker replays); a retry within 24h replays the cached response instead of re-executing the write. Only successful (2xx) responses are cached; TTL enforced in the read predicate.';
COMMENT ON COLUMN ops.idempotency_keys.idempotency_key IS 'Client-supplied Idempotency-Key header value (PK).';
COMMENT ON COLUMN ops.idempotency_keys.response_status IS 'HTTP status of the first successful completion, replayed on retry.';
COMMENT ON COLUMN ops.idempotency_keys.response_body IS 'Cached response body (jsonb) replayed on retry.';
COMMENT ON COLUMN ops.idempotency_keys.created_at IS 'Insert time; drives the 24h TTL (rows older than 24h are never honored). Default now().';

COMMENT ON TABLE ops.capture_observations IS 'ADR-0045 §2.4b live-capture OBSERVE evidence. sparkplug-decoder agent (sole writer) upserts which count indices + topics actually arrive from a tenant''s live PLC tee while client_descriptors.status=''captured''; edge-api reads (read-only) to diff against the descriptor, promoting count-index entries from inferred to confirmed. Best-effort DQ evidence, never the data plane. Upsert key (id_enterprise, topic, count_index).';
COMMENT ON COLUMN ops.capture_observations.id_capture_observation IS 'Surrogate PK (bigserial).';
COMMENT ON COLUMN ops.capture_observations.id_enterprise IS 'Tenant being observed.';
COMMENT ON COLUMN ops.capture_observations.topic IS 'SparkPlug packml_topic the count channel arrived on.';
COMMENT ON COLUMN ops.capture_observations.count_index IS 'Count-channel index within the topic (part of the observe identity).';
COMMENT ON COLUMN ops.capture_observations.metric_suffix IS 'Full SparkPlug metric-name leaf/suffix observed for this channel (overwritten to the latest on upsert).';
COMMENT ON COLUMN ops.capture_observations.first_seen_ts IS 'Earliest sighting of this channel (pinned to LEAST on upsert). Default now().';
COMMENT ON COLUMN ops.capture_observations.last_seen_ts IS 'Latest sighting of this channel (widened to GREATEST on upsert). Default now().';
COMMENT ON COLUMN ops.capture_observations.observed_count IS 'Running total of observations for this channel (SUMmed across flush intervals). Default 0.';

COMMENT ON TABLE ops.mirror_replay_cursor IS 'High-water mark for the prod->staging mirror-replay pipeline (mirror-worker-go). One row per replay source stream: last_log_id = highest prod user_logs id already replayed; the poll loop reads rows above it, replays into staging, and advances the cursor.';
COMMENT ON COLUMN ops.mirror_replay_cursor.source IS 'Replay stream identifier (PK), e.g. the event/order category a worker drains.';
COMMENT ON COLUMN ops.mirror_replay_cursor.last_log_id IS 'Highest prod user_logs.id_user_logs replayed for this source (replay watermark).';
COMMENT ON COLUMN ops.mirror_replay_cursor.last_run_at IS 'Last poll-loop run time for this source. Default now().';

COMMENT ON TABLE ops.mirror_replay_dlq IS 'Dead-letter queue for the mirror-replay pipeline. The poll loop writes a row + advances the cursor on any non-skip error so the queue keeps moving; the DLQ retrier re-replays rows past their exponential backoff window and DELETEs on success. Depth powers the mirror_worker_dlq_depth gauge.';
COMMENT ON COLUMN ops.mirror_replay_dlq.id IS 'Surrogate PK (bigserial).';
COMMENT ON COLUMN ops.mirror_replay_dlq.source IS 'Replay stream identifier this failed row belongs to (matches mirror_replay_cursor.source).';
COMMENT ON COLUMN ops.mirror_replay_dlq.source_log_id IS 'prod user_logs.id_user_logs of the failed source record (re-SELECTed to rebuild the replay on retry).';
COMMENT ON COLUMN ops.mirror_replay_dlq.category IS 'Category of the replayed prod user_log (action classification). Nullable.';
COMMENT ON COLUMN ops.mirror_replay_dlq.subcategory IS 'Subcategory of the replayed prod user_log. Nullable.';
COMMENT ON COLUMN ops.mirror_replay_dlq.payload IS 'Captured payload (jsonb) of the failed replay for triage/reanimation.';
COMMENT ON COLUMN ops.mirror_replay_dlq.error IS 'Error message that caused the DLQ write.';
COMMENT ON COLUMN ops.mirror_replay_dlq.retry_attempts IS 'Retry counter maintained solely by the DLQ retrier; drives backoff = (1<<retry_attempts) minutes. Default 0 (first retry fires immediately).';
COMMENT ON COLUMN ops.mirror_replay_dlq.last_retry_at IS 'Timestamp of the last re-replay attempt (NULL = never retried, immediately eligible). Set by the retrier only.';
COMMENT ON COLUMN ops.mirror_replay_dlq.created_at IS 'When the row was dead-lettered. Default now().';
