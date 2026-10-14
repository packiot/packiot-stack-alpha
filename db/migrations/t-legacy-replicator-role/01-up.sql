-- t-legacy-replicator-role — the least-privilege DEST login legacy-replicator runs under (2026-10-14).
--
-- WHY
-- legacy-replicator (services/analytics-sync/cmd/legacy-replicator; compose services legacy-replicator and
-- legacy-replicator-sbx) wrote packiot_analytics as ${POSTGRES_USER} (postgres: SUPERUSER, BYPASSRLS) with
-- env_file: [.env] (every secret on the host in its environment). A bug or a compromised dependency could
-- DROP, TRUNCATE, ALTER or read anything on the cluster.
--
-- SCOPE: the DEST connection only. How it reads the LEGACY source DB (packiot40, SELECT-only, login
-- awslambda from LEGACY_DB_*) is unchanged and not this migration's business.
--
-- WHAT IT ACTUALLY NEEDS (full statement inventory: services/analytics-sync/README.md § legacy-replicator
-- database role; nothing below needs ownership):
--   * DML only. SELECT for the resolver/lookups; INSERT/UPDATE for the PO lifecycle replay, the PO
--     reconciler + enrich pass, the event replay and the base-event reconciler; DELETE only where a pass
--     rewrites what it owns: gold.production_orders_runtime (window convergence), silver.equipment_events_man
--     + ops.legacy_manual_event_link (manual-event reconciler, provenance-checked), ops.mirror_replay_dlq
--     (retrier clears a row on success) and serving.downtime_events_resolved (the refresh function below).
--   * No DDL. The binary used to run CREATE SCHEMA ops / CREATE TABLE IF NOT EXISTS ops.mirror_replay_cursor,
--     ops.mirror_replay_dlq (+ ALTER … ADD COLUMN, CREATE INDEX) and ops.legacy_manual_event_link at boot; a
--     non-owner cannot (CREATE is checked before IF NOT EXISTS), so that DDL now lives HERE (section 1) and the
--     code only checks the tables exist. No TRUNCATE, COPY, temp tables, SET ROLE, advisory locks of its own,
--     session_replication_role, or superuser-only calls (grep-confirmed).
--   * Triggers fired by its writes run as the invoker: core.production_orders_po_number (every PO
--     INSERT/UPDATE) reads core.po_number_corrections and may nextval core.production_orders_internal_id_order_seq
--     (the two grants the stream-engine static inventory missed); core.production_orders.po_uuid DEFAULT calls
--     core.uuidv7(). No other written table has a user trigger.
--   * serving.refresh_downtime_events_resolved(tstz, tstz) is SECURITY INVOKER: it DELETEs every tenant's rows
--     of serving.downtime_events_resolved in the range and re-INSERTs (ON CONFLICT DO UPDATE) from
--     silver.equipment_events{,_man} ⋈ core.equipments/sites/shifts/production_orders ⋈
--     gold.production_orders_runtime/equipment_oee_shift. So the role needs those reads too.
--   * Sequences: USAGE behind serial INSERT targets; core.products_id_product_seq and core.clients_id_client_seq
--     also SELECT (reads last_value) + UPDATE (setval past a kept legacy id: enrich KEEP_LEGACY_IDS). Identity
--     columns need none.
--
-- RLS: TENANT-SCOPED, not cross-tenant. Each instance mirrors exactly ONE tenant (DST_ENTERPRISE: 3 CPACK,
-- 2000003 the sandbox twin) and every statement it runs is keyed on that tenant or on that tenant's equipment.
-- So the role is NOBYPASSRLS with NO app.tenant_id default, and each connection stamps
-- app.tenant_id = DST_ENTERPRISE in its startup packet (cmd/legacy-replicator: db.DBCreds.Params). Effect:
--   * on the FORCE-RLS tables it touches (core.equipments, core.topic_routing via the security_invoker
--     core.packml_register view, core.production_orders, gold.production_orders_runtime, gold.equipment_oee_shift,
--     serving.downtime_events_resolved) a bug that addresses another tenant's row matches nothing;
--   * a connection WITHOUT the stamp sees no tenant rows at all (fails closed: the resolver maps nothing);
--   * the cross-tenant serving.refresh_downtime_events_resolved stays correct: its DELETE and re-INSERT both go
--     through serving.downtime_events_resolved's FORCE RLS, so a tenant-3 caller re-resolves tenant 3 only and
--     leaves every other tenant's rows untouched (golden test proves it).
-- Not -1 (the all-tenant sentinel stream_engine uses): nothing here needs a second tenant, and -1 would let the
-- CPACK instance write the sandbox tenant and vice versa. NOT a security boundary against a compromised
-- process (app.tenant_id is user-settable), a fence against bugs — the same as every RLS GUC in this stack.
-- silver.equipment_events{,_man} and the ops tables have no RLS; their statements filter on id_enterprise /
-- the tenant's equipment in SQL.
--
-- PASSWORD. Not here. LOGIN with a NULL password until the host sets it from Secrets Manager
-- packiot/<env>/legacy-replicator-db-creds (scripts/ops/provision-db-role.py --service legacy-replicator).
--
-- Idempotent: guarded CREATEs, ALTER re-asserts attributes, GRANTs are repeatable. Run as postgres.
-- Reversible: rollback.sql (point both replicators back at their old login first).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

