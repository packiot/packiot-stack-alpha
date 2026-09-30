---
title: read-api (refdata-api)
layer: 3
owner_area: serving
last_verified: 2026-09-28
---
# read-api (refdata-api)

> **Layer 3 · Components** — the Go read API that replaced Hasura: the operator's `/v1/*`
> routes, front4's named datasets over `serving.*` SQL, the historian door, external
> contract shims. For engineers adding a dataset or debugging a slow or empty read.
> Up: [Serving & APIs](../subsystems/serving-apis.md)

## Responsibility

Serve every dashboard and operator **read** from the analytics DB, scoped to exactly one
tenant that the server derives from the caller's credential. read-api compiles only
allowlisted SQL (named datasets and a small metric composer), stamps the tenant into both
the SQL (`$1`) and the Postgres session (`app.tenant_id` for RLS), caches hot results in
Redis, and reaches the historian for windows older than the hot store. It never writes
business data (the only writes are per-user layout JSON).

## At a glance

| | |
|---|---|
| Language / runtime | Go, single binary `read-api` (`services/read-api/cmd/refdata-api`), distroless |
| Container (staging) | `read-api`, network alias `refdata-api`, IP `172.18.0.26` |
| Port | `9104` (API, `/healthz`, `/metrics`); not host-published |
| Public route (staging) | `https://refdata.staging.packiot.app` (nginx → `172.18.0.26:9104`, no SSO gate, CORS for `https://staging.packiot.com`); operator SPAs proxy `/v1/*` to `refdata-api:9104` with an injected key |
| DB | pgbouncer → `packiot_analytics` (`REFDATA_FLOW=f3`), role **`readapi_ro`** (NOSUPERUSER, NOBYPASSRLS), pool of 5, simple query protocol |
| Historian | optional second pool (4 conns) to `hist-gateway:5432/packiot_historian` as `historian_svc` |
| Cache | app-redis (`REDIS_URL`), fail-open |
| Depends on | pgbouncer, analytics DB, Cognito JWKS, app-redis (soft), hist-gateway (soft) |
| Depended on by | front4, operator app (all tenants), csadmin/customize (some reads), edge-transformer (`/internal/resolve-device`), external integrations (`/ext/*`, `/integration/*`) |
| Production (new stack) | `compose.production.yml` service `read-api` (single DB, keys from `REFDATA_QUERY_API_KEYS`) |

## Inputs & outputs

| Route | Method | Class | What it reads |
|---|---|---|---|
| `/v1/events-timeline?topics=` | GET | tenant | `serving.events_timeline($2)` |
| `/v1/pending-downtime?topics=` | GET | tenant | `serving.pending_downtime($2)` |
| `/v1/shift-hours?topic=` | GET | tenant | `piot_get_shift_hours_by_packml_topic_2` |
| `/v1/shift-hours-by-enterprise?topic=` | GET | tenant | `piot_get_shift_hours_by_enterprise_packml_topic_2` (`?enterprise=` ignored) |
| `/v1/day-week-begin?topic=` | GET | tenant | `piot_get_day_week_begin_by_packml_topic` |
| `/v1/operator-po-list` | GET | tenant | `v_operator_po_list_setup_4` |
| `/v1/operator-po-details` | GET | tenant | `v_operator_po_details_3` |
| `/v1/operator-entities` | GET | tenant | `v_operator_entities_2` |
| `/v1/entities-per-user-role` | GET | tenant | `v_entities_per_user_role_operator` |
| `/v1/language-packs` | GET | global (auth required) | `language_packs` |
| `/v1/downtime-reasons?topics=` | GET | tenant | `equipments` ⋈ `packml_register` |
| `/v1/catalog` | GET | global | metric/dimension/grain/dataset catalog |
| `/v1/query` | POST | tenant | named dataset or metric composer (below) |
| `/v1/screen-config?user=&screen=` | GET/PUT | tenant | `identity.user_screen_config` |
| `/v1/dashboard-config?dashboard_id=[&user=]` | GET | tenant | `dashboard_config` ‖ user override (jsonb merge) |
| `/v1/historian/production-series` | POST | tenant | historian gateway, daily gross/net |
| `/v1/historian/downtime-series` | POST | tenant | historian gateway, daily downtime |
| `/internal/resolve-device?device_key=[&enterprise=]` | GET | internal (`X-Internal-Key`) | `packml_register` by `device_key` |
| `/ext/neopac/*`, `/ext/montebello/*`, `/ext/incoplast/*`, `/integration/*/:id_enterprise` | GET | external shim (own auth) | frozen customer contracts |
| `/healthz`, `/metrics` | GET | infra (no auth) | pool ping, Prometheus |

