-- 09-packml-register-device-key.sql — ADR-0046 §2 declared equipment identity.
-- __SCH__ = target schema (public on packiot_shadow / F3). Idempotent.
--
-- CONTEXT. ADR-0046 (edge-source topic contract §2 "identity is DECLARED at birth,
-- never derived") makes each equipment carry a STABLE `device_key` — a flat string
-- the stack resolves to id_equipment via packml_register, instead of string-parsing
-- a metric name at DATA time. Task #18 promotes device_key to a first-class field:
-- the client descriptor now DECLARES it (clientdescriptor.Equipment.device_key),
-- onboard-gen emits it in the register INSERT, and the sparkplug-agent's definitive
-- birth stamps the declared value onto properties["device_key"].
--
-- This migration adds the persistence + the identity guard:
--   (1) packml_register.device_key TEXT — the declared identity column. Nullable:
--       legacy rows created before ADR-0046 keep NULL and still resolve by topic
--       (the birth side's derivation bridge covers them), so this is additive and
--       backward-compatible — no backfill, no rewrite.
--   (2) a PARTIAL UNIQUE index on (id_enterprise, device_key) WHERE device_key IS
--       NOT NULL — one declared key per tenant (the cross-tenant guard is the
--       enterprise scope, matching packml_register.id_enterprise). Partial so the
--       many NULL-device_key legacy rows are exempt from the uniqueness constraint.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + CREATE UNIQUE INDEX IF NOT EXISTS, so a
-- re-run (or a run against a DB that already has the column) is a no-op.
--
-- Like the sibling db/init migrations this file is __SCH__-parameterized; the
-- greenfield F3 loader substitutes __SCH__→public. packml_register's DDL also lives
-- in db/init/00-schema.sql (dev bootstrap, which carries the same column + index);
-- staging/prod apply this migration through their own lineage (edge-node-red),
-- exactly as packml_register itself is managed.

ALTER TABLE __SCH__.packml_register
    ADD COLUMN IF NOT EXISTS device_key TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pr_enterprise_device_key
    ON __SCH__.packml_register (id_enterprise, device_key)
    WHERE device_key IS NOT NULL;
