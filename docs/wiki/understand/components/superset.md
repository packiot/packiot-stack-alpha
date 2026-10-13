---
title: Superset
layer: 3
owner_area: serving
last_verified: 2026-09-28
---
# Superset

> **Layer 3 · Components** — the embedded BI stack: Apache Superset containers, the `bi`
> schema it reads, the tenant fence (Superset RLS + Postgres RLS), the guest-token embed
> flow into front4, and the gotchas that broke it. For engineers touching reports,
> dashboards or BI access. Up: [Analytics DB](../subsystems/analytics-db.md)

## Responsibility

Superset serves Packiot's reports: curated dashboards embedded in front4's **Reports** page
for client users, and an authoring UI for staff. It must show each viewer only their own
tenant's rows. It reads the analytics DB exclusively through the `bi.*` views as the
NOBYPASSRLS role `superset_ro`, and the historian gateway through one dataset as
`historian_svc`. Superset's own state (users, dashboards, RLS rules, embed configs) lives in
the separate `superset` database.

## At a glance

| | |
|---|---|
| Image | `packiot/superset:4.1.1-w2`, built from `docker/superset/Dockerfile` on `apache/superset:4.1.1` (adds the Postgres driver, flask-cors, Authlib, flask-talisman) |
| Compose | `compose.superset.yml` overlay; every service has `profiles: ["superset"]`, so it starts only when `COMPOSE_PROFILES` includes `superset` |
| Containers | `superset` (gunicorn :8088, 4 workers × 20 threads, 2 GB, 1.5 CPU), `superset-worker` (Celery, 1 GB), `superset-redis` (noeviction, 256 MB), one-shots `superset-db-init` and `superset-init`; `superset-beat` commented out |
| Host (staging) | app host; `127.0.0.1:8088` behind nginx `superset.conf` at `bi.staging.packiot.app` (no oauth2 gate: it would break the iframe and the OIDC redirect) |
| Metadata DB | `superset` on the DB host, connected upstream-direct (`POSTGRES_HOST_UPSTREAM`) |
| Analytics connection | `superset_ro@<POSTGRES_HOST_UPSTREAM>:5432/<SUPERSET_ANALYTICS_DB>` — **direct, not pgbouncer**; staging 10.10.10.89/`packiot_analytics`, production must set `packiot` |
| Historian connection | `historian_union` = `historian_svc@hist-gateway:5432/packiot_historian` |
| Depends on | analytics DB, historian gateway, Cognito (authoring login), `edge-api` (guest-token broker) |
| Depended on by | front4 Reports page (`front4/src/pages/SupersetReport/index.jsx`, `@superset-ui/embedded-sdk`) |

## Inputs & outputs

| Reads | Notes |
|---|---|
| `bi.oee_shift`, `bi.oee_hourly`, `bi.production_orders`, `bi.production_order_runtime`, `bi.downtimes`, `bi.equipment_speed`, `bi.live_status`, `bi.production_by_team`, `bi.equipments`, `bi.production_targets`, `bi.scanned_boxes`, `bi.po_box_counter` | 12 datasets under `configs/superset/assets/datasets/packiot_analytics/` |
| historian `silver.equipment_values` | virtual dataset `configs/superset/assets/datasets/historian_union/ev_all.yaml`; Jinja injects the year/month prune range from the dashboard time filter |

Dashboards as code (`configs/superset/assets/dashboards/`): OEE overview (EN and PT), shift
report, total production, production orders, downtime analysis, scrap analysis, machine
speed, live status, scanned boxes.

## Internal design

### The `bi` schema

Created by `db/superset/01-superset-ro-role.sql` (views), `02-tenant-rls.sql` (policies),
`04-bi-oee-spike-guard.sql` (NULLs gross/net above 1e8 per equipment-shift in `bi.oee_shift`
so float4 sums cannot overflow on the 2026-06/07 CPACK totalizer spikes),
`05-bi-scanned-boxes.sql` (barcode views). These files are applied **by hand**, staging first;
nothing runs them automatically. The repo SQL was written against the pre-medallion
`public` names; the live views read `gold.*`, `silver.*`, `core.*` (see
[Analytics DB schemas](analytics-db-schemas.md)).

