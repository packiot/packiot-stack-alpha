# db/superset — W2 embedded-Superset DB scaffolding (INERT until W2 go)

These SQL files provision the DB-side pieces for **W2 — embedded self-service
Superset** (see `docs/plans/w2-embedded-superset.md`). They are **scaffolding**:
checked in for review, **NOT wired into any auto-running boot chain** (unlike
`db/init/*.sql` which local-dev mounts, or `db/init-f3/` which prod assembles).
Apply them **by hand, staging-first, only after the W2 go decision**.

> **Why Superset, not Metabase?** The predecessor design (`docs/plans/w2-embedded-metabase.md`)
> required Metabase **Enterprise** (interactive embedding + data sandboxing are
> paid features). That licensing was deemed infeasible, so W2 was re-cut onto
> **Apache Superset** (Apache-2.0, free, self-hosted). The **curated read surface
> is BI-tool-agnostic**; what changed is the app deployment (Redis + Celery + its
> own metadata DB) and the auth/tenancy wiring (guest tokens for viewing, Cognito
> OIDC + per-tenant Superset RLS for authoring).

Apply order (against the analytics DB — the r7g `public`/F3 schema):

| File | What it does | Idempotent |
|---|---|---|
| `01-superset-ro-role.sql` | Creates `bi_owner` (NOLOGIN, **NOBYPASSRLS**) + `superset_ro` (NOLOGIN until the apply-time LOGIN+password grant) + a `bi` schema of **curated, tenant-safe SECURITY DEFINER views** owned by `bi_owner`. Every view carries `id_enterprise`. | yes |
| `02-tenant-rls.sql` | Enables Postgres **row-level security** on all five base tables behind the views + a policy keyed on the `app.tenant_id` session GUC — the DB-level **co-enforcer** beneath Superset's own RLS. | yes |
| `03-authoring-rls-mapping.optional.sql` | **OPTIONAL** — only for authoring-RLS **Strategy B** (one global Jinja RLS filter + a `bi.user_tenant` mapping table). Skip it if you use **Strategy A** (per-tenant Superset role). | yes |

**No password literal.** `01` creates `superset_ro` **NOLOGIN** — the Metabase
donor's `CREATE ROLE metabase_ro … PASSWORD 'CHANGE_ME_AT_APPLY'` is the
anti-pattern this avoids. Grant LOGIN + the real password at apply from Secrets
Manager (`packiot/<env>/app` key `superset_db_ro_password`):

```sh
psql -v pw="$SUPERSET_DB_RO_PASSWORD" -c "ALTER ROLE superset_ro LOGIN PASSWORD :'pw';"
```

## The two isolation layers (read this before you reason about safety)

1. **PRIMARY — Superset Row Level Security** (native, free). Applied on BOTH
   surfaces from the **Cognito identity**:
   - **Viewing** (embedded curated dashboards): edge-api mints a **guest token**
     (`POST /api/v1/security/guest_token/`) carrying an inline RLS rule
     `rls: [{clause: "id_enterprise = <derived>"}]`, tenant derived **server-side**
     from the Cognito JWT (never client-supplied). Landed as a real endpoint —
     `POST /api/superset/guest-token` (edge-api PR #175).
   - **Authoring** (Cognito-OIDC accounts building their own charts): a per-tenant
     RLS **filter** bound to the user (Strategy A: a `tenant_<id>` role; Strategy
     B: one global filter with a `{{ current_username() }}` subquery against
     `bi.user_tenant`). Authors are ALSO **denied SQL Lab** on the analytics DB —
     native SQL would bypass dataset RLS (see `configs/superset/*.py`).

2. **CO-ENFORCER — Postgres RLS** (`02-tenant-rls.sql`). A **genuine** per-tenant
   filter, NOT a no-op, because the `bi.*` views are SECURITY DEFINER owned by the
   **NOBYPASSRLS `bi_owner`**: reading a view runs base-table access as `bi_owner`,
   so the policies bite, keyed on the session GUC `app.tenant_id`. Stamp the GUC
   per tenant on the connection to co-enforce:
   - **(a)** per-tenant Superset "database" with `connect_args {"options": "-c app.tenant_id=<id>"}`, or
   - **(c)** a per-tenant login role `superset_ro_t<id>` with `ALTER ROLE … SET app.tenant_id='<id>'`.

   With the GUC set → RLS filters to that tenant; **unset → deny-all
   (fail-closed)**. The single pooled embed connection leaves the GUC unset, so
   the embed **viewer** path leans on the Superset guest-token clause as primary,
   with Postgres RLS as its fail-closed net; **authoring/direct** connections
   should use (a)/(c) so Postgres RLS co-enforces.

`superset_ro` has **no base-table grant at all** — only `bi_owner` does, and only
on the five curated tables. The raw ~300-table schema stays dark.

## Prove it — the isolation gate

`tests/superset/` applies these exact SQL files to an ephemeral Postgres, seeds
two tenants, and asserts per-tenant row-sets are disjoint, unset-GUC is
fail-closed, and every `bi.*` view has a tenant key + base RLS. It is a blocking
CI check (`.github/workflows/superset-rls-isolation.yml`). **No tenant sees a
chart until it is green on staging.** Run locally: `./tests/superset/run.sh`.
