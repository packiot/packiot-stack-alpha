-- knex-baseline.sql — ROADMAP W1.5: reconcile edge-api's knex migrations with
-- the F3-as-`public` schema so knex does NOT rebuild the legacy F1 shape over F3.
--
-- CONTEXT (see docs/adr/reference/production-knex-f3-reconciliation.md):
--   In greenfield single-flow prod, `db-schema-f3` assembles the proven F3
--   schema as `public` (F3_MISSING=0). THEN `db-migrate` runs edge-api's knex
--   `migrate:latest`. edge-api's migrations were authored to BUILD the legacy F1
--   schema from an empty DB — most of the early ones are `CREATE TABLE <x>` with
--   NO guard. Run against an F3-shaped DB with an empty `knex_migrations`, knex
--   tries to apply ALL of them from scratch and dies on the first one
--   (`equipment_values already exists`), aborting the whole batch — OR, worse, if
--   the F3 schema were absent, it silently builds F1 and prod computes WRONG OEE.
--
-- THE FIX (industry-standard "fake-baseline", cf. Rails `db:schema:load` +
-- `db:migrate --fake`, Django `--fake-initial`): pre-seed `knex_migrations` with
-- every migration whose object F3 ALREADY provides (or which F3 DELIBERATELY
-- omits and re-adding would DIVERGE from F3). knex then treats them as applied
-- and `migrate:latest` runs ONLY the genuinely edge-api-specific migrations that
-- F3 lacks (labels / sample_boxes / scanned_boxes / idempotency_keys /
-- mirror_replay_dlq + the additive id_label / operator_pw_hash columns).
--
-- knex 2.5.1's only integrity check is "a completed migration must exist on disk"
-- (validateMigrationList -> getMissingMigrations); it does NOT reject a pending
-- migration that sorts before a faked one. So faking a non-contiguous subset is
-- safe: the pending (edge-api-only) migrations still run, in filename order.
--
-- IDEMPOTENT: safe to run more than once (unique index + ON CONFLICT). Applied by
-- the `db-knex-baseline` compose one-shot, AFTER db-schema-f3, BEFORE db-migrate.
--
-- MAINTENANCE: this list is coupled to edge-api/migrations/. When edge-api adds a
-- migration, classify it (fake vs run); scripts/prod-knex-f3-reconcile-check.sh
-- FAILS if any migration file is unclassified.

BEGIN;

-- knex's own bookkeeping tables, in knex's exact shape (knex 2.5.1
-- lib/migrations/migrate/table-creator.js). Created here so we can seed BEFORE
-- knex runs; knex's ensureTable then no-ops (tables already exist).
CREATE TABLE IF NOT EXISTS knex_migrations (
  id             serial PRIMARY KEY,
  name           varchar(255),
  batch          integer,
  migration_time timestamptz
);
CREATE TABLE IF NOT EXISTS knex_migrations_lock (
  "index"   serial PRIMARY KEY,
  is_locked integer
);
-- Idempotency guard for the seed INSERT below.
CREATE UNIQUE INDEX IF NOT EXISTS knex_migrations_name_uq ON knex_migrations (name);

-- knex._lockMigrations does `UPDATE ... SET is_locked=1 WHERE is_locked=0` and
-- REQUIRES exactly one matching row (rowCount===1 or it throws "already locked").
-- knex only seeds this row when IT creates the lock table; since we create it,
-- we must seed it.
INSERT INTO knex_migrations_lock (is_locked)
SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM knex_migrations_lock);