-- ── 1. the ops tables the binary used to create at boot (same DDL; no-ops where they exist) ───────────────
CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.mirror_replay_cursor (
  source       text PRIMARY KEY,
  last_log_id  bigint NOT NULL,
  last_run_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ops.mirror_replay_dlq (
  id             BIGSERIAL   PRIMARY KEY,
  source         text        NOT NULL,
  source_log_id  bigint      NOT NULL,
  category       text,
  subcategory    text,
  payload        jsonb,
  error          text        NOT NULL,
  retry_attempts int         NOT NULL DEFAULT 0,
  last_retry_at  timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);
-- an older table without the retrier's columns converges (guarded: no ACCESS EXCLUSIVE lock when current)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'ops'
                    AND table_name = 'mirror_replay_dlq' AND column_name = 'retry_attempts') THEN
    ALTER TABLE ops.mirror_replay_dlq ADD COLUMN retry_attempts int NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'ops'
                    AND table_name = 'mirror_replay_dlq' AND column_name = 'last_retry_at') THEN
    ALTER TABLE ops.mirror_replay_dlq ADD COLUMN last_retry_at timestamptz;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS mirror_replay_dlq_source_idx ON ops.mirror_replay_dlq (source, created_at DESC);

-- provenance of manual events the manual-event reconciler wrote (first created by t-replicate-manual-events).
-- No FK to silver.equipment_events_man on purpose (TRUNCATE / sandbox re-clone); dangling links are pruned.
CREATE TABLE IF NOT EXISTS ops.legacy_manual_event_link (
  id_equipment_event        integer     PRIMARY KEY,
  dst_enterprise            integer     NOT NULL,
  legacy_id_equipment_event bigint,
  linked_at                 timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS legacy_manual_event_link_ent_legacy_idx
  ON ops.legacy_manual_event_link (dst_enterprise, legacy_id_equipment_event);

-- ── 2. the role ──────────────────────────────────────────────────────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'legacy_replicator') THEN
    CREATE ROLE legacy_replicator LOGIN;
  END IF;
END $$;

ALTER ROLE legacy_replicator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT
  CONNECTION LIMIT 15;   -- two instances × pool 5 + provision conn + a rolling recreate
ALTER ROLE legacy_replicator RESET app.tenant_id;   -- no tenant default on purpose: the connection stamps it (RLS)

COMMENT ON ROLE legacy_replicator IS
  'legacy-replicator DEST login (t-legacy-replicator-role): DML on the PO/runtime/event/manual-event tables it '
  'mirrors into, its ops cursor/DLQ/provenance tables and serving.downtime_events_resolved; sequence USAGE (+ '
  'setval on products/clients); EXECUTE on 5 INVOKER functions; no DDL, no TRUNCATE, no TEMP. NOBYPASSRLS, no '
  'tenant default: each instance stamps app.tenant_id=DST_ENTERPRISE at connect. Password from Secrets Manager '
  'packiot/<env>/legacy-replicator-db-creds.';

