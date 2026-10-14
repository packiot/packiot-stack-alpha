-- t-barcode-service-role — the least-privilege login barcode-service runs under (2026-10-14).
--
-- WHY
-- barcode-service connected to packiot_analytics as ${POSTGRES_USER} (postgres: SUPERUSER, BYPASSRLS),
-- and its compose service had env_file: [.env], so the admin password and every other .env secret sat
-- in the container's environment. It is a PUBLIC endpoint (scan.<env>.packiot.app, Cognito JWT): a
-- leaked credential or an injection bug was a superuser on the shared analytics DB, and its tenant
-- fence ran with RLS bypassed.
--
-- CALL PATH → PRIVILEGE (complete; services/barcode-service/cmd/barcode-service)
--   pool connect + /healthz Ping .................................. CONNECT on the database
--   POST /v1/scans, one tx per scan (scans.go RecordScan):
--     pg_advisory_xact_lock(id_po) ................................ built-in, EXECUTE granted to PUBLIC
--     set_config('app.tenant_id', <JWT tenant>, true) .............. built-in, no grant
--     existingByUUID: bronze.box_scans (id_enterprise, box_scan_id, label_seq, scan_uuid,
--                     id_production_order) ⟕ gold.po_box_counter (id_production_order, total_qty)  SELECT
--     tenantOwns:     core.production_orders (id_production_order, id_enterprise),
--                     core.equipments (id_equipment, id_enterprise)                                 SELECT
--     lastLabelSeq:   gold.po_box_counter (id_production_order, last_label_seq)                    SELECT
--     insertScan:     INSERT bronze.box_scans (13 columns) RETURNING box_scan_id  INSERT on those 13 +
--                     SELECT box_scan_id; scalar subqueries read core.equipments (id_site, id_area) and
--                     core.production_orders (id_order)                                            SELECT
--                     INSERT … ON CONFLICT (id_production_order) DO UPDATE gold.po_box_counter
--                     RETURNING total_qty   INSERT on its 5 columns, UPDATE on the 3 the SET writes,
--                     SELECT on the ones it reads (conflict key, last_label_seq, total_qty)
--   Firebase token path (auth_firebase.go): NOTHING granted. It is off on staging and dev
--     (FIREBASE_PROJECT_ID="", #159), and its query cannot run against packiot_analytics anyway:
--     identity.users has no id_user_firebase column (42703). Firebase stays retired.
--   RLS tenant_isolation on core.production_orders + core.equipments (FORCE) calls
--     public.current_tenant() / public.is_all_tenant() as the invoker . USAGE on core + public,
--     EXECUTE on the two helpers (explicit, so a future REVOKE … FROM PUBLIC cannot break it)
-- Not needed: box_scan_id is GENERATED ALWAYS AS IDENTITY (an identity's implicit nextval is not
-- ACL-checked; box_uid/ingested_at defaults are gen_random_uuid()/now()); the FKs on both tables
-- (enterprises, sites, areas, equipments, production_orders, box_scans) run their RI checks as the
-- table owner; serving.v_po_box_totals is read by other services, not this one. No UPDATE/DELETE on
-- box_scans (append-only; trg_box_scans_no_mutate rejects them anyway), no DDL, no TRUNCATE.
--
-- RLS. core.production_orders and core.equipments are FORCE ROW LEVEL SECURITY keyed on app.tenant_id.
-- This role is NOBYPASSRLS, so RecordScan stamps the JWT tenant as a TRANSACTION-LOCAL GUC right after
-- the advisory lock (same primitive as read-api / operator-gateway; safe under pgbouncer transaction
-- pooling). Unstamped, the fence sees 0 rows → 403 (fail closed). bronze.box_scans and gold.po_box_counter
-- have no RLS; their tenant fence is the SQL (`id_enterprise = $1`, scan_uuid owner
-- check). Columns referenced only by a policy need no column grant.
--
-- PASSWORD. Not here (no secret in git). LOGIN with a NULL password until the host sets it from
-- Secrets Manager packiot/<env>/barcode-service-db-creds: services/barcode-service/README.md
-- § Provisioning the DB role. The dev seed gives every login role the password "dev".
--
-- Session defaults: statement_timeout 30s (a scan is ~6 PK/unique lookups; the bound only stops a
-- runaway, e.g. a pile-up behind one PO's advisory lock). Not read-only: this service writes.
--
-- Idempotent: guarded CREATE, ALTER re-asserts attributes, GRANTs are repeatable.
-- Reversible: rollback.sql (point barcode-service back at its old login first).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'barcode_service') THEN
    CREATE ROLE barcode_service LOGIN;
  END IF;
END $$;

ALTER ROLE barcode_service LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT
  CONNECTION LIMIT 15;   -- pool max 5 (via pgbouncer: ≤5 server conns); 15 leaves room for a recreate + psql
ALTER ROLE barcode_service SET statement_timeout = '30s';

COMMENT ON ROLE barcode_service IS
  'barcode-service scan ingest (t-barcode-service-role). Column grants on bronze.box_scans, '
  'gold.po_box_counter, core.production_orders, core.equipments; NOBYPASSRLS (stamps '
  'app.tenant_id per tx). Password from Secrets Manager packiot/<env>/barcode-service-db-creds, set on the host.';

DO $$ BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO barcode_service', current_database());
END $$;

GRANT USAGE ON SCHEMA bronze, gold, core, public TO barcode_service;

GRANT SELECT (box_scan_id, id_enterprise, id_production_order, label_seq, scan_uuid) ON bronze.box_scans TO barcode_service;
GRANT INSERT (id_enterprise, id_site, id_area, id_equipment, id_production_order, id_order,
              scan_type, label_seq, qty, counts_toward_total, raw_barcode, scan_uuid, ts_value)
  ON bronze.box_scans TO barcode_service;

GRANT SELECT (id_production_order, id_enterprise, last_label_seq, total_qty) ON gold.po_box_counter TO barcode_service;
GRANT INSERT (id_production_order, id_enterprise, last_label_seq, total_qty, updated_at)
  ON gold.po_box_counter TO barcode_service;
GRANT UPDATE (last_label_seq, total_qty, updated_at) ON gold.po_box_counter TO barcode_service;

GRANT SELECT (id_production_order, id_enterprise, id_order)   ON core.production_orders TO barcode_service;
GRANT SELECT (id_equipment, id_enterprise, id_site, id_area)  ON core.equipments        TO barcode_service;

GRANT EXECUTE ON FUNCTION public.current_tenant(), public.is_all_tenant() TO barcode_service;

COMMIT;