-- ── Fake-apply set (batch 0): migrations whose object F3 already provides, OR
-- that F3 deliberately omits (re-adding would diverge from the proven F3 shape).
-- Each row is annotated with WHY it is faked. `batch 0` visually distinguishes
-- the F3 baseline from migrations knex actually applies (it uses batch >= 1).
INSERT INTO knex_migrations (name, batch, migration_time) VALUES
  -- F3 already HAS these tables/columns/constraints -> a plain CREATE/ALTER would
  -- ERROR ("already exists") and abort the batch. Fake to skip.
  ('20230816170559_create_equipment_values.ts',                   0, now()), -- F3 has equipment_values (as a HYPERTABLE; the F1 shape is a plain serial-PK table — must NOT be rebuilt over F3)
  ('20230816194129_create_equipments.ts',                         0, now()), -- F3 has equipments
  ('20230817132725_create_enterprises.ts',                        0, now()), -- F3 has enterprises
  ('20230817135658_create_clients.ts',                            0, now()), -- F3 has clients
  ('20230817140322_create_sites.ts',                              0, now()), -- F3 has sites
  ('20230817140626_create_areas.ts',                              0, now()), -- F3 has areas
  ('20230817141814_create_product_family.ts',                     0, now()), -- F3 has product_families
  ('20230817142108_create_products.ts',                           0, now()), -- F3 has products
  ('20230817142630_create_user_roles.ts',                         0, now()), -- F3 has user_roles
  ('20230817143018_create_users.ts',                              0, now()), -- F3 has users
  ('20230817154644_create_production_orders.ts',                  0, now()), -- F3 has production_orders
  ('20230817160953_create_production_orders_runtime.ts',          0, now()), -- F3 has production_orders_runtime (+ its sequence)
  ('20230922203352_create_equipment_events_table.ts',             0, now()), -- F3 has equipment_events
  ('20230926205614_create_manual_event_table.ts',                 0, now()), -- F3 has equipment_events_man
  ('20231122142254_add_net_production_type.ts',                   0, now()), -- F3 equipments already has net_production_type
  ('20240830220046_create_user_logs.ts',                          0, now()), -- F3 has user_logs
  ('20251001000000_add_check_constraints_production_orders.ts',   0, now()), -- F3 already has production_orders_speed_check + ts_start_ts_end
  ('20260512000001_create_packml_register.ts',                    0, now()), -- F3 has packml_register
  -- F3 DELIBERATELY OMITS these; re-adding would DIVERGE from the proven F3 shape.
  ('20230817131303_add_foreign_key_eqp_values.ts',                0, now()), -- F3 equipment_values (hypertable) has NO FK to equipments — the F3 shape omits it
  ('20230817162628_add_exclude_constraint_production_orders.ts',  0, now()), -- F3 has NO gist EXCLUDE on production_orders_runtime (and no btree_gist ext)
  ('20250903183221_update_equipmentevents_trigger_function.ts',   0, now()), -- F3 has NO piot_trig_equipment_events_update_prev fn (Go worker owns event closure in F3)
  ('20250903183451_update_equipmentevents_trigger.ts',            0, now()), -- F3 has NO update_prev trigger — re-adding it double-manages event durations = WRONG OEE
  ('20260625000001_equipment_events_trigger_bypass_forced.ts',    0, now()), -- same trigger fn (bypass variant); F3 omits it
  ('20260701000001_shadow_go_port_schema.ts',                     0, now()), -- shadow_go_port/shadow_diff = F1<->F3 comparison infra; single-flow prod has no comparator
  ('20260702000001_shadow_go_port_operator_tables.ts',            0, now())  -- shadow_go_port operator mirror tables; comparison infra, not needed in prod
ON CONFLICT (name) DO NOTHING;

-- Everything NOT faked above runs on `db-migrate` (knex migrate:latest), all of
-- it F3-safe (net-new edge-api tables, or idempotent-guarded adds):
--   20260409000001_create_labels                        (new table)
--   20260409000002_create_sample_boxes                  (new table)
--   20260409000003_create_scanned_boxes                 (new table)
--   20260413000001_add_id_label_to_production_orders    (additive col, guarded; edge-api INSERTs it)
--   20260413000002_fix_scanned_boxes                    (guarded reshape of scanned_boxes)
--   20260413000003_production_orders_equipment_run_idx  (CREATE INDEX IF NOT EXISTS)
--   20260413000004_add_id_plc_to_equipments             (guarded; no-op — F3 has it)
--   20260414000001_add_active_to_sites_and_areas        (IF NOT EXISTS; no-op — F3 has it)
--   20260414000002_create_shifts                        (hasTable guard; no-op — F3 has it)
--   20260414000003_add_active_to_equipments             (IF NOT EXISTS; no-op — F3 has it)
--   20260420000001_create_pages                         (createTableIfNotExists; no-op — F3 has it)
--   20260611000001_add_nm_production_order              (guarded; no-op — F3 has it)
--   20260626000001_mirror_replay_dlq_add_retry_columns  (creates mirror_replay_dlq IF NOT EXISTS)
--   20260630235959_create_uns_equipment_current_metrics (IF NOT EXISTS; no-op — F3 has it)
--   20260707120000_add_operator_pw_hash_to_users        (additive col, IF NOT EXISTS; edge-api SELECTs it)
--   20260707180000_create_idempotency_keys              (new table)

COMMIT;
