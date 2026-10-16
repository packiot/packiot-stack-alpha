-- Tidy pass: make packiot_analytics self-documenting — schema taxonomy, the
-- naming convention, and COMMENTs on the int-as-timestamp trap columns. Pure
-- documentation (COMMENT ON …); zero blast radius. Visible via psql \l+, \dn+, \d+.
BEGIN;

-- ── Top-level map + naming convention (psql: \l+) ────────────────────────────
COMMENT ON DATABASE packiot_analytics IS
$$Analytics hot store. Schema taxonomy — each schema answers ONE question:
 MATURITY (medallion pipeline): bronze=raw immutable · silver=merged facts+rollups+live grains · gold=computed OEE grains.
 CONTEXT: core=conformed dimensions (Kimball) · auth=identity · config=i18n/labels · ops=operational plumbing.
 SECURITY/CONSUMER: serving=security_invoker API (read-api) · bi=security_definer+RLS (Superset).
 CUSTOMER: customer_reports / customer_dashboards=per-tenant surfaces.
 public=transactional tables (Samples, PO control) + knex ledger + auto-updatable compat shim views into the domain schemas.
Naming convention: LEGACY tables keep Hungarian-ish prefixes id_/nm_/cd_/tp_/ts_/vl_/dt_/txt_ (id_=identifier, nm_/txt_=name/text, cd_=code, tp_=type, ts_=timestamp, vl_=value, dt_=date). NEW tables use the clean core.downtime_reason style (id/code/label/category/active). Do not mix within one table.$$;

-- ── Domain-schema descriptions (psql: \dn+) ──────────────────────────────────
COMMENT ON SCHEMA bronze  IS 'Medallion BRONZE — immutable append-only raw landing: equipment_values_raw/events_raw (ADR-0036, flag-gated BRONZE_RAW_APPEND), box_scans (barcode scan ledger, no_mutate trigger). Never UPDATE/DELETE.';
COMMENT ON SCHEMA silver  IS 'Medallion SILVER — merged/deduped facts (equipment_values/events, latest-wins UPSERT) + minute/hour metric & categorical rollup caggs + current-state live grains (equipment_live_*, area/site_live_*).';
COMMENT ON SCHEMA gold    IS 'Medallion GOLD — computed OEE grains (equipment_oee_{shift,hourly,daily,weekly,monthly}, area/site) + per-PO aggregates (production_orders_runtime, po_box_counter).';
COMMENT ON SCHEMA core    IS 'Conformed dimensions (Kimball): enterprises→sites→areas→equipments hierarchy + production_orders, shifts/shift_hours, topic_routing (SparkPlug routing), products/clients, scrap_targets. The control-plane reference data.';
COMMENT ON SCHEMA auth    IS 'Application AUTH (identity): users, user_roles, user_screen_config, user_logs (action audit trail).';
COMMENT ON SCHEMA config  IS 'Application CONFIG (i18n + labels): translations, tenant_translations, language_packs, pages, dashboard_config, labels, label_formats.';
COMMENT ON SCHEMA ops     IS 'Application OPS (operational plumbing): idempotency_keys, function_execution_log, capture_observations, mirror_replay_cursor/dlq.';
COMMENT ON SCHEMA serving IS 'Serving API — security_invoker views/functions read by read-api under the CALLER''s RLS. Programmatic query surface.';
COMMENT ON SCHEMA bi      IS 'BI — security_definer + RLS views for Superset (definer-side tenant fence via current_setting(''app.tenant_id'')).';

-- ── The int-as-timestamp trap columns (psql: \d+ core.shift_hours) ───────────
COMMENT ON COLUMN core.shift_hours.begin_time IS 'INTEGER SECONDS from week_begin (NOT a clock time). Calendar expansion of a shift × weekday. Contrast core.shifts.begin_time, which IS a clock time.';
COMMENT ON COLUMN core.shift_hours.end_time   IS 'INTEGER SECONDS from week_begin (NOT a clock time). See core.shift_hours.begin_time.';
COMMENT ON COLUMN core.shifts.begin_time      IS 'Clock time (time-of-day). Shift definition. Contrast core.shift_hours.begin_time, which is integer seconds from week_begin.';
COMMENT ON COLUMN core.shifts.end_time        IS 'Clock time (time-of-day). See core.shifts.begin_time.';
COMMENT ON COLUMN core.enterprises.week_begin IS 'INTEGER SECONDS offset of the production week''s start from Monday 00:00. MAY BE NEGATIVE (e.g. -3000 = Sunday 23:10). Site/area inherit or override.';
COMMENT ON COLUMN core.enterprises.day_begin  IS 'INTEGER SECONDS offset of the production day''s start from midnight.';
COMMENT ON COLUMN core.enterprises.week_size  IS 'INTEGER SECONDS in the production week (normally 604800).';
COMMENT ON COLUMN core.sites.week_begin       IS 'INTEGER SECONDS offset of the week start from Monday 00:00; may be negative. Overrides enterprise.';
COMMENT ON COLUMN core.sites.day_begin        IS 'INTEGER SECONDS offset of the day start from midnight. Overrides enterprise.';
COMMENT ON COLUMN core.sites.week_size        IS 'INTEGER SECONDS in the production week. Overrides enterprise.';
COMMENT ON COLUMN core.areas.week_begin       IS 'INTEGER SECONDS offset of the week start from Monday 00:00; may be negative. Overrides site.';
COMMENT ON COLUMN core.areas.day_begin        IS 'INTEGER SECONDS offset of the day start from midnight. Overrides site.';
COMMENT ON COLUMN core.areas.week_size        IS 'INTEGER SECONDS in the production week. Overrides site.';

COMMIT;
