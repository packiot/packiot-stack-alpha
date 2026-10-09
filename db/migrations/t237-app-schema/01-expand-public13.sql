-- t237 P-app.1 · EXPAND — move the 13 pure-public auth/i18n/config/ops tables
-- public → schema `app`, each behind an auto-updatable public shim view.
--
-- Deploy-free: no running service has an unqualified CREATE-IF-NOT-EXISTS for any
-- of these 13 (verified: only cursor.go[mirror_replay_cursor] + query.go
-- [user_screen_config] self-heal, and those are the 2 GOLD→APP tables handled in
-- P-app.2). edge-api creates users/user_logs/… via ledger-gated knex one-shots
-- (not re-run on staging, not on app-restart) → no bootstrap-shadow this phase.
-- All writers use unqualified names (search_path-absorbed); all UPSERTs are
-- col-target (no ON CONSTRAINT) → shim-safe. No function references any of the 13
-- by table name (the enterprise-06 SAP fossil's `labels` match is a CTE, not the table).
--
-- Owned sequences follow the table by OID (see P-barcode log). Dependent serving/bi
-- views + FKs + triggers all bind by OID and follow automatically.
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE SCHEMA IF NOT EXISTS app;

ALTER TABLE public.users                  SET SCHEMA app;
ALTER TABLE public.user_roles             SET SCHEMA app;
ALTER TABLE public.user_logs              SET SCHEMA app;
ALTER TABLE public.translations           SET SCHEMA app;
ALTER TABLE public.tenant_translations    SET SCHEMA app;
ALTER TABLE public.language_packs         SET SCHEMA app;
ALTER TABLE public.pages                  SET SCHEMA app;
ALTER TABLE public.dashboard_config       SET SCHEMA app;
ALTER TABLE public.labels                 SET SCHEMA app;
ALTER TABLE public.label_formats          SET SCHEMA app;
ALTER TABLE public.idempotency_keys       SET SCHEMA app;
ALTER TABLE public.function_execution_log SET SCHEMA app;
ALTER TABLE public.capture_observations   SET SCHEMA app;

CREATE VIEW public.users                  AS SELECT * FROM app.users;
CREATE VIEW public.user_roles             AS SELECT * FROM app.user_roles;
CREATE VIEW public.user_logs              AS SELECT * FROM app.user_logs;
CREATE VIEW public.translations           AS SELECT * FROM app.translations;
CREATE VIEW public.tenant_translations    AS SELECT * FROM app.tenant_translations;
CREATE VIEW public.language_packs         AS SELECT * FROM app.language_packs;
CREATE VIEW public.pages                  AS SELECT * FROM app.pages;
CREATE VIEW public.dashboard_config       AS SELECT * FROM app.dashboard_config;
CREATE VIEW public.labels                 AS SELECT * FROM app.labels;
CREATE VIEW public.label_formats          AS SELECT * FROM app.label_formats;
CREATE VIEW public.idempotency_keys       AS SELECT * FROM app.idempotency_keys;
CREATE VIEW public.function_execution_log AS SELECT * FROM app.function_execution_log;
CREATE VIEW public.capture_observations   AS SELECT * FROM app.capture_observations;

COMMIT;