Ownership is the security mechanism. Each view is owned by `bi_owner` (NOLOGIN, NOSUPERUSER,
NOBYPASSRLS) and is **not** `security_invoker`, so base-table access runs as `bi_owner`, and
because the base tables have `FORCE ROW LEVEL SECURITY`, the tenant policy applies to the
owner. `superset_ro` has `USAGE` on `bi` (plus `serving`, `silver`, `ops` schema usage) and
`SELECT` on the `bi` views only — no base-table grants.

### Two tenant fences

| Layer | Mechanism | Applies to |
|---|---|---|
| Primary: Superset RLS | guest token carries `rls: [{clause: "id_enterprise = <n>"}]`; authoring users get a per-tenant RLS filter | every dataset query (datasets expose `id_enterprise`) |
| Co-enforcer: Postgres RLS | `DB_CONNECTION_MUTATOR` in `superset_config.py` stamps `-c app.tenant_id=<n>` as a libpq startup option; the base-table policies filter on it | analytics connection only |

The mutator derives the tenant from the caller's RLS clause with the regex
`id_enterprise\s*=\s*(\d+)`. If none is found and the caller is an authenticated, non-guest
**Admin**, it stamps the all-tenant sentinel `-1` (the regex can never yield a negative, so a
token cannot forge it). Anyone else gets no stamp, so the GUC is unset and every policy denies
(fail-closed). It matches database names `packiot`, `packiot_shadow`, `packiot_analytics`.

This is why the analytics connection must not go through pgbouncer: in transaction mode a
startup option is set once per server connection, so a pooled connection could carry another
tenant's stamp.

The historian connection has **no** Postgres co-enforcer (pg_duckdb has no session GUC on the
cold path). Superset RLS is the only fence there, so the connection has
`expose_in_sqllab: false`, DML/CTAS/CVAS off, and every chart on it must be reached through a
guest token or an authoring role with the tenant rule.

### Embed flow

```text
 front4 Reports page            edge-api                          Superset (bi.staging)
 ───────────────────            ────────                          ─────────────────────
 embedDashboard({ id: <embed uuid>, fetchGuestToken })
     ──POST /api/superset/guest-token──▶
                                tenant from the verified caller
                                (never the request body);
                                log in as the minter account
                                ──POST /api/v1/security/guest_token/──▶
                                  resources: [{type: dashboard,
                                               id: SUPERSET_OEE_DASHBOARD_UUID}]
                                  rls: [{clause: "id_enterprise = <n>"}]
                     ◀── token ─┘◀───────────────────────── signed JWT (5 min)
 iframe https://bi.staging…/embedded/<uuid> ──(guest token)──▶ GuestViewer role
                                                    referrer ∈ allow_domain_list?
                                                    chart query + RLS clause
                                                    mutator stamps app.tenant_id=<n>
                                                    ──▶ superset_ro ▶ bi.* ▶ RLS
```

- `edge-api/src/usecases/superset-embed/` needs `SUPERSET_BASE_URL`,
  `SUPERSET_GUESTTOKEN_ADMIN_USER`, `SUPERSET_GUESTTOKEN_ADMIN_PASSWORD`,
  `SUPERSET_OEE_DASHBOARD_UUID`; without them it returns 503.
- Guest tokens are signed with `SUPERSET_GUEST_TOKEN_JWT_SECRET` and expire after 300 s;
  front4 re-mints.
- Guests assume `GUEST_ROLE_NAME = "GuestViewer"`. `bootstrap_guest_role.py` gives that role
  the minimum read perms, strips the anonymous `Public` role to zero perms, and scopes the
  minter account to a `GuestTokenMinter` role once a separate human admin exists.
- `register_embed.py` pins a stable embed UUID onto the target dashboard
  (`SUPERSET_EMBED_TARGET_DASHBOARD`) and writes `allow_domain_list` from
  `SUPERSET_FRAME_ANCESTOR`.
