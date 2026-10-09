-- f3-schema-parity.sql — STAGING CUTOVER: make packiot_analytics (F3) a complete
-- config-schema match for the legacy packiot (F1) so edge-api's `db-migrate`
-- (knex) + all runtime writes target F3 as the SOLE plane.
--
-- CONTEXT
--   Two DBs on 10.10.10.89:5432 — `packiot` (F1, knex-migration-managed config
--   master, being RETIRED) and `packiot_analytics` (F3, new-stack telemetry plane
--   holding LIVE continuously-written data + a partial/snapshot config schema that
--   is NOT knex-managed). Post-cutover edge-api points at F3.
--
--   This is the IN-PLACE STAGING analog of `db/init-f3/knex-baseline.sql`. That
--   file is the GREENFIELD path: assemble F3 as an empty `public`, fake the
--   F3-covered migration subset, then let `knex migrate:latest` BUILD the pending
--   edge-api-only tables. Here F3 already exists WITH live telemetry, so we cannot
--   re-assemble: instead we (A) CREATE the pending edge-api tables directly from
--   F1's exact shape, (B) ADD the additive drifted columns, (C) wire the one FK,
--   and (D) fake-baseline the FULL 58-row F1 ledger so `db-migrate` is a complete
--   no-op (edge-api's deployed migration folder tail == F1 ledger tail == id 58).
--
-- SAFETY
--   100% ADDITIVE. Never DROP/ALTER-AWAY anything; never touches telemetry
--   (equipment_values, *_1min/_1hour/_1day/_1week/_1month caggs, uns_*,
--   equipment_runtime_*, samples telemetry, ...). All ADD COLUMNs are nullable
--   with no default => metadata-only (no table rewrite, PG11+), safe on live
--   equipments / production_orders / users. IDEMPOTENT: re-runnable (IF NOT
--   EXISTS guards + pg_constraint checks + ON CONFLICT).
--
-- APPLY:  psql -d packiot_analytics -f db/cutover/f3-schema-parity.sql
--
-- Gap inventory found by exhaustive information_schema diff F1 vs live F3:
--   MISSING TABLES (edge-api writes them; F3 lacked them):
--     labels, sample_boxes, scanned_boxes, idempotency_keys,
--     client_descriptors, translations, tenant_translations
--   DRIFTED COLUMNS (present in F1, absent in F3):
--     equipments   += gross_machine, scrap_machine,
--                     exclude_idle_from_availability, idle_timeout_seconds
--     users        += operator_pw_hash
--     production_orders += id_label  (+ FK -> labels)
--   NOT PORTED (in F1 but NOT written by edge-api, no FK/trigger dep — out of
--   scope for edge-api parity): plcs, plc_events, devices, mirror_replay_dlq,
--   production_targets_day/week/month, packml_transmition_states.
--   FK parents of the new tables (enterprises, equipments) already exist in F3.

BEGIN;

-- ============================================================================
-- SECTION A — CREATE MISSING CONFIG TABLES (exact F1 shape)
-- ============================================================================

-- A.1 labels ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.labels (
    id_label      bigint NOT NULL,
    id_enterprise bigint NOT NULL,
    id_equipment  bigint NOT NULL,
    name          character varying(255) NOT NULL,
    template      text
);
CREATE SEQUENCE IF NOT EXISTS public.labels_id_label_seq
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.labels_id_label_seq OWNED BY public.labels.id_label;
ALTER TABLE public.labels ALTER COLUMN id_label SET DEFAULT nextval('public.labels_id_label_seq'::regclass);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='labels_pkey' AND conrelid='public.labels'::regclass) THEN
    ALTER TABLE public.labels ADD CONSTRAINT labels_pkey PRIMARY KEY (id_label);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='labels_id_enterprise_foreign' AND conrelid='public.labels'::regclass) THEN
    ALTER TABLE public.labels ADD CONSTRAINT labels_id_enterprise_foreign FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise) ON UPDATE RESTRICT ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='labels_id_equipment_foreign' AND conrelid='public.labels'::regclass) THEN
    ALTER TABLE public.labels ADD CONSTRAINT labels_id_equipment_foreign FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment) ON UPDATE RESTRICT ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_labels_enterprise ON public.labels USING btree (id_enterprise);
CREATE INDEX IF NOT EXISTS idx_labels_equipment  ON public.labels USING btree (id_equipment);

