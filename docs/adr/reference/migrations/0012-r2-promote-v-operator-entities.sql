-- 0012-r2-promote-v-operator-entities.sql — ADR-0012 R2 naming cleanup
-- (APPLIED to new-prod 2026-08-12, as-executed).
--
-- Discovery: the operator-entities view existed ONLY as the version-suffixed
-- `v_operator_entities_2` — there was no canonical unsuffixed `v_operator_entities`.
-- ADR-0012 R2 ("version suffixes: promote the latest shape to the UNSUFFIXED
-- canonical name, retire siblings, keep old names as compat views") was never
-- applied to this view; the `_2` was a migration-artifact leftover.
--
-- Consumers (all keep working — no consumer was on a wrong/nonexistent name):
--   * refdata-api  /v1/operator-entities  → SELECT * FROM v_operator_entities_2
--                  (cmd/refdata-api/main.go) — hits the compat view below.
--   * v_entities_per_user_role_operator    → FROM v_operator_entities_2 v
--                  (edge-api /session; adds the topic-exploded `equipments`).
--   * Hasura tracks v_operator_entities_2 (by name) — compat view preserves it.
--
-- Technique: ALTER … RENAME preserves the EXACT definition and auto-repoints
-- every dependent view by OID (v_entities_per_user_role_operator now reads
-- `FROM v_operator_entities v` with no edit). The `_2` name is recreated as a
-- thin passthrough so refdata + Hasura are untouched. Fully reversible (see foot).
--
-- NOTE: this is pure naming hygiene. It is NOT related to the operator SPA
-- all-blue screen (= oauth2-proxy Cognito edge-gate) nor the sidebar
-- machine-vs-line binding — both diagnosed separately.

BEGIN;

ALTER VIEW v_operator_entities_2 RENAME TO v_operator_entities;

-- Compat view: keeps the legacy `_2` name resolving for refdata's runtime SQL
-- and Hasura's name-based tracking. Same 7 columns, same order.
CREATE VIEW v_operator_entities_2 AS SELECT * FROM v_operator_entities;

COMMIT;

-- ── Rollback ─────────────────────────────────────────────────────────────────
-- BEGIN;
--   DROP VIEW v_operator_entities_2;                       -- the compat passthrough
--   ALTER VIEW v_operator_entities RENAME TO v_operator_entities_2;
-- COMMIT;
