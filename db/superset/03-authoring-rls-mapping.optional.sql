-- db/superset/03-authoring-rls-mapping.optional.sql
-- W2 embedded-Superset scaffolding — OPTIONAL, INERT until the W2 go decision.
-- Apply by hand ONLY if you choose the "single RLS filter + Jinja" authoring
-- strategy over the "per-tenant role" strategy. See docs/plans/w2-embedded-superset.md §2.2.
--
-- ── The problem this solves ──────────────────────────────────────────────────
-- Superset's GUEST token (viewers) carries its RLS clause inline — edge-api mints
-- `rls: [{clause: "id_enterprise = <derived>"}]` per request, so viewing needs no
-- DB state. But AUTHORING users log in via Cognito OIDC and get a REAL Superset
-- account; their per-tenant filter must be bound to the account, not a token.
-- Two ways to bind it (the spec compares them):
--
--   STRATEGY A (default, no SQL here): one Superset ROLE per tenant (`tenant_<id>`)
--     each with a literal RLS filter `id_enterprise = <id>`, auto-created + assigned
--     by the custom security manager on first OIDC login. Zero analytics-DB state.
--     Cost: a role + filter per onboarded tenant (role explosion at scale).
--
--   STRATEGY B (this file): ONE global RLS filter whose clause is a Jinja
--     subquery against a mapping table, so a single filter serves ALL tenants:
--         id_enterprise IN (
--           SELECT id_enterprise FROM bi.user_tenant
--            WHERE username = '{{ current_username() }}')
--     Superset renders `{{ current_username() }}` to the logged-in user at query
--     time; no per-tenant role needed. Cost: this mapping table must be kept in
--     sync (the security manager, or edge-api during onboarding, upserts a row
--     per authoring user → their id_enterprise).
--
-- Pick ONE. This file provisions Strategy B's mapping table. If you use Strategy
-- A, do NOT apply this file.

-- ── Mapping table: authoring username → id_enterprise ────────────────────────
CREATE TABLE IF NOT EXISTS bi.user_tenant (
    username      text PRIMARY KEY,   -- the Superset username (= Cognito email/sub used at login)
    id_enterprise int  NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE bi.user_tenant IS
  'W2 authoring-RLS (Strategy B): maps a Superset authoring account to its tenant. '
  'Read by the global RLS Jinja filter via current_username(). Upserted per user at '
  'onboarding / first OIDC login. NOT used by the guest-token (viewer) path.';

-- superset_ro must READ it (the RLS subquery runs as superset_ro). SELECT only —
-- the mapping is populated out-of-band (edge-api onboarding or the security
-- manager), never by the read role.
GRANT SELECT ON bi.user_tenant TO superset_ro;

-- Example upsert the onboarding path would run (as the owner, NOT superset_ro):
--   INSERT INTO bi.user_tenant (username, id_enterprise) VALUES ('ana@acme.com', 42)
--   ON CONFLICT (username) DO UPDATE SET id_enterprise = EXCLUDED.id_enterprise,
--                                        updated_at    = now();