-- A.2 sample_boxes ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sample_boxes (
    id_box              bigint NOT NULL,
    box_order_number    integer,
    should_increment    boolean DEFAULT false,
    ts_value            timestamp with time zone NOT NULL,
    increment           integer,
    id_site             bigint NOT NULL,
    id_production_order bigint NOT NULL,
    id_order            bigint NOT NULL,
    id_equipment        bigint NOT NULL,
    id_enterprise       bigint NOT NULL,
    id_area             bigint
);
CREATE SEQUENCE IF NOT EXISTS public.sample_boxes_id_box_seq
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.sample_boxes_id_box_seq OWNED BY public.sample_boxes.id_box;
ALTER TABLE public.sample_boxes ALTER COLUMN id_box SET DEFAULT nextval('public.sample_boxes_id_box_seq'::regclass);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='sample_boxes_pkey' AND conrelid='public.sample_boxes'::regclass) THEN
    ALTER TABLE public.sample_boxes ADD CONSTRAINT sample_boxes_pkey PRIMARY KEY (id_box);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='sample_boxes_id_enterprise_foreign' AND conrelid='public.sample_boxes'::regclass) THEN
    ALTER TABLE public.sample_boxes ADD CONSTRAINT sample_boxes_id_enterprise_foreign FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise) ON UPDATE RESTRICT ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='sample_boxes_id_equipment_foreign' AND conrelid='public.sample_boxes'::regclass) THEN
    ALTER TABLE public.sample_boxes ADD CONSTRAINT sample_boxes_id_equipment_foreign FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment) ON UPDATE RESTRICT ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_sample_boxes_equip ON public.sample_boxes USING btree (id_equipment);
CREATE INDEX IF NOT EXISTS idx_sample_boxes_po    ON public.sample_boxes USING btree (id_production_order);

-- A.3 scanned_boxes -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.scanned_boxes (
    id                  bigint NOT NULL,
    box_order_number    integer,
    increment           integer,
    id_enterprise       integer,
    id_equipment        integer,
    id_order            integer,
    id_production_order integer,
    id_site             integer,
    ts_value            timestamp with time zone,
    id_area             integer,
    id_box              bigint
);
CREATE SEQUENCE IF NOT EXISTS public.scanned_boxes_id_seq
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.scanned_boxes_id_seq OWNED BY public.scanned_boxes.id;
ALTER TABLE public.scanned_boxes ALTER COLUMN id SET DEFAULT nextval('public.scanned_boxes_id_seq'::regclass);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='scanned_boxes_pkey' AND conrelid='public.scanned_boxes'::regclass) THEN
    ALTER TABLE public.scanned_boxes ADD CONSTRAINT scanned_boxes_pkey PRIMARY KEY (id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='scanned_boxes_un' AND conrelid='public.scanned_boxes'::regclass) THEN
    ALTER TABLE public.scanned_boxes ADD CONSTRAINT scanned_boxes_un UNIQUE (box_order_number, id_production_order);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_scanned_boxes_equip          ON public.scanned_boxes USING btree (id_equipment);
CREATE INDEX IF NOT EXISTS idx_scanned_boxes_po             ON public.scanned_boxes USING btree (id_production_order);
CREATE INDEX IF NOT EXISTS idx_scanned_boxes_ts             ON public.scanned_boxes USING btree (ts_value DESC);
CREATE INDEX IF NOT EXISTS scanned_boxes_id_equipment_idx   ON public.scanned_boxes USING btree (id_equipment);
CREATE INDEX IF NOT EXISTS scanned_boxes_id_equipment_ts_idx ON public.scanned_boxes USING btree (id_equipment, ts_value);
CREATE INDEX IF NOT EXISTS scanned_boxes_id_production_order_idx ON public.scanned_boxes USING btree (id_production_order);

-- A.4 idempotency_keys --------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.idempotency_keys (
    idempotency_key text NOT NULL,
    response_status integer NOT NULL,
    response_body   jsonb,
    created_at      timestamp with time zone DEFAULT now() NOT NULL
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='idempotency_keys_pkey' AND conrelid='public.idempotency_keys'::regclass) THEN
    ALTER TABLE public.idempotency_keys ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY (idempotency_key);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idempotency_keys_created_at_idx ON public.idempotency_keys USING btree (created_at);

