---
title: edge-api
layer: 3
owner_area: serving
last_verified: 2026-10-13
---
# edge-api

> **Layer 3 · Components** — the NestJS write and control-plane API: operator actions (POs,
> downtimes, scans), CS-Admin configuration and onboarding, edge box operations over AWS SSM,
> BI token brokering. For engineers changing an endpoint or chasing a 401/403/404/400.
> Up: [Serving & APIs](../subsystems/serving-apis.md) ·
> [README](https://github.com/packiot/edge-api/blob/staging/README.md) ·
> [API reference](../../reference/api/edge-api.md) ·
> [Service catalog](../../reference/service-catalog.md)

## Responsibility

edge-api is the **only writer of operational state** in the new stack that a human can
trigger: production-order lifecycle, downtime classification, manual downtimes, box scans,
tenant configuration (hierarchy, shifts, users, targets, reasons), onboarding artifacts and
edge-box operations. It authenticates every `/api/*` call, derives the caller's tenant
server-side, fences the target row to that tenant, performs the write and records an audit
row in `user_logs`. It does not compute OEE and does not serve the dashboards' read models
(that is [read-api](read-api.md)).

## At a glance

| | |
|---|---|
| Language / runtime | TypeScript, NestJS 10, Node (alpine image), pg-promise |
| Repo path | `edge-api/` (git submodule, own repo `packiot/edge-api`, deploys via submodule bump) |
| Container (staging) | `stack-edge-api-1`, compose service `edge-api`, IP `172.18.0.3` |
| Build | `edge-api/Dockerfile`, target `production` |
| Host (staging) | app host (`packiot-staging-app`) |
| Port | `8080`, published on `127.0.0.1:8080` only; public via nginx `api.staging.packiot.app` (`/api/*`, `/session*`) and each SPA's nginx |
| Health | `GET /health` (outside `/api`, no auth) → `{status: ok}`; docker healthcheck every 30 s |
| Docs | OpenAPI document at `/packiot/docs-json`, read-only Swagger UI at `/packiot/docs` (both behind the cs-admin SSO gate on `api.staging.packiot.app`); 188 operations, rendered as the [edge-api reference](../../reference/api/edge-api.md) |
| Metrics | `GET /metrics` (OpenMetrics, `http_request_duration_seconds{method,route,status}` with exemplars) |
| Depends on | pgbouncer → `packiot_analytics`; Cognito JWKS; AWS SSM + Cognito + Secrets Manager (instance role); `edge-session-broker`; `sparkplug-decoder` onboard server; Superset; RabbitMQ (commands, optional); GitHub API (edge bundles) |
| Depended on by | operator app, front4, csadmin, customize, barcode app, operator-gateway, (retired) mirror-worker |
| Production (new stack) | `compose.production.yml` service `edge-api` against the single F3 database (`POSTGRES_DB`) |

## Inputs & outputs

| Kind | Object |
|---|---|
| HTTP in | `/api/*` (authenticated), `/session*` (own Cognito auth), `/health`, `/metrics`, `/packiot/docs` + `/packiot/docs-json`, WebSocket upgrade for box shells |
| DB writes | `core.production_orders`, `gold.production_orders_runtime`, `silver.equipment_events`, `equipment_events_man`, `bronze.box_scans`, `gold.po_box_counter`, `scanned_boxes`, `sample_boxes`, hierarchy/config tables, `identity.users`/roles, `config.production_targets`, `user_logs`, `idempotency_keys` |
| DB reads | the same plus `enterprises` (api-key lookup), `packml_register`, live telemetry for `plc-status` |
| Out | AWS SSM `CreateActivation`/`SendCommand`/`StartSession`; Cognito admin APIs; Superset guest-token API; Power BI; GitHub workflow dispatch; RabbitMQ command exchange; `sparkplug-decoder:9105/v1/onboard/*` |

## Internal design

### Module map (vertical slices)

Each feature is `src/usecases/<domain>/<feature>/{controller,service,module,dto}` with a DAO
in `src/data/DAO/<entity>/`. `src/app.module.ts` imports about 120 feature modules.

| Domain (`src/usecases/…`) | Routes (prefix) | Who calls it |
|---|---|---|
| `session/login` | `/session`, `/session/switch`, `/session/enterprises` | operator app login and super-admin tenant switch |
| `production-orders` | `/api/production-orders/{create,create-and-start,start,stop,setup,change-status,change-time,replace,delete,current}`, `/api/admin/production-orders/csv/{validate,import}` | operator app, barcode app (`current`), operator-gateway, ERP connector (CSV import) |
| `out-of-service` | `/api/out-of-service` (+ `/edit`, `/delete`) | csadmin (planned not-in-use windows) |
| `downtimes` | `/api/downtimes` (upsert base event), `/justify`, `/split`, `/split-manual-downtime`, `/create-manual-event`, `/edit-manual-event`, `/delete-manual-event`, `GET /pending`, `/justified`, `/line-member-stops` | operator app, operator-gateway |
| `scanned-boxes`, `samples`, `labels` | `/api/scanned-boxes`, `/api/samples/*`, `/api/labels` | barcode app |
| `enterprises`, `sites`, `areas`, `equipments`, `lines`, `entities`, `teams` | `/api/<entity>` (GET), `/api/<entity>/{create,edit,delete}` (POST), `/api/equipments/:id/{reasons,move}`, `/api/entities/tree` | csadmin, customize, front4 settings |
| `packml-register`, `packml-config` | `/api/packml-register/*`, `/api/packml-config/generate` | csadmin |
| `shifts`, `shift-hours` | `/api/shifts/*`, `/api/shift-hours/*` | csadmin |
| `users`, `user-roles`, `pages`, `cognito-users` | `/api/users/*`, `/api/user-roles/*`, `/api/pages`, `/api/cognito-users` | csadmin, front4 settings |
| `production-targets` | `/api/production-targets` (+ `/scrap`, `/custom`, `/custom/delete`) | csadmin, front4 |
| `downtime-reasons`, `equipments/*/reasons` | `/api/admin/downtime-reasons` (+ `/upload`, `/download/:idEquipment`) | csadmin |
| `language-packs`, `i18n` | `/api/language-packs/*`, `/api/i18n/*` | all SPAs |
| `plc-status` | `/api/plc-status`, `/plc-probe`, `/:idEnterprise/agent-health` | csadmin, front4 |
| `superset-embed`, `integrations/powerbi` | `/api/superset/guest-token`, `/api/admin/integrations/powerbi/*` | front4 Reports |
| `edge-ssm` | `/api/edge-ssm/*` (18 routes: activation, status, deploy, deploy-bundle, deploy-onprem, apply-agent-config, health, logs, restart, bootstrap, deregister, connect, session, webui) | csadmin Box Ops |
| `edge-bundle` | `/api/edge-bundle/{generate,deploy,runs,download}` | csadmin |
| `commands` | `/api/commands/{param-write,po-setup}` | edge command channel (RabbitMQ) |
| `onboarding` | `/api/onboarding/*` (descriptor, generate, simulate, validate, readiness, capture, cutover, apply-register, apply-line-meters, operator-edge, barcode-edge, onprem-offline, reset, …) | csadmin, customize |
| `promote` | `/api/promote/{plan,bundle,apply}` | staging → production config promotion (dark) |
| `teardown` | `/api/teardown/{plan,telemetry,config,shifts,hierarchy,identity,box}` | csadmin (client removal) |

The full list with methods, bodies and errors is the generated
[edge-api reference](../../reference/api/edge-api.md).

### OpenAPI contract

The document (tags, security schemes, servers) is built once in `src/openapi/` and shared by
three consumers: the served `/packiot/docs(-json)`, `npm run openapi:export` (writes
`openapi/edge-api.openapi.json`), and the completeness test `src/openapi/openapi.spec.ts`,
which builds the real document from `AppModule` with stubbed DB adapters and fails when an
operation lacks an id, summary, tag, security, examples or error descriptions, or when the
committed export is stale. The stack repo's `make openapi` copies that file from the
**pinned** submodule commit into `docs/api/openapi/edge-api.openapi.json`, which the wiki
and the staging API portal (`/docs/`, proxied from `/packiot/docs-json`) render. Swagger UI
runs with `supportedSubmitMethods: []`, so it never sends requests.

### Request pipeline

```text
 request ─▶ MetricsMiddleware ─▶ AuthMiddleware ─▶ RequestLoggerMiddleware   (only /api/*)
          ─▶ OperatorWriteBlockMiddleware (staging mirror tenant; listed write routes only)
          ─▶ CsAdminRouteGuard (global) ─▶ per-route guards (CsAdminGuard, feature flags)
          ─▶ ValidationPipe (transform, whitelist) ─▶ IdempotencyInterceptor (global)
          ─▶ controller: tenant = callerEnterpriseId(res); TenantFence.assert…()
          ─▶ service ─▶ DAO (pg-promise) ─▶ res.locals.logData ─▶ user_logs on 'finish'
```

The middlewares are applied to `/api/*` except `/api/edge-ssm/webui/*` (the embedded
Node-RED reverse proxy, authenticated by a one-time ticket cookie). `/session*`, `/health`
and `/metrics` are outside the auth middleware.

### Authentication (`src/middleware/auth.middleware.ts`)

| Path taken | Condition | Tenant published in `res.locals.callerEnterpriseId` |
|---|---|---|
| **Bearer (CS-Admin target)** | `AUTH_BEARER_ENABLED`, a Bearer JWT verified against the Cognito JWKS, `cognito:groups` contains `EDGE_API_CS_ADMIN_GROUP` (default `cs-admin`), `EDGE_API_COGNITO_AUTH_ENABLED=true`, and `?idEnterprise=N` | `N` (honoured); also `isCsAdmin=true`, `actingUser=<sub>` |
| **Bearer (regular user)** | verified JWT, no CS target | the user's enterprise from `users` by `id_user_cognito` (active user of an active enterprise). First Cognito login links `id_user_cognito` by verified email, then re-resolves. No row → 401 |
| **api-key** | no Bearer; `x-api-key` header (deprecated `?token=` still accepted and logged) | the enterprise that owns the key (`enterprises.api_key`, `active=true`). With `?idEnterprise=`, the key must belong to that enterprise |
| **api-key + operator super-admin** | `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED`, key valid, `?idEnterprise=` ≠ home, header `x-operator-superadmin-token` = Cognito ID token of a live `user_roles.super_user` on `OPERATOR_SUPERADMIN_ALLOWLIST` (default `dev@packiot.com`), target active | the target; otherwise silently locked to the key's home tenant |

A present but invalid Bearer is a 401 and is **never** downgraded to the api-key path. This
is why the operator SPA's nginx strips `Authorization` before forwarding `/api/*` and
injects the tenant key instead.

### Authorization

- **`callerEnterpriseId(res)`** (`src/shared/tenant-fence/caller-enterprise.ts`) is the only
  accessor controllers may use for the tenant. It throws 401 if the middleware did not set
  a positive integer. Never read `req.query.idEnterprise` or a body `idEnterprise`.
- **`TenantFence`** (`src/shared/tenant-fence/tenant-fence.ts`) runs a guarding
  `SELECT 1 … WHERE <target id> AND id_enterprise = $caller` before a mutation:
  `assertProductionOrder`, `assertEquipment`, `assertEquipmentEvent` (on the analytics
  adapter, joined through `equipments`), `assertManualEvent`, role fences. Zero rows → **404**,
  not 403, so another tenant's rows do not even appear to exist.
- **Mirror-tenant write block** (`src/shared/operator-write-block/`, edge-api #298/#299,
  staging only). For enterprises in `OPERATOR_WRITE_BLOCKED_ENTERPRISES` (staging: `3`, which
  the legacy replicator owns), every PO, downtime, out-of-service and shift/shift-hour write
  route answers **403 `MIRROR_TENANT_WRITE_BLOCKED`** (pointing at the sandbox
  `OPERATOR_WRITE_BLOCK_SANDBOX_ENTERPRISE`). Reads and other tenants are untouched; the spec
  discovers every mutating route of those domains so a new one cannot bypass it. Unset = off.
- **Downtime upsert fence** (edge-api #302, 2026-10-13). `POST /api/downtimes` rejects the
  whole batch with **403** when any event's `idEquipment` is not the caller's, and the
  insert itself re-checks the equipment's tenant. Before, events were stamped with the
  caller's enterprise but could land on a foreign machine and surface in that tenant's
  pending downtimes.
- **Settings grants** (`src/shared/settings-grants/`, #296): Bearer users need the
  per-settings-page edit grant from `user_roles.permissions` for settings mutations.
- **`CsAdminRouteGuard`** (global) returns 403 unless `isCsAdmin` for paths under
  `/api/enterprises`, `/api/i18n/upsert`, `/api/i18n/import`, `/api/i18n/export`.
- **`CsAdminGuard`** (per controller) on `edge-ssm`, `edge-bundle`, `cognito-users`, and via
  the `@OnboardingEndpoint()`, `@TeardownEndpoint()`, `@PromoteEndpoint()` decorators.
  Those decorators put a feature-flag guard first, so a disabled feature is a 404 for
  everyone.

### Database adapters (`src/providers/database/`)

| Provider | Connection | Used by |
|---|---|---|
| `PostgresAdapter` | `postgres://POSTGRES_USER:…@POSTGRES_HOST:POSTGRES_PORT/POSTGRES_DB` | almost every DAO, auth lookups, audit log, idempotency |
| `AnalyticsPostgresAdapter` | `POSTGRES_ANALYTICS_URL`, falling back to the primary URL | justify, pending/justified downtimes, plc-status, entities tree, `TenantFence.assertEquipmentEvent` |

On staging **both point at `packiot_analytics` through pgbouncer** (`POSTGRES_DB:
packiot_analytics`, `POSTGRES_HOST: pgbouncer`). Code comments that say "primary = F1
`packiot`" describe the pre-2026-08 layout; the split survives as a seam. Both are
process-wide singletons (`@Global` `DatabaseModule`). pg-promise type parsers are installed
globally: int2/int4/int8 → JS number, `timestamptz`/`timestamp` → ISO-8601 UTC strings.

Transactions come in two styles: `createTransaction()` returns a call-owned batch whose
`execute()` runs the queued statements in one transaction (a statement returning zero rows
throws → 500); `tx(callback)` is a real pg-promise transaction for data-dependent multi-step
writes (scans, imports). Until 2026-10-08 the queue lived on the singleton adapter, so
concurrent requests could replay each other's statements (bug 202, fixed in edge-api #294);
`query(sql, params, true)` now throws instead of queueing.

### Audit log (`src/middleware/logger.middleware.ts`)

Controllers set `res.locals.logData = { eventType, payload, lineId, enterpriseId }`. When the
response finishes with status < 400 the middleware inserts
`user_logs(ts_event, id_enterprise, id_equipment, nm_user, category, ts_log, payload)`.
`nm_user` is `res.locals.actingUser` (CS-Admin / super-admin) or the `x-user` header;
`id_enterprise` falls back to `callerEnterpriseId`. Routes without `logData` (most GETs) write
nothing; logins are never logged. The `category` values (`order-started`,
`event-justified`, `event-splitted`, …) are the same strings the legacy platform writes,
which is what the [legacy bridge](analytics-sync.md) replays on the other side.

The request logger prints method, URL, status, headers and body for every `/api/*` call,
**redacted** since 2026-09-28 (`src/middleware/redact.ts`): credential headers
(`authorization`, `cookie`, `x-api-key`, `x-ingest-key`, `x-operator-superadmin-token`, …),
`?token=` and body keys that look like secrets become `[REDACTED]`. Since #294 an audit row
whose `idEnterprise` is NaN falls back to the authenticated tenant instead of being dropped.

### Validation (`src/main.ts`)

Global `ValidationPipe({ transform: true, whitelist: true })`, `forbidNonWhitelisted`
**off**, errors flattened to constraint messages. Consequences:

- A property with only `@ApiProperty` (no class-validator decorator) is **silently
  stripped**. The 2026-09-21 split bug: `EventDto.endTime` lacked a validator, was stripped,
  and every split 400'd (edge-api #267).
- The DTO property name is the wire contract. There is no snake/camel conversion; a key the
  DTO does not declare disappears with a 2xx (2026-08-20 csadmin audit).
- Do not require `idEnterprise` in a body DTO; inject it in the controller from
  `callerEnterpriseId` (the teams pattern).

### Idempotency (`src/interceptors/idempotency.interceptor.ts`)

A `POST` with `Idempotency-Key` returns the stored 2xx response if the key was seen in the
last 24 h (`idempotency_keys`); errors are not cached. Built for mirror-worker replays; the SPAs and
operator-gateway do not send one.

### PO staleness gate

`src/usecases/production-orders/shared/po-staleness-gate.ts` rejects (409) a PO action that
was captured against an outdated state: `STALE_HEAD` (the running PO changed),
`RANGE_CONFLICT`, `BEYOND_HORIZON`. On any data doubt it degrades to allow. Enabled on
staging for enterprises 3 and 4.

### Box operations and the SSM rail (`src/usecases/edge-ssm/`)

Factory boxes are SSM hybrid-activated managed instances (`mi-…`) tagged
`enterprise=<id>` and `managed-by=packiot-edge-api`. edge-api uses the app host's
**instance role** (no static AWS keys; a static key once hijacked the default credential
chain) to `CreateActivation`, `SendCommand` (`AWS-RunShellScript`, by `InstanceIds` after a
tag lookup), `GetCommandInvocation`, `StartSession` and `Deregister`. `deploy-onprem` renders
`compose.onprem-edge.yml` from code (`shared/onprem-compose.ts`, optional `operator-edge`
and `barcode-edge` services) and pushes it base64-encoded. `apply-agent-config` targets the
shared `sparkplug-agent-shared` on the app host (`SSM_SHARED_AGENT_INSTANCE_ID`). Interactive
shells are relayed over WebSocket to [edge-session-broker](edge-session-broker.md).
Enterprises in `SSM_SANDBOX_ENTERPRISE_IDS` (≥ 2,000,000) get **mocked** mutating
operations (`mock: true`, `wouldRun`). See [Edge box](edge-box.md).

### Onboarding and customizations

`/api/onboarding/*` stores a per-tenant descriptor and proxies generate/simulate to the
decoder's onboard server (`ONBOARD_GENERATE_URL`, `ONBOARD_SIMULATE_URL`, shared
`ONBOARD_API_KEY`). `simulate` previews a descriptor's derive rules (ADR-0058
customizations) without persisting. The Customization Hub SPA
([customize](customize.md)) is the UI; csadmin no longer edits customizations (2026-09-25).
Teardown (`EDGE_API_TEARDOWN_ENABLED`) is the inverse of onboarding, dry-run by default,
with a protected-tenant floor (CPACK 3 and SBXCPACK 2000003).

## Configuration

Staging values from `compose.staging.yml`; secrets come from `/opt/packiot/.env` and are
not listed.

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `POSTGRES_HOST` / `_PORT` / `_DB` / `_USER` / `_PASSWORD` | — | `pgbouncer` / 5432 / `packiot_analytics` / `.env` | Primary adapter |
| `POSTGRES_ANALYTICS_URL` | empty (→ primary) | pgbouncer `packiot_analytics` | Analytics adapter |
| `AUTH_BEARER_ENABLED` | on | `true` | Accept Cognito Bearer JWTs |
| `COGNITO_ISSUER`, `COGNITO_CLIENT_ID`, `COGNITO_JWKS_URI` | — | staging pool `us-east-1_0T9t1sTwt` | JWT verification (public identifiers) |
| `EDGE_API_COGNITO_AUTH_ENABLED` | off | `true` | CS-Admin cross-tenant `?idEnterprise=` |
| `EDGE_API_CS_ADMIN_GROUP` | `cs-admin` | default | CS-Admin group name |
| `COGNITO_USER_POOL_ID`, `COGNITO_CS_ADMIN_GROUP` | — | pool id, `cs-admin` | Cognito user management |
| `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | off | `true` | Super-admin switch + write escalation |
| `OPERATOR_SUPERADMIN_ALLOWLIST` | `dev@packiot.com` | default | Who may escalate |
| `EDGE_API_ONBOARDING_ENABLED` | off | `true` | Onboarding slice (404 when off) |
| `EDGE_API_TEARDOWN_ENABLED` | off | `true` | Teardown slice |
| `TEARDOWN_PROTECTED_ENTERPRISES` | protected floor | default | Extra protected tenants |
| `EDGE_API_PROMOTE_ENABLED`, `EDGE_API_PROMOTE_APPLY_ENABLED` | off | not set | Promotion slice |
| `ONBOARD_GENERATE_URL`, `ONBOARD_SIMULATE_URL`, `ONBOARD_API_KEY` | — | generate URL on decoder `:9105`, key from `.env`; simulate URL not set | Onboarding proxy |
| `PO_STALENESS_GATE_ENABLED`, `PO_STALENESS_GATE_ENTERPRISES` | off, empty | `true`, `3,4` | PO 409 gate |
| `OPERATOR_WRITE_BLOCKED_ENTERPRISES`, `OPERATOR_WRITE_BLOCK_SANDBOX_ENTERPRISE` | empty (off) | `3`, `2000003` | Mirror-tenant 403 write block (staging only) |
| `AWS_REGION` | `us-east-1` | same | SSM / Cognito |
| `SSM_HYBRID_INSTANCE_ROLE` | — (503 without) | `packiot-edge-ssm-hybrid-role` | Box activation role |
| `SSM_SHARED_AGENT_INSTANCE_ID`, `SSM_SHARED_AGENT_DIR` | empty (503) | app host instance id, runner workspace path | `apply-agent-config` target |
| `SSM_EDGE_INGEST_URL`, `SSM_EDGE_INGEST_KEY` | prod ingest URL, empty | staging ingest URL, `.env` | Baked into pushed reader bundles |
| `SSM_SANDBOX_ENTERPRISE_IDS` | — | see code | Mock mutating box ops for twins |
| other `SSM_*` | see `edge-ssm.config.ts` | defaults | Timeouts, session caps, deploy paths |
| `EDGE_SESSION_BROKER_WS_URL` / `_HTTP_URL` / `_TOKEN` | — | broker `:8090`/`:8091`; token from `.env` with a compose fallback | Box shells |
| `COMMANDS_ENABLED`, `COMMANDS_ALLOWED` | `false`, `po_setup,param_write` | not set in compose | Command channel (503 when off) |
| `RABBITMQ_*`, `EDGE_API_INGEST_TOPOLOGY_PROVISION_ENABLED` | — | `.env` | Command publisher, tenant topology |
| `SUPERSET_BASE_URL`, `SUPERSET_GUESTTOKEN_ADMIN_*`, `SUPERSET_OEE_DASHBOARD_UUID(_PT)` | — | `.env` | Guest-token minting |
| `POWERBI_*` | — | `.env` | Power BI broker |
| `GITHUB_DISPATCH_*`, `GITHUB_DEPLOY_WORKFLOW` | — | `.env` | Edge bundle builds |
| `CORS_ALLOWED_ORIGINS` | built-in list (localhost, `*.packiot.com`, `front/operator/csadmin.{staging,prod}.packiot.app`) | default | Browser origins |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME` | unset (off) | `http://tempo:4317`, `edge-api` | Tracing |
| `NEW_RELIC_ENABLED` | — | `false` | Legacy APM agent off |
| `REDIS_URL` | — | app-redis | Plumbed, not used by code |

## Data & invariants

- The tenant is **always** `res.locals.callerEnterpriseId`; client-sent enterprise ids are
  selectors at most, honoured only for CS-Admin and verified super-admins.
- Mutations are fenced to the caller before they run: the target row by `TenantFence`
  (404 on mismatch) and every referenced id by `assertRefs` (sites, areas, shifts,
  packml-register and equipment create/edit since the 2026-09-28 cross-tenant write fence).
  Controllers that still declare `?idEnterprise=` keep it only for the Swagger contract and
  read the tenant from `callerEnterpriseId`.
- Mutations address rows by their true key **and** tenant. `id_equipment_event` is not
  unique across tenants (PK is `(id_equipment, ts_event)`); the 2026-09-21 sandbox split
  wrote into CPACK because of it (fixed by tenant-pinning, edge-api #266).
- Throw Nest `HttpException` subclasses from services. A plain `Error` bypasses the
  `HttpExceptionFilter` and becomes a 500.
- Mutations use `POST` (including deletes: `/…/delete`); reads use `GET`; a few config
  writes use `PUT`.
- Only successful mutations are audited; logins are not.
- Box scans are gapless per PO: `pg_advisory_xact_lock(id_production_order)` + client
  `scan_uuid` idempotency, ported from [barcode-service](barcode-service.md).

## Observability

- `/metrics`: `http_request_duration_seconds` histogram by method, route template and
  status, plus Node default metrics. Scraped by Prometheus job `edge-api`.
- Traces: OpenTelemetry NodeSDK (`src/tracing.ts`) → Tempo; pg spans per DAO query; the
  operator-gateway's `traceparent` continues into edge-api.
- Logs worth grepping: `Deprecated auth: request used ?token=`, `audit row skipped`,
  `status: 4`/`status: 5` request lines, `Unauthorized!`.
- Grafana board "PO staleness gate" (uid `v2-po-staleness-gate`): the 409 rate must stay 0; edge-api RED metrics are on "API — RED" (`v2-api`).

## Failure modes

| Symptom | Cause | Fix / where |
|---|---|---|
| 201/200 but a field did not persist | DTO key not declared or lacks a validator → stripped by whitelist | Add the decorator; match casing (2026-08-20, 2026-09-21 #267) |
| 400 on a body that "looks right" | Required DTO field missing, often `idEnterprise` | Inject tenant from `callerEnterpriseId` |
| 401 on every operator write | Operator SPA sent its own Bearer; Bearer path fails closed | nginx `proxy_set_header Authorization ""` on `/api/` |
| 404 "… not found" on a real id | TenantFence: the id belongs to another tenant, or the key's tenant is not the one you expect | Check which key/JWT reached edge-api |
| 403 on csadmin | Token lacks the `cs-admin` group, or the feature flag env was lost on redeploy (flags are hardcoded in compose since then) | Cognito group membership; compose env |
| Cross-tenant super-admin write lands in home tenant | Super-admin token not verified (#188, fixed around 2026-09-06: an HS256 verifier was fed an RS256 Cognito token) | `x-operator-superadmin-token` must be the Cognito ID token |
| Split wrote into another tenant (2026-09-21) | Mutation keyed by non-unique `id_equipment_event` | Tenant-pin every mutating SQL (#266) |
| `GET /api/lines` returned other tenants' lines (until 2026-09-28) | Controller read `req.query.idEnterprise` | edge-api #272; grep new controllers for `req.query.idEnterprise` |
| Concurrent writes replayed each other's statements (bug 202, until 2026-10-08) | Statement queue on the singleton adapter | #294 per-call `createTransaction()` |
| Audit rows silently missing for api-key callers (bug 203) | `Number(undefined)` = NaN enterprise id failed the NOT NULL insert | #294 logger falls back to `callerEnterpriseId` |
| 403 `MIRROR_TENANT_WRITE_BLOCKED` on staging CPACK | Enterprise 3 is mirror-owned; writes would fight the replicator (2026-10-08: test POs stole ~74k net) | Expected; test on the sandbox 2000003 |
| Downtime upsert 403 | An event's `idEquipment` is not the caller's (#302) | Send only your own equipment |
| Submodule bump PR never appears (from 2026-10-13) | `bump-stack-submodule.yml` fails at "Checkout parent repo": `PARENT_REPO_TOKEN` expired | Rotate the secret in the edge-api repo; until then bump the submodule by hand |
| Box op 503 "not configured" | Missing `SSM_*` target env | Set it; the 503 is the safe failure |
| Every AWS call AccessDenied | A static `AWS_ACCESS_KEY_ID` in `.env` overrode the instance role | Remove static keys |

The 2026-09-28 review candidates are closed: the controllers that took the tenant from
`?idEnterprise=` or the body (sites, areas, shifts, shift-hours, packml-register, equipment
reasons, targets, downtime-reason upload/download, PO CSV, `plc-probe`) now use
`callerEnterpriseId` and `assertRefs`, and `GET /api/plc-status/:idEnterprise/agent-health`
ignores a foreign path enterprise and only fetches hosts matching
`sparkplug-agent[-name]:9103` (SSRF guard).

## Operating it

- **Deploy:** merge to edge-api `staging` → its `bump-stack-submodule.yml` (secret
  `PARENT_REPO_TOKEN`) opens an auto-merge PR on the stack repo → merge →
  `deploy-staging.yml` rebuilds `edge-api` on the app host. The token stopped working on
  2026-10-13 (every bump run fails at checkout), so bumps need a manual stack PR until it is
  rotated. See [CI/CD](ci-cd.md).
- **Change the API contract:** edit the controller decorators/DTOs, run
  `npm run openapi:export`, commit `openapi/edge-api.openapi.json` (the spec test fails on a
  stale copy); after the bump, `make openapi` in the stack repo vendors it. See
  [Add an API endpoint](../../build/develop/add-an-api-endpoint.md).
- **Recreate one container** with the compose labels on the running container:
  `docker compose -p stack -f <config_files> up -d --no-deps edge-api`. `docker restart`
  keeps the old environment; recreate to apply `.env` changes.
- **Roll back a flag:** set it to `"false"` in `compose.staging.yml` and redeploy; every
  flag above is designed to go inert.
- **Safe to retry:** reads; POSTs with `Idempotency-Key`; scans (by `scan_uuid`). **Not
  safe blindly:** PO start/stop/setup (use the staleness gate), teardown stages.
- Swagger at `https://api.staging.packiot.app/packiot/docs` and the portal at `/docs/` sit
  behind the cs-admin SSO gate (only `/api/*` and `/session*` bypass it).

## Tests

- Unit and contract specs: `cd edge-api && npm test` (Jest, `*.spec.ts` next to the code).
  Notable: `src/middleware/auth.middleware.spec.ts`, `src/shared/tenant-fence/*.spec.ts`,
  `src/usecases/operator-actions-smoketest.contract.spec.ts`,
  `src/usecases/write-plane-smoketest.contract.spec.ts`, `src/openapi/openapi.spec.ts`
  (OpenAPI completeness + stale-export check),
  `src/shared/operator-write-block/operator-write-block.middleware.spec.ts`,
  `downtimes/split/split.dto.whitelist.spec.ts`,
  `data/DAO/downtimes/downtimes-dao.tenant-pin.spec.ts`.
- E2E: `npm run test:e2e` (`test/jest-e2e.json`).
- Stack-level browser journeys that exercise edge-api live in `e2e/` (see
  [Simulators & twins](simulators-and-twins.md) for the sandbox they use).

## Source map

| Path | What's there |
|---|---|
| `edge-api/README.md` | How to run and change it |
| `edge-api/src/main.ts` | Bootstrap, CORS, ValidationPipe, Swagger, WebSocket shell relay, Node-RED webui proxy |
| `edge-api/src/openapi/`, `scripts/openapi/export.ts`, `openapi/edge-api.openapi.json` | OpenAPI document, export, committed spec |
| `edge-api/src/shared/operator-write-block/` | Staging mirror-tenant write block |
| `edge-api/src/middleware/redact.ts` | Log redaction |
| `edge-api/src/app.module.ts` | Module registry, global guard/interceptor, middleware binding |
| `edge-api/src/middleware/auth.middleware.ts` | All authentication paths |
| `edge-api/src/middleware/logger.middleware.ts`, `src/repositories/user-logs.repository.ts` | Audit trail |
| `edge-api/src/shared/tenant-fence/` | `callerEnterpriseId`, `TenantFence` |
| `edge-api/src/shared/control-plane/cs-admin-route.guard.ts` | Global CS-Admin path guard |
| `edge-api/src/shared/auth/` | Bearer JWT config/verifier, operator super-admin verifier |
| `edge-api/src/providers/database/` | `PostgresAdapter`, `AnalyticsPostgresAdapter` |
| `edge-api/src/providers/messaging/` | RabbitMQ command publisher, tenant topology |
| `edge-api/src/interceptors/idempotency.interceptor.ts` | Idempotency-Key store |
| `edge-api/src/usecases/` | All feature slices |
| `edge-api/src/usecases/edge-ssm/shared/` | SSM service, config, on-prem compose generator, reader bundle |
| `edge-api/src/usecases/production-orders/shared/po-staleness-gate.ts` | PO staleness gate |
| `edge-api/src/data/DAO/` | SQL per entity |
| `compose.staging.yml` (`edge-api`), `compose.production.yml` (`edge-api`) | Deployment and env |
| `edge-api/.github/workflows/bump-stack-submodule.yml` | Submodule bump PR on the stack repo |
| `terraform/staging/user_data/nginx_setup.sh` (`api.conf`) | Public routing, SSO bypass, API docs portal |