- Embedding is allowed by CSP `frame-ancestors` (Talisman) and CORS for `FRONT4_ORIGINS`
  (parsed from the comma-separated `SUPERSET_FRAME_ANCESTOR`). Session cookies are
  `SameSite=None; Secure; Partitioned` because the iframe is cross-site.

### `superset-init` sequence (every deploy of the profile)

`superset db upgrade` → `superset init` → create the human admin (if `SUPERSET_ADMIN_*`) →
create the minter account → `bootstrap_guest_role.py` → `import_bundle.py` (stages assets and
injects `SUPERSET_DB_RO_PASSWORD` into the URI) → `superset import-dashboards` (overwrite on
stable UUIDs) → `sync_databases.py` (applies every database asset, including ones no dashboard
references, and logs the resolved `user@host/db`) → `normalize_query_context.py` (rebuilds
chart `query_context` lost by import) → `harden_dashboard_roles.py` → `register_embed.py`.

## Configuration

Names only; values come from Secrets Manager `packiot/<env>/app` via `app_init.sh` into `.env`.

| Variable | Effect |
|---|---|
| `SUPERSET_SECRET_KEY`, `SUPERSET_GUEST_TOKEN_JWT_SECRET` | must be identical across web, worker, init |
| `SUPERSET_DB_PASSWORD` | `superset` metadata role |
| `SUPERSET_DB_RO_PASSWORD` | `superset_ro`, injected into the analytics URI at import |
| `POSTGRES_HOST_UPSTREAM`, `SUPERSET_ANALYTICS_DB` | analytics host/db for the URI template (`__ANALYTICS_HOST__`, `__ANALYTICS_DB__`); default db `packiot_analytics`, production `packiot` |
| `SUPERSET_GUESTTOKEN_ADMIN_USER` / `_PASSWORD` | minter service account (shared with edge-api) |
| `SUPERSET_ADMIN_USER` / `_PASSWORD` | durable human admin |
| `SUPERSET_FRAME_ANCESTOR` | comma-separated front4 origins (staging: `https://staging.packiot.com,https://front.staging.packiot.app`) |
| `SUPERSET_OEE_DASHBOARD_UUID`, `SUPERSET_EMBED_TARGET_DASHBOARD` | embed UUID and which dashboard carries it |
| `SUPERSET_COGNITO_ISSUER`, `_CLIENT_ID`, `_CLIENT_SECRET`, `SUPERSET_AUTH_MODE` | OIDC login for authors (`oauth` mode) |
| `HIST_GW_SVC_PASSWORD` | `historian_svc`, for the historian connection |

In `superset_config.py`: `ROW_LIMIT = 50000`, `SQL_MAX_ROW = 100000`, feature flags
`EMBEDDED_SUPERSET`, `DASHBOARD_RBAC`, `ALERT_REPORTS` on, `GLOBAL_ASYNC_QUERIES` off,
`WTF_CSRF_ENABLED = True`, `ENABLE_PROXY_FIX = True`.

## Data & invariants

- `superset_ro` can read only `bi.*`; the raw schemas stay dark.
- No stamp ⇒ zero rows. A misconfiguration fails closed, never open.
- `allow_domain_list` is a comma-separated **string**.
- SQL Lab is not exposed on either data connection.

## Observability

- Health: `curl -fsS http://127.0.0.1:8088/health` (container healthcheck).
- For embed errors, read the Superset container log traceback first; it names the check that
  failed.