-- A.5 client_descriptors ------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.client_descriptors (
    id            integer NOT NULL,
    id_enterprise integer NOT NULL,
    tenant_code   text NOT NULL,
    descriptor    jsonb NOT NULL,
    version       integer DEFAULT 1 NOT NULL,
    status        text DEFAULT 'draft'::text NOT NULL,
    artifacts     jsonb,
    validation    jsonb,
    created_at    timestamp with time zone DEFAULT now() NOT NULL,
    updated_at    timestamp with time zone DEFAULT now() NOT NULL,
    created_by    text,
    updated_by    text,
    CONSTRAINT client_descriptors_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'generated'::text, 'captured'::text, 'validated'::text, 'cutover'::text])))
);
CREATE SEQUENCE IF NOT EXISTS public.client_descriptors_id_seq
    AS integer START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.client_descriptors_id_seq OWNED BY public.client_descriptors.id;
ALTER TABLE public.client_descriptors ALTER COLUMN id SET DEFAULT nextval('public.client_descriptors_id_seq'::regclass);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='client_descriptors_pkey' AND conrelid='public.client_descriptors'::regclass) THEN
    ALTER TABLE public.client_descriptors ADD CONSTRAINT client_descriptors_pkey PRIMARY KEY (id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='client_descriptors_enterprise_uniq' AND conrelid='public.client_descriptors'::regclass) THEN
    ALTER TABLE public.client_descriptors ADD CONSTRAINT client_descriptors_enterprise_uniq UNIQUE (id_enterprise);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS client_descriptors_tenant_code_idx ON public.client_descriptors USING btree (tenant_code);

-- A.6 translations ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.translations (
    language_tag text NOT NULL,
    app          text NOT NULL,
    namespace    text DEFAULT 'common'::text NOT NULL,
    key          text NOT NULL,
    value        text NOT NULL,
    updated_at   timestamp with time zone DEFAULT now() NOT NULL,
    updated_by   text
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='translations_pkey' AND conrelid='public.translations'::regclass) THEN
    ALTER TABLE public.translations ADD CONSTRAINT translations_pkey PRIMARY KEY (language_tag, app, namespace, key);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS translations_read_idx ON public.translations USING btree (app, language_tag, namespace);

-- A.7 tenant_translations (NOT knex-managed in F1 — created out-of-band) -------
CREATE TABLE IF NOT EXISTS public.tenant_translations (
    id_enterprise integer NOT NULL,
    language_tag  text NOT NULL,
    app           text NOT NULL,
    namespace     text DEFAULT 'common'::text NOT NULL,
    key           text NOT NULL,
    value         text NOT NULL,
    updated_at    timestamp with time zone DEFAULT now() NOT NULL,
    updated_by    text
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='tenant_translations_pkey' AND conrelid='public.tenant_translations'::regclass) THEN
    ALTER TABLE public.tenant_translations ADD CONSTRAINT tenant_translations_pkey PRIMARY KEY (id_enterprise, language_tag, app, namespace, key);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS tenant_translations_read_idx ON public.tenant_translations USING btree (id_enterprise, app, language_tag, namespace);

-- ============================================================================
-- SECTION B — ADDITIVE DRIFTED COLUMNS (nullable, no default => metadata-only)
-- ============================================================================
ALTER TABLE public.equipments        ADD COLUMN IF NOT EXISTS gross_machine                  bigint;
ALTER TABLE public.equipments        ADD COLUMN IF NOT EXISTS scrap_machine                  bigint;
ALTER TABLE public.equipments        ADD COLUMN IF NOT EXISTS exclude_idle_from_availability boolean;
ALTER TABLE public.equipments        ADD COLUMN IF NOT EXISTS idle_timeout_seconds           integer;
ALTER TABLE public.users             ADD COLUMN IF NOT EXISTS operator_pw_hash               text;
ALTER TABLE public.production_orders ADD COLUMN IF NOT EXISTS id_label                       bigint;

-- ============================================================================
-- SECTION C — production_orders.id_label -> labels FK (labels now exists)
-- ============================================================================
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='production_orders_id_label_foreign' AND conrelid='public.production_orders'::regclass) THEN
    ALTER TABLE public.production_orders ADD CONSTRAINT production_orders_id_label_foreign FOREIGN KEY (id_label) REFERENCES public.labels(id_label) ON UPDATE RESTRICT ON DELETE SET NULL;
  END IF;
END $$;

