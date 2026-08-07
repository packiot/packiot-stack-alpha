# db/superset — W2 embedded-Superset DB scaffolding (INERT until W2 go)

These SQL files provision the DB-side pieces for **W2 — embedded self-service
Superset** (see `docs/plans/w2-embedded-superset.md`). They are **scaffolding**:
checked in for review, **NOT wired into any auto-running boot chain** (unlike
`db/init/*.sql` which local-dev mounts, or `db/init-f3/` which prod assembles).
Apply them **by hand, staging-first, only after the W2 go decision**.

> **Why Superset, not Metabase?** The predecessor design (`db/metabase/`,
> `docs/plans/w2-embedded-metabase.md`) required Metabase **Enterprise**
> (interactive embedding + data sandboxing are paid features). That licensing was
> deemed infeasible, so W2 was re-cut onto **Apache Superset** (Apache-2.0, free,
> self-hosted). The **curated read surface below is BI-tool-agnostic and ports
> 1:1** — only the login role name changes (`metabase_ro` → `superset_ro`). What
> changes is the app deployment (Superset needs Redis + Celery + its own metadata
> DB) and the auth/tenancy wiring (guest tokens for viewing, Cognito OIDC +
> per-tenant Superset RLS for authoring). See the spec.

Apply order (against the analytics DB — the r7g `public`/F3 schema):

| File | What it does | Idempotent |
|---|---|---|
| `01-superset-ro-role.sql` | Creates the `superset_ro` least-privilege login role + a `bi` schema of **curated, tenant-safe views** Superset reads (never base tables). | yes |
| `02-tenant-rls.sql` | Enables Postgres **row-level security** on the representative analytics tables + a policy keyed on the `app.tenant_id` session GUC — the DB-level backstop beneath Superset's own RLS. | yes |
| `03-authoring-rls-mapping.optional.sql` | **OPTIONAL** — only for authoring-RLS **Strategy B** (one global Jinja RLS filter + a `bi.user_tenant` mapping table). Skip it if you use **Strategy A** (per-tenant Superset role). | yes |

> **Port note / cleanup:** `bi.oee_shift` in the Metabase original self-joined
> `equipments` twice (`eq` for the name, `e` for `id_enterprise`). That was
> redundant — the port collapses it to a single join keyed on `eq.id_enterprise`.
> Semantically identical, one fewer join.

## The two isolation layers (read this before you reason about safety)

1. **PRIMARY — Superset Row Level Security** (native, free). Applied on BOTH
   surfaces:
   - **Viewing** (embedded curated dashboards): edge-api mints a **guest token**
     (`POST /api/v1/security/guest_token/`) carrying an inline RLS rule
     `rls: [{clause: "id_enterprise = <derived>"}]`, where the tenant is derived
     **server-side from the Cognito JWT** (never client-supplied). Superset ANDs
     that clause into every query the embedded dashboard issues.
   - **Authoring** (Cognito-OIDC Superset accounts building their own charts): a
     per-tenant RLS **filter** bound to the user (Strategy A: a `tenant_<id>` role
     with a literal `id_enterprise = <id>` filter; or Strategy B: one global
     filter with a `{{ current_username() }}` Jinja subquery against
     `bi.user_tenant`). Every query an author runs — including brand-new
     charts/SQL-Lab queries on the `bi.*` datasets — is rewritten with that
     predicate. This is what makes self-service authoring tenant-safe.

2. **BACKSTOP — Postgres RLS** (`02-tenant-rls.sql`). Defends the DB itself if
   Superset's RLS is ever misconfigured, or against any *other* client that
   connects as `superset_ro`. **Caveat (load-bearing):** RLS bites only when the
   *connection* carries the tenant in `app.tenant_id`. Superset uses **one pooled
   SQLAlchemy connection per registered database**, shared across all users and
   guest tokens — it does **not** set that GUC per query. So under the default
   single-connection topology, Postgres RLS falls back to its fail-closed deny
   (`current_tenant()` → NULL → zero rows) and **Superset RLS is doing the real
   per-tenant work**. To make Postgres RLS *also* co-enforce you need a
   **per-tenant DB connection** (`?options=-c app.tenant_id=<n>`) or a per-tenant
   Superset database entry. See the spec §3 + §6 open questions.

Nothing here grants write access. `superset_ro` is `SELECT`-only on the `bi`
schema (plus `SELECT` on `bi.user_tenant` if Strategy B is used) and nothing else.