- `sync_databases.py` prints each connection's resolved `user@host/db` on every init.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Embed 403 / "Issue 1011" for every origin (2026-09-21) | Reports iframe never renders | `register_embed.py` assigned a Python list to the Text column `allow_domain_list`; psycopg2 stored the array literal `{https://…}`; Superset splits on commas and `same_origin` saw a netloc of `''` (`superset/embedded/view.py` line 67) | store a comma-joined string (PR #1363); fixed live with an `UPDATE embedded_dashboards` |
| Empty charts for every tenant | 0 rows everywhere | GUC not stamped (connection routed through pgbouncer, or DB name not in `_ANALYTICS_DB_NAMES`) | direct connection; check the name tuple |
| "Empty" when probing as superuser | a DBA sees 0 rows through `bi.*` | definer view + FORCE RLS + no GUC | test as `superset_ro` with `-c app.tenant_id=<n>` |
| Admin sees blank dashboards | admin session without sentinel | not a native `Admin` role | grant Admin or use a guest token |
| `historian_union` broken silently (found 2026-09-24) | historian dataset errors | the connection was hand-made (`postgres@…/postgres`) and never imported; DB later renamed | `sync_databases.py` (#1411) |
| Charts error after import | `GET /chart/<id>/data/` fails | `import-dashboards` drops `query_context`; raw table `params.all_columns` must equal `query_context.columns` (2026-09-21, #1370) | `normalize_query_context.py` |
| float overflow in KPI sums | `NumericValueOutOfRange` | CPACK totalizer spikes (1e15–1e23) in `gold.equipment_oee_shift` summed as float4 | `04-bi-oee-spike-guard.sql` |
| New env not applied | old CSP/origins still served | `docker restart` keeps creation-time env | recreate with `docker compose … up -d` |
| Stale config file (P7, 2026-09-24) | edited config ignored | single-file bind mount pinned the old inode | whole-directory mount `./configs/superset:/app/pythonpath:ro` |
| Recreating a `bi` view as superuser | tenant fence changes | owner becomes `postgres` (BYPASSRLS) | `ALTER VIEW bi.<v> OWNER TO bi_owner` after every recreate |

## Operating it

Build and (re)create on staging (the deploy workflow builds with both files; the profile
decides what runs):

```sh
cd /opt/packiot
docker compose -p stack -f compose.staging.yml -f compose.superset.yml --profile superset up -d
```

Faithful isolation probe (read-only):

```sh
psql "host=10.10.10.89 dbname=packiot_analytics user=superset_ro options='-c app.tenant_id=5'" \
  -c "SELECT count(*) FROM bi.oee_shift"
```

Change a `bi` view: `CREATE OR REPLACE VIEW` cannot reorder or insert columns, so add new
columns at the end or `DROP` + `CREATE`; then `ALTER VIEW … OWNER TO bi_owner` and
`GRANT SELECT … TO superset_ro`; re-run `tests/superset/run.sh`.

Runbook for first go-live: `docs/superset-golive-runbook.md`.

## Tests

| Test | What | Run |
|---|---|---|
| `tests/superset/test_superset_tenant_isolation.py` | applies `db/superset/*.sql` to an ephemeral Postgres, seeds two tenants, asserts disjoint row sets, unset-GUC deny, every `bi` view has a tenant key and base RLS | `./tests/superset/run.sh`; CI `.github/workflows/superset-rls-isolation.yml` |
| edge-api `superset-embed.*.spec.ts` | broker auth, tenant derivation, config gating | `npm test` in `edge-api` |

## Source map

| Path | What's there |
|---|---|
| `compose.superset.yml` | services, limits, init sequence |
| `docker/superset/Dockerfile` | derived image |
| `configs/superset/superset_config.py` | auth, CSP/CORS, cookies, RLS mutator |
| `configs/superset/bootstrap_guest_role.py`, `harden_dashboard_roles.py` | roles and RBAC |
| `configs/superset/register_embed.py` | embed UUID and `allow_domain_list` |
| `configs/superset/import_bundle.py`, `sync_databases.py`, `normalize_query_context.py` | dashboards-as-code import |
| `configs/superset/assets/` | databases, datasets, charts, dashboards |
| `db/superset/01…05-*.sql`, `db/superset/README.md` | `bi` schema, roles, RLS |
| `tests/superset/` | isolation gate |
| `edge-api/src/usecases/superset-embed/` (separate repo) | guest-token broker |
| `front4/src/pages/SupersetReport/index.jsx` (separate repo) | embed client |
| `terraform/staging/dns.tf` (`bi` record) | `bi.staging.packiot.app` |