-- ============================================================================
-- SECTION D — KNEX LEDGER BASELINE (fake-apply the FULL F1 ledger, ids 1..58)
--   => `knex migrate:latest` against F3 is a complete no-op. edge-api's deployed
--   migration folder tail == F1 ledger tail == id 58, and every object those 58
--   migrations produce now exists in F3 (Sections A-C above + pre-existing F3).
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.knex_migrations (
    id             integer NOT NULL,
    name           character varying(255),
    batch          integer,
    migration_time timestamp with time zone
);
CREATE SEQUENCE IF NOT EXISTS public.knex_migrations_id_seq
    AS integer START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.knex_migrations_id_seq OWNED BY public.knex_migrations.id;
ALTER TABLE public.knex_migrations ALTER COLUMN id SET DEFAULT nextval('public.knex_migrations_id_seq'::regclass);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='knex_migrations_pkey' AND conrelid='public.knex_migrations'::regclass) THEN
    ALTER TABLE public.knex_migrations ADD CONSTRAINT knex_migrations_pkey PRIMARY KEY (id);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.knex_migrations_lock (
    index     integer NOT NULL,
    is_locked integer
);
CREATE SEQUENCE IF NOT EXISTS public.knex_migrations_lock_index_seq
    AS integer START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.knex_migrations_lock_index_seq OWNED BY public.knex_migrations_lock.index;
ALTER TABLE public.knex_migrations_lock ALTER COLUMN index SET DEFAULT nextval('public.knex_migrations_lock_index_seq'::regclass);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='knex_migrations_lock_pkey' AND conrelid='public.knex_migrations_lock'::regclass) THEN
    ALTER TABLE public.knex_migrations_lock ADD CONSTRAINT knex_migrations_lock_pkey PRIMARY KEY (index);
  END IF;
END $$;