DO $$ BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO legacy_replicator', current_database());
END $$;

GRANT USAGE ON SCHEMA core, gold, silver, ops, serving, public TO legacy_replicator;

-- ── 3. reads ─────────────────────────────────────────────────────────────────────────────────────────────
-- resolver (packml_register is a security_invoker view over topic_routing; equipments = staging hierarchy)
GRANT SELECT ON core.equipments, core.topic_routing, core.packml_register TO legacy_replicator;
-- trigger production_orders_po_number (every core.production_orders INSERT/UPDATE)
GRANT SELECT ON core.po_number_corrections TO legacy_replicator;
-- serving.refresh_downtime_events_resolved joins
GRANT SELECT ON core.sites, core.shifts, gold.equipment_oee_shift TO legacy_replicator;
-- sandbox hold gate (ops.sandbox_hold_mode reads this definer-rights view)
GRANT SELECT ON ops.sandbox_hold_status TO legacy_replicator;

-- ── 4. writes ────────────────────────────────────────────────────────────────────────────────────────────
-- PO lifecycle replay + PO reconciler (+ converge) + enrich: insert/update, never delete
GRANT SELECT, INSERT, UPDATE         ON core.production_orders                              TO legacy_replicator;
-- enrich: find-or-create product dimensions by name
GRANT SELECT, INSERT                 ON core.products, core.product_families, core.clients  TO legacy_replicator;
-- runtime windows: open/close/reassign; converge deletes and re-inserts a PO's windows
GRANT SELECT, INSERT, UPDATE, DELETE ON gold.production_orders_runtime                      TO legacy_replicator;
-- base events: replay + base reconciler insert, classify/split update; never delete
GRANT SELECT, INSERT, UPDATE         ON silver.equipment_events                             TO legacy_replicator;
-- manual events: the manual-event reconciler deletes rows it owns (provenance-checked in the same statement)
GRANT SELECT, INSERT, UPDATE, DELETE ON silver.equipment_events_man                         TO legacy_replicator;
-- serving refresh: delete-range + re-insert ON CONFLICT DO UPDATE
GRANT SELECT, INSERT, UPDATE, DELETE ON serving.downtime_events_resolved                    TO legacy_replicator;
-- its own plumbing
GRANT SELECT, INSERT, UPDATE         ON ops.mirror_replay_cursor                            TO legacy_replicator;
GRANT SELECT, INSERT, UPDATE, DELETE ON ops.mirror_replay_dlq, ops.legacy_manual_event_link TO legacy_replicator;

-- ── 5. sequences ─────────────────────────────────────────────────────────────────────────────────────────
GRANT USAGE ON SEQUENCE
  core.production_orders_internal_id_order_seq,   -- nextval in trigger production_orders_po_number
  core.product_families_id_product_family_seq,
  silver.equipment_events_source_seq_seq,
  ops.mirror_replay_dlq_id_seq
TO legacy_replicator;
-- enrich KEEP_LEGACY_IDS: SELECT last_value + setval past an explicitly inserted legacy id
GRANT SELECT, UPDATE, USAGE ON SEQUENCE core.products_id_product_seq, core.clients_id_client_seq
  TO legacy_replicator;

-- ── 6. functions (all SECURITY INVOKER; explicit so the role does not rely on PUBLIC EXECUTE) ────────────
GRANT EXECUTE ON FUNCTION
  public.current_tenant(), public.is_all_tenant(),                     -- RLS policies
  core.uuidv7(timestamptz),                                            -- core.production_orders.po_uuid DEFAULT
  ops.sandbox_hold_mode(integer),                                      -- sandbox hold gate (hold.go)
  serving.refresh_downtime_events_resolved(timestamptz, timestamptz)   -- base/manual reconcilers
TO legacy_replicator;

COMMIT;
