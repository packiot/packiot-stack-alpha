# db/metabase — W2 embedded-Metabase DB scaffolding (INERT until W2 go)

These SQL files provision the DB-side pieces for **W2 — embedded self-service
Metabase** (see `docs/plans/w2-embedded-metabase.md`). They are **scaffolding**:
checked in for review, **NOT wired into any auto-running boot chain** (unlike
`db/init/*.sql` which local-dev mounts, or `db/init-f3/` which prod assembles).
Apply them **by hand, staging-first, only after the W2 go decision**.

Apply order (against the analytics DB — the r7g `public`/F3 schema):

| File | What it does | Idempotent |
|---|---|---|
| `01-metabase-ro-role.sql` | Creates the `metabase_ro` least-privilege login role + a `bi` schema of **curated, tenant-safe views** Metabase reads (never base tables). | yes |
| `02-tenant-rls.sql` | Enables Postgres **row-level security** on the representative analytics tables + a policy keyed on the `app.tenant_id` session GUC — the DB-level backstop beneath Metabase's own data-sandbox. | yes |

## The two isolation layers (read this before you reason about safety)

1. **PRIMARY — Metabase data sandbox** (Enterprise/Pro). Every embedded user
   carries an `id_enterprise` **login attribute** sourced from the SSO JWT
   (minted by edge-api from the Cognito identity — see the spec §2). Metabase
   rewrites every query for a sandboxed group to filter on that attribute. This
   is what makes self-service authoring tenant-safe: even a user building a
   brand-new question only ever sees their own rows.

2. **BACKSTOP — Postgres RLS** (`02-tenant-rls.sql`). Defends the DB itself if
   Metabase's sandbox is ever misconfigured, or against any *other* client that
   connects as `metabase_ro`. **Caveat (load-bearing):** RLS bites only when the
   *connection* carries the tenant in `app.tenant_id`. A single shared Metabase
   connection pool does **not** set that GUC per query, so under the default
   one-connection topology RLS falls back to its `USING (false)`-style deny and
   the sandbox is doing the real work. To make RLS *also* enforce per-tenant you
   need a **per-tenant DB connection** (JDBC `?options=-c app.tenant_id=<n>`) or
   a per-tenant Metabase database entry. See the spec §3 + §6 open questions.

Nothing here grants write access. `metabase_ro` is `SELECT`-only on the `bi`
schema and nothing else.