## Internal design

### Files

| File (`cmd/refdata-api/`) | Role |
|---|---|
| `main.go` | Pool, cache, route registration, the 11 legacy `/v1/*` endpoints, generic JSON row encoder |
| `auth.go` | Route manifest (every route has a class), auth middleware, exemptions |
| `auth_firebase.go`, `auth_cognito.go` | Bearer verification (Cognito only since #159), uid → tenant lookup, link-on-login |
| `auth_operator_superadmin.go` | Super-admin cross-tenant read escalation |
| `query.go` | `/v1/catalog`, `/v1/query`, screen/dashboard config, `runQueryJSON` (tenant-stamped tx) |
| `datasets.go` | The named-dataset registry (~66 datasets), windows, cache TTLs |
| `coverage.go` | Retention-aware coverage headers from `ops.retention_policy` |
| `historian.go`, `historian_split.go` | Historian endpoints and the hot/cold split |
| `external*.go` | Anti-corruption shims for external contracts (ADR-0031) |
| `internal.go` | `/internal/resolve-device` (ADR-0046) |
| `contract.go` | `--dump-contract` for the prod drift gate |
| `flow.go` | `REFDATA_FLOW` → DB name |

### Authentication and tenant resolution

Whole-mux middleware (`authMiddleware`), fail-closed, runs before any handler except the
exempt classes (infra, external shims, internal):

1. **`X-Api-Key` present** → look it up in the static map `QUERY_API_KEYS`
   (`key:enterprise,…`). Unknown key → 401; no fall-through to Bearer. This is how the
   operator SPAs authenticate (nginx injects the key per deployment).
2. **`Authorization: Bearer <Cognito ID token>`** → RS256 against the pool JWKS
   (`iss`, `aud`, `exp`) → `SELECT id_enterprise, user_roles FROM users WHERE
   id_user_cognito = $1 AND active = true AND id_enterprise IS NOT NULL`. In the analytics
   DB `users` resolves to **`identity.users`** through the database `search_path`. Cached 5
   min. Zero rows → first tries link-on-login (bind `id_user_cognito` by verified email),
   then 401. This is how front4 authenticates. A user linked only in the edge-api-side
   table but not here sees "Couldn't load workspace data".
3. **Operator super-admin escalation** (when `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED`):
   a request with the home api-key **plus** `x-operator-superadmin-token` (Cognito ID token)
   **plus** `?idEnterprise=<target>` is re-scoped to the target only if the token verifies,
   carries a verified email on the allowlist (`OPERATOR_SUPERADMIN_ALLOWLIST`, default
   `dev@packiot.com`), that email has live `user_roles.super_user`, and the target is
   active. Any failure silently keeps the home tenant.

The resolved enterprise (`customer_id`) goes into the request context. The verified user's
`id_user_role` is kept too; the two role datasets (`entities-per-user-role`,
`menu-per-user-role`) return 403 on the api-key path because they need a user.

### Tenant fence, twice

```text
 customer_id (from credential) ──▶ $1 in every tenant-scoped SQL   (primary fence)
                              └──▶ BEGIN; SELECT set_config('app.tenant_id','<id>', true);
                                    <query>; COMMIT                 (RLS co-enforcer)
```

`runQueryRows` wraps each tenant read in a transaction that stamps the RLS GUC with
`is_local = true`, which is safe under pgbouncer transaction pooling (a plain `SET` would
leak to the next borrower). Because read-api connects as `readapi_ro` (NOBYPASSRLS since
2026-09-13, migration `t276`), `FORCE ROW LEVEL SECURITY` tables (`core.equipments`,
`core.production_orders`, `core.production_targets`, `gold.equipment_oee_*`,
`gold.production_orders_runtime`) return only this tenant's rows even if a dataset forgot
its `$1`. Without the GUC they return nothing: an empty result from a `serving.*`
SECURITY INVOKER function usually means the GUC was not set.

### `/v1/query`

Body `{"dataset": "<name>", …params, "window": {"from","to"}}` → named dataset; otherwise
the legacy **metric composer** `{"metrics": [...], "dimensions": [...], "grain": "1min"|"1hour",
"from", "to", "filters"}` compiled against `agg_equipment_values_{1min,1hour}`
(metrics `net_production`, `gross_production`, `scrap`, `avg_speed`; dimensions `site`,
`area`, `equipment`, `shift`).

| Limit | Value |
|---|---|
| Composer window | 1min ≤ 7 days, 1hour ≤ 90 days; a window before the relation's retention floor → **422** pointing at the historian |
| Dataset windows | analytics datasets ≤ 400 days, event datasets ≤ 90 days |
| Row cap | 10,000 per response |
| Body | ≤ 64 KiB |
| Timeout | **40 s** for `/v1/query` (was 20 s until 2026-09-21), 15 s legacy routes, 10 s dashboard-config, 60 s historian |

Datasets are `$1`-first SQL over `serving.*` functions and views (e.g.
`serving.mission_control`, `serving.oee_score`, `serving.downtime_events_v3`,
`serving.production_orders_with_runtimes`), plus a few direct table reads (targets,
equipment info, users minus credentials, `enterprises` minus `api_key`). `GET /v1/catalog`
lists them. Every dataset is checked by tests to bind the tenant as `$1`.

Responses of windowed datasets carry `X-Data-Hot-Floor` (earliest instant the hot store can
fully answer, from `ops.retention_policy`) and `X-Data-Truncated: true` when the requested
window starts earlier.

### Cache-aside (ADR-0035)

Only named-dataset responses are cached, in app-redis, keyed
`refdata:ds:v1:<flow>:e<enterprise>:<dataset>:<sha256(sql,args)>` (tenant from the server,
never the body). TTL per dataset group:

| Group | TTL |
|---|---|
| `enterprise-config`, `settings`, `targets`, `tenant-custom` | 300 s |
| `variables-context` | 180 s |
| `live-uns-equipment` | 15 s |
| `mission-control`, `overview-detail`, `events-timeline`, `machine-speed`, `production-orders` | 20 s |
| `oee`, `downtimes-analytics`, `single-period`, `total-production`, `production-flow`, `home` | 30 s |
| `downtimes-events`, `downtimes-events-legacy` (override) | 120 s |
| anything else | 20 s |

Redis down or `REDIS_CACHE_ENABLED=false` → every read goes to the DB. Errors are never
cached. Writes elsewhere do not invalidate; staleness is bounded by the TTL.

### Historian split (PR #1474, 2026-09-28)

`POST /v1/historian/{production,downtime}-series` with `{from, to, equipment?}` (≤ 5 years).
The gateway's union views mix a DuckDB `read_parquet` (cold, S3) with a `postgres_fdw` scan
(hot) in one plan, which was slow both ways (30 cold days ≈ 25 s; 7-day downtime ≈ 24 s
without FDW pushdown). read-api now runs the halves as separate statements and merges them
in Go:

| Series | Cold side | Hot side | Split point |
|---|---|---|---|
| production | `cold.equipment_values_daily` (pre-aggregated, spike-guarded), only for EV-promoted tenants | `live.equipment_values_1hour` via FDW, summed per UTC day | `cold.ev_daily_watermark.covered_until` (whole UTC days) |
| downtime | `cold.equipment_events`, only for EE-promoted tenants and before `cold.ee_union_boundary` | `live.equipment_events` summed per UTC day | the tenant's cutover timestamp |

Both sides bind literal bounds (no `now()`, which `postgres_fdw` cannot push down) and
year/month partition-prune predicates. The equipment filter is an inline integer list
because DuckDB cannot cast a Postgres `int[]`. If the historian password is unset or the
gateway is down at boot, the endpoints return 503 and the rest of read-api is unaffected.
See [Historian gateway](historian-gateway.md).

## Configuration

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `DB_HOST` / `DB_PORT` | `pgbouncer` / `5432` | same | |
| `DB_USER` / `DB_PASSWORD` | `postgres` / — | `readapi_ro` / `.env` `READAPI_RO_PASSWORD` | Must be a NOBYPASSRLS role |
| `REFDATA_FLOW` | `f1` | `f3` | `f3` → `DB_NAME_F3` |
| `DB_NAME` / `DB_NAME_F3` | `packiot` / `packiot_analytics` | `packiot` / `packiot_analytics` | |
| `HEALTH_PORT` | `9104` | `9104` | Serving port |
| `QUERY_API_KEYS` | empty | per-tenant staging keys (demo keys for ent 2, 3, 4, 5, 2000003) | api-key → enterprise map; production keys belong in Secrets Manager |
| `COGNITO_AUTH_ENABLED` | on | `true` | Bearer path |
| `COGNITO_ISSUER`, `COGNITO_CLIENT_ID`, `COGNITO_JWKS_URL` | staging pool | same | Public identifiers |
| `FIREBASE_PROJECT_ID` | `fbpackiot` | not used | Firebase retired (#159) |
| `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | off | `true` | Read escalation |
| `OPERATOR_SUPERADMIN_ALLOWLIST` | `dev@packiot.com` | default | |
| `REDIS_CACHE_ENABLED`, `REDIS_URL` | `true`, app-redis | same | Cache-aside |
| `HIST_GW_HOST` / `_PORT` / `_USER` / `_DB` | `hist-gateway` / 5432 / `historian_svc` / `packiot_historian` | same | Historian pool |
| `HIST_GW_PASSWORD` | — | `.env` `HIST_GW_SVC_PASSWORD` (Secrets Manager `packiot/staging/historian-svc`) | Empty → historian 503 |
| `INTERNAL_API_KEY` | — | `.env` | Empty → `/internal/*` 401 |
| `EXTERNAL_NEOPAC_CUSTOMER_ID`, `EXTERNAL_MONTEBELLO_CUSTOMER_ID`, `EXTERNAL_INCOPLAST_CUSTOMER_ID` | 0 | not in compose | Owner binding per shim; 0 → shim returns 401 for everyone |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | `http://alloy:4317` | Tracing |

## Data & invariants

- **The client never names a tenant** (ADR-0027). The only exceptions are the gated
  super-admin escalation and `/internal/resolve-device` (service-to-service).
- **Every route has a class** in `routeManifest()`; the exemption set is derived from it, so
  a new route cannot silently skip auth.
- **Read-only** except `identity.user_screen_config` (created by `ensureSchema` at boot).
- **Byte-stable shapes** for the operator's `/v1/*` routes; the operator caches by URL and
  parses fixed shapes.
- **Raw JSON arrays** of row objects; pgx types are encoded as-is.

## Observability

- `http_request_duration_seconds{method,route,status}` with trace exemplars (OpenMetrics),
  `refdata_cache_requests_total`, `refdata_internal_resolve_device_total`, Go runtime.
  Prometheus job `read-api` (`read-api:9104`).
- Traces: `otelhttp` server span per request, `otelpgx` span per query, exported to Alloy.
- `/healthz` pings the pool: `{"healthy":true,"served":N,"failed":M}`.
- Logs: `query failed` (path + DB error for legacy routes), `historian query failed`,
  `read-plane flow resolved`, `external shim owner unset`, `cache ping failed`.

!!! note "The `/v1/query` 500 does not log the database error"
    On the dataset path a failed query returns `{"error":"query failed"}` without logging
    the cause. If a dataset 500s only on larger windows, suspect the timeout before the SQL.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| front4 Downtimes 500 on month view (2026-09-21) | `serving.downtime_events_v2` took 18-31 s cold (decompressed ~2 months of event chunks) > 20 s timeout | Timeout 40 s + cache 120 s (#1371); now `downtime_events_v3` reads the precomputed `serving.downtime_events_resolved` (refreshed every 2 min) |
| Every tenant read returns `[]` | GUC not stamped or role cannot see RLS tables | Check the tx wrapper; `SELECT current_setting('app.tenant_id')` inside the function |
| 401 for a front4 user | No `identity.users` row with that `id_user_cognito`, user inactive, or enterprise NULL | Link the user in the analytics DB |
| 403 on role datasets | Called with an api-key (no user) | Use a Bearer |
| 422 "window starts before …" | Composer window older than the cagg retention | Use `/v1/historian/production-series` |
| Historian 503 | `HIST_GW_PASSWORD` missing or gateway down at boot | Fix and restart read-api (the pool is built once) |
| Historian slow / OOM on the host (2026-09-28 audit) | Mixed DuckDB+FDW plans; unbounded DuckDB memory | #1474 split + gateway memory caps |
| Stale number after an edit | Cache TTL | Wait ≤ TTL, or flush the `refdata:ds:v1:*e<N>*` keys |
| Mission Control "loading forever" (2026-09-25) | `serving.mission_control` joined a real-time cagg on a computed id (18-25 s) | Fixed in SQL (#1454); time per-line subqueries with a correlated id |

## Operating it

- Deploys with the stack (`deploy-staging.yml`); image built from `services/read-api`.
- Restart after changing `.env` credentials or the historian password (both pools are
  built at boot). Recreate, don't `docker restart`, so new env applies.
- Rollback switches: `REDIS_CACHE_ENABLED=false`, `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED=false`,
  or temporarily `READAPI_RO_USER=postgres` (removes RLS co-enforcement; last resort).
- Adding a dataset: add an entry in `datasets.go` with `$1` = enterprise, a `group` (for
  TTL and coverage), a window cap if windowed, then refresh the contract golden
  (`UPDATE_GOLDEN=1 go test ./cmd/refdata-api/ -run TestContractGolden`).
- Prod drift gate before a production flip:
  `AWS_REGION=us-east-1 bash services/read-api/scripts/refdata-contract-drift-check.sh`.

## Tests

`cd services/read-api && go test ./...` (CI: `go-services.yml`; contract self-check in
`refdata-contract-drift.yml`). Tenancy tests include `TestEveryDatasetIsTenantScoped`
(`tenancy_isolation_test.go`), `TestWorkstreamADatasetsAreTenantFenced`,
`TestWorkstreamADatasetsCompileDisjointAcrossTenants`, `TestDashboardConfigSQLFencesTenant`,
`TestBearerAuthResolveDerivesTenantFromUID`, the super-admin `TestResolveTarget_*` tests,
external golden tests, and `historian_split_test.go` for the split planner and merge.

## Source map

| Path | What's there |
|---|---|
| `services/read-api/cmd/refdata-api/main.go` | Boot, legacy `/v1/*` endpoints |
| `services/read-api/cmd/refdata-api/auth*.go` | Authentication, route manifest, super-admin escalation |
| `services/read-api/cmd/refdata-api/query.go` | `/v1/query`, catalog, config routes, tenant-stamped tx |
| `services/read-api/cmd/refdata-api/datasets.go` | Dataset registry and cache TTLs |
| `services/read-api/cmd/refdata-api/historian*.go` | Historian endpoints and hot/cold split |
| `services/read-api/cmd/refdata-api/external*.go` | External contract shims |
| `services/read-api/cmd/refdata-api/internal.go` | Device-key resolver |
| `services/read-api/cmd/refdata-api/coverage.go` | Coverage headers |
| `services/read-api/internal/cache/cache.go` | Redis cache-aside |
| `services/read-api/internal/httpmetrics/`, `internal/tracing/` | RED metrics, OTel |
| `services/read-api/README.md` | Service notes (partly historical: Firebase text) |
| `db/migrations/t276-readapi-ro-nobypassrls/` | `readapi_ro` role |
| `compose.staging.yml` (`read-api`), `terraform/staging/user_data/nginx_setup.sh` (`refdata.conf`) | Deployment and routing |