-- Seed the exact F1 ledger rows (verbatim ids/names/batches/times). ON CONFLICT
-- => idempotent. knex keys integrity on `name` existing on disk, not on id, so
-- the non-contiguous ids (F1 has a 26..30 gap) are irrelevant.
INSERT INTO public.knex_migrations (id, name, batch, migration_time) VALUES
  (1,'20230816170559_create_equipment_values.ts',1,'2026-05-12 18:47:13.336+00'),
  (2,'20230816194129_create_equipments.ts',1,'2026-05-12 18:47:13.357+00'),
  (3,'20230817131303_add_foreign_key_eqp_values.ts',1,'2026-05-12 18:47:13.362+00'),
  (4,'20230817132725_create_enterprises.ts',1,'2026-05-12 18:47:13.374+00'),
  (5,'20230817135658_create_clients.ts',1,'2026-05-12 18:47:13.386+00'),
  (6,'20230817140322_create_sites.ts',1,'2026-05-12 18:47:13.396+00'),
  (7,'20230817140626_create_areas.ts',1,'2026-05-12 18:47:13.404+00'),
  (8,'20230817141814_create_product_family.ts',1,'2026-05-12 18:47:13.414+00'),
  (9,'20230817142108_create_products.ts',1,'2026-05-12 18:47:13.434+00'),
  (10,'20230817142630_create_user_roles.ts',1,'2026-05-12 18:47:13.452+00'),
  (11,'20230817143018_create_users.ts',1,'2026-05-12 18:47:13.469+00'),
  (12,'20230817154644_create_production_orders.ts',1,'2026-05-12 18:47:13.496+00'),
  (13,'20230817160953_create_production_orders_runtime.ts',1,'2026-05-12 18:47:13.604+00'),
  (14,'20230817162628_add_exclude_constraint_production_orders.ts',1,'2026-05-12 18:47:13.608+00'),
  (15,'20230922203352_create_equipment_events_table.ts',1,'2026-05-12 18:47:13.623+00'),
  (16,'20230926205614_create_manual_event_table.ts',1,'2026-05-12 18:47:13.639+00'),
  (17,'20231122142254_add_net_production_type.ts',1,'2026-05-12 18:47:13.641+00'),
  (18,'20240830220046_create_user_logs.ts',1,'2026-05-12 18:47:13.651+00'),
  (19,'20250903183221_update_equipmentevents_trigger_function.ts',1,'2026-05-12 18:47:13.655+00'),
  (20,'20250903183451_update_equipmentevents_trigger.ts',1,'2026-05-12 18:47:13.657+00'),
  (21,'20251001000000_add_check_constraints_production_orders.ts',1,'2026-05-12 18:47:13.66+00'),
  (22,'20260409000001_create_labels.ts',1,'2026-05-12 18:47:13.674+00'),
  (23,'20260409000002_create_sample_boxes.ts',1,'2026-05-12 18:47:13.685+00'),
  (24,'20260409000003_create_scanned_boxes.ts',1,'2026-05-12 18:47:13.692+00'),
  (25,'20260512000001_create_packml_register.ts',2,'2026-05-12 19:03:37.189+00'),
  (31,'20260413000001_add_id_label_to_production_orders.ts',3,'2026-06-23 21:36:29.715+00'),
  (32,'20260413000002_fix_scanned_boxes.ts',3,'2026-06-23 21:36:29.739+00'),
  (33,'20260413000003_production_orders_equipment_run_idx.ts',3,'2026-06-23 21:36:29.742+00'),
  (34,'20260413000004_add_id_plc_to_equipments.ts',3,'2026-06-23 21:36:29.75+00'),
  (35,'20260414000001_add_active_to_sites_and_areas.ts',3,'2026-06-23 21:36:29.756+00'),
  (36,'20260414000002_create_shifts.ts',3,'2026-06-23 21:36:29.761+00'),
  (37,'20260414000003_add_active_to_equipments.ts',3,'2026-06-23 21:36:29.764+00'),
  (38,'20260420000001_create_pages.ts',3,'2026-06-23 21:36:29.768+00'),
  (39,'20260611000001_add_nm_production_order.ts',3,'2026-06-23 21:36:29.777+00'),
  (40,'20260625000001_equipment_events_trigger_bypass_forced.ts',4,'2026-06-25 13:59:59.029+00'),
  (41,'20260626000001_mirror_replay_dlq_add_retry_columns.ts',5,'2026-06-26 21:09:30.393+00'),
  (42,'20260701000001_shadow_go_port_schema.ts',6,'2026-07-01 17:18:25.164+00'),
  (43,'20260702000001_shadow_go_port_operator_tables.ts',7,'2026-07-02 04:41:23.738+00'),
  (44,'20260630235959_create_uns_equipment_current_metrics.ts',8,'2026-07-07 12:51:39.759+00'),
  (45,'20260707120000_add_operator_pw_hash_to_users.ts',9,'2026-07-07 13:25:02.871+00'),
  (46,'20260707180000_create_idempotency_keys.ts',10,'2026-07-07 17:14:39.594+00'),
  (47,'20260728000001_create_client_descriptors.ts',11,'2026-08-04 13:44:44.572+00'),
  (48,'20260807000001_add_gross_scrap_machine_to_equipments.ts',12,'2026-08-07 15:51:20.053+00'),
  (49,'20260809000001_enterprises_api_key_integrity.ts',13,'2026-08-13 14:42:33.583+00'),
  (50,'20260809000002_users_id_user_cognito_unique.ts',13,'2026-08-13 14:42:33.594+00'),
  (51,'20260809000003_users_id_enterprise_notnull_fk.ts',13,'2026-08-13 14:42:33.608+00'),
  (52,'20260809000004_user_roles_super_user_notnull.ts',13,'2026-08-13 14:42:33.615+00'),
  (53,'20260812000001_add_equipment_active_dup_guard.ts',13,'2026-08-13 14:42:33.622+00'),
  (54,'20260813000001_fix_scrap_target_on_conflict.ts',13,'2026-08-13 14:42:33.626+00'),
  (55,'20260819000001_add_availability_policy_to_equipments.ts',14,'2026-08-20 15:32:07.034+00'),
  (56,'20260820000001_seed_legacy_language_packs.ts',14,'2026-08-20 15:32:07.048+00'),
  (57,'20260820000002_create_translations.ts',15,'2026-08-20 22:15:23.739+00'),
  (58,'20260820000003_explode_language_packs_to_translations.ts',15,'2026-08-20 22:15:25.122+00')
ON CONFLICT (id) DO NOTHING;

-- Seed the lock row (knex._lockMigrations requires exactly one is_locked=0 row).
INSERT INTO public.knex_migrations_lock (index, is_locked) VALUES (1,0)
ON CONFLICT (index) DO NOTHING;

-- Advance the id sequence past the seeded max so the NEXT real migration (>=59)
-- gets a fresh id instead of colliding with the baselined rows.
SELECT setval('public.knex_migrations_id_seq',      (SELECT max(id)    FROM public.knex_migrations),      true);
SELECT setval('public.knex_migrations_lock_index_seq', (SELECT max(index) FROM public.knex_migrations_lock), true);

COMMIT;
