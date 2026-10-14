---
title: Serving & APIs
layer: 2
owner_area: serving
last_verified: 2026-10-13
---
# Serving & APIs

> **Layer 2 · Subsystems** — the HTTP surface of the new stack: which API serves which app,
> how each authenticates and picks the tenant, where each publishes its contract, and the
> `serving.*` SQL layer the read side is built on. For anyone adding an endpoint or tracing
> a request from a browser to a table.
> Up: [Architecture overview](../architecture/overview.md)

## Purpose

Apps never talk to the database directly. Two services form the API layer (ADR-0026):
**read-api** answers reads with tenant-scoped, allowlisted SQL, mostly over the `serving`
schema, and **edge-api** performs every human-initiated write and all control-plane work
(configuration, onboarding, users, edge boxes, BI tokens). Two smaller services sit at the
edges: **operator-gateway** turns a client's own operator system into edge-api calls, and
**barcode-service** is a standalone box-scan ingest API (the barcode app itself writes
through edge-api). All of them share one rule: the tenant comes from the credential, never
from the request.

Everything here describes **staging**. `compose.production.yml` defines edge-api, read-api
and (profile `client-ingest`) operator-gateway for the new-stack production host, but
production has not been promoted yet (draft release PR #1653); production clients are still
served by the legacy platform.

## Boundaries

**Owns**

- The HTTP contracts the SPAs, edge boxes and integrations depend on, and their OpenAPI specs.
- Authentication (api-keys, Cognito JWT verification) and tenant derivation for API calls.
- The write paths into operational tables and the `user_logs` audit trail.
- The query side of the read models: dataset registry, caching, windows and limits.

**Does not own**

- The definitions of the `serving.*` functions and views and the tables behind them:
  those are migrations in the [Analytics DB](analytics-db.md).
- Derived numbers (OEE, rollups, downtime derivation): [Compute](compute.md).
- Telemetry ingest over HTTP or MQTT (sparkplug-agent, ingest-shim): [Ingestion](ingestion.md)
  and [Edge](edge.md).
- User identity itself (Cognito pool, oauth2-proxy gate): [Identity](identity.md).
- BI dashboards: [Superset](../components/superset.md) (edge-api only mints guest tokens).

## Components

| Component | What it does | Runtime | Staging entry point | Layer 3 · API reference |
|---|---|---|---|---|
| read-api (Go package `refdata-api`) | Operator reads (`/v1`, `/v2`), composable query API and named datasets, per-user screen config, historian series, external shims | Go, container `read-api` :9104 (alias `refdata-api`) | `refdata.staging.packiot.app`; `/v1/*` behind the operator and csadmin SPAs | [read-api](../components/read-api.md) · [API](../../reference/api/read-api.md) |
| edge-api | All writes (POs, downtimes, scans, samples, config), onboarding, users, box ops over SSM, Superset guest tokens | NestJS, container `stack-edge-api-1` :8080 | `api.staging.packiot.app` (`/api/*`, `/session*`); `/api/*` behind each SPA | [edge-api](../components/edge-api.md) · [API](../../reference/api/edge-api.md) |
| operator-gateway | Client Node-RED tee → edge-api (Incoplast, enterprise 4) | Go, TLS :8443 | internal only (host `127.0.0.1:8445`) | [operator-gateway](../components/operator-gateway.md) · [API](../../reference/api/operator-gateway.md) |
| barcode-service | Gapless box-scan ingest (`POST /v1/scans`) + SSE stream | Go, :8446 | `scan.staging.packiot.app` (exact paths only) | [barcode-service](../components/barcode-service.md) · [API](../../reference/api/barcode-service.md) |
| `serving` schema | SQL functions and views the read side calls | Postgres | — | [Analytics DB schemas](../components/analytics-db-schemas.md) |

Every service also has a row in the [service catalog](../../reference/service-catalog.md).

## How it works

```text
                     ┌─────────────── browser / device ───────────────┐
 operator app (per-tenant nginx)   front4          csadmin / customize    barcode app
   │ /api/* + injected x-api-key    │ Bearer        │ Bearer (cs-admin)    │ /api/* + injected key
   │ /v1/*, /v2/* + injected key    │ (Cognito)     │ + ?idEnterprise=N    │
   │ /session  (Cognito Bearer)     │               │                      │
   ▼                                ▼               ▼                      ▼
 ┌──────────────────────┐  ┌──────────────────────────────────────────────────────┐
 │ read-api  :9104      │  │ edge-api  :8080                                      │
 │ tenant = key map or  │  │ tenant = api-key owner | user's enterprise |         │
 │  identity.users(sub) │  │  CS-Admin target | verified super-admin target       │
 │ $1 + app.tenant_id   │  │ TenantFence → DAO → user_logs audit                  │
 └─────────┬────────────┘  └──────────┬──────────────────────┬────────────────────┘
           │ readapi_ro (RLS)         │ pgbouncer            │ SSM, Cognito, Superset,
           ▼                          ▼                      ▼ edge-session-broker
   serving.* fns/views ──▶ packiot_analytics (core / silver / gold / identity / config)
           │
           └──▶ hist-gateway (historian) for /v1/historian/* long windows

 client Node-RED tee ──X-Ingest-Key──▶ operator-gateway ──api-key──▶ edge-api
 scanner (Cognito Bearer) ──▶ scan.staging ──▶ barcode-service ──▶ packiot_analytics
```

A typical operator action: the operator app posts `POST /api/production-orders/start` to
its own nginx, which injects the tenant's api-key and **strips the browser's
`Authorization` header** (otherwise edge-api would try the Bearer path and 401); edge-api
resolves the tenant from the key, fences the PO to it, writes `core.production_orders` and
the runtime window, and records the action in `user_logs`. The app then re-polls
`/v1/operator-po-details` (or the id-keyed `/v2/operator-po-list`, ADR-0061), which read-api
answers scoped to the same tenant.

On staging, CPACK (enterprise 3) is a mirror of legacy, so edge-api rejects operator PO,
downtime and shift writes for it with 403 (`OPERATOR_WRITE_BLOCKED_ENTERPRISES=3`; test on
the sandbox twin 2000003 instead).

### Contracts: OpenAPI everywhere

| API | Spec served at | Committed spec |
|---|---|---|
| read-api, barcode-service, operator-gateway, ingest-shim, sparkplug-agent, onboard API | `GET /openapi.json` on the service | `docs/api/openapi/<api>.openapi.json` |
| edge-api | `GET /packiot/docs-json` (Swagger UI at `/packiot/docs`) | `docs/api/openapi/edge-api.openapi.json` (`npm run openapi:export`) |

- **Portal:** `https://api.staging.packiot.app/docs/`, behind the oauth2-proxy `cs-admin`
  gate. nginx fetches each spec in-network, so a stopped service only breaks its own entry.
- **Generated reference:** the wiki build renders every committed spec into
  [API reference](../../reference/api/index.md) (`scripts/wiki-openapi-to-md.py`).
- **Drift gates:** route ↔ spec tests per service, plus `openapi-export.yml` on every PR.
- `refdata.staging.packiot.app/metrics` and `/openapi.json` return 404 publicly
  (2026-10-13); Prometheus and the portal reach them in-network.

## Interfaces

### Who calls what, with which credential

| Caller | API | Credential | Tenant source |
|---|---|---|---|
| Operator app (`operator`, `operator-sbx`, `operator-bispharma`) | edge-api `/api/*` | `x-api-key` injected by that container's nginx | key owner (`enterprises.api_key`) |
| Operator app | edge-api `/session*` | Cognito ID token (Bearer) | user row (`user_name` = email); super-admin may switch |
| Operator app | read-api `/v1/*`, `/v2/*` | `x-api-key` injected by nginx (a `QUERY_API_KEYS` entry) | key map |
| Operator super-admin | both | api-key + `x-operator-superadmin-token` + `?idEnterprise=` | verified target (flag-gated) |
| front4 | read-api `/v1/query`, `/v1/catalog`, `/v1/historian/*`, `/v1/screen-config`, … | Cognito Bearer | `identity.users.id_user_cognito` |
| front4 | edge-api settings, `/session/enterprises`, `/api/superset/guest-token` | Cognito Bearer | user's enterprise |
| csadmin, customize | edge-api control plane (csadmin also read-api `/v1`) | Cognito Bearer in group `cs-admin` + `?idEnterprise=N` | `N` (CS-Admin target) |
| Barcode app | edge-api `/api/scanned-boxes`, `/api/samples*`, `/api/lines`, `/api/production-orders/current` | injected `x-api-key` | key owner |
| Scanner clients | barcode-service `/v1/scans` | Cognito Bearer | verified `custom:id_enterprise` claim |
| operator-gateway | edge-api | tenant api-key | key owner |
| sparkplug-decoder | read-api `/internal/resolve-device` | `X-Internal-Key` | caller names its enterprise (service-to-service) |
| External integrations (Neopac, Montebello, Incoplast) | read-api `/ext/*`, `/integration/*` | `x-api-key` from `QUERY_API_KEYS`, bound to a per-shim owner | owner binding |

read-api accepts only two credentials: `X-Api-Key` (wins when present) or a Cognito
Bearer; Firebase tokens are rejected since #159. Endpoint detail:
[API reference](../../reference/api/index.md).

### The `serving` schema

read-api calls functions and views in `serving` for anything non-trivial, all taking the
enterprise as their first argument or exposing `id_enterprise`. Functions are SECURITY
INVOKER (they run as `readapi_ro`, so RLS applies and needs the `app.tenant_id` GUC); views
run with their owner's rights, so for views the `$1` predicate is the only fence.

| Area | Objects (examples) |
|---|---|
| Operator app | `v_operator_po_list_setup_4`, `v_operator_po_details_3`, `v_operator_entities_2`, `v_entities_per_user_role_operator`, `events_timeline(_by_equipment)`, `pending_downtime(_by_equipment)`, `operator_po_list_by_equipment`, `downtime_reasons_by_equipment` |
| Mission Control / home | `mission_control`, `mission_control_area`, `mission_control_timeline`, `home` |
| OEE | `oee_score`, `oee_score_by_team`, `oee_progress`, `equipment_scrap_capability`, `targets` |
| Overview | `overview_job_info`, `overview_events(_v3)`, `overview_production_chart`, `production_chart(_legacy)`, `production_health`, `overview_takt`, `overview_scrap_rate` |
| Downtimes | `downtime_summary`, `downtime_by_category`, `downtime_duration_by_category`, `downtime_events(_v2, _v3)` + table `downtime_events_resolved` (refreshed by `refresh_downtime_events_resolved`) |
| Production | `total_production_by_team`, `single_period_by_team(_v4)`, `production_orders(_with_runtimes)`, `production_flow`, `machine_speed`, `events_timeline_by_po`, `events_timeline_full` |
| Menus / reports / barcode | `v_entities_per_user_role`, `v_menu_per_user_role`, `report_*`, `sap_site_report`, `data_sync`, `v_po_box_totals` |

Change these only through migrations: recreating a definer view as a superuser flips its
owner and silently disables its RLS fence (2026-09-21).

## Data it owns

- `user_logs` rows written by edge-api's audit middleware (category names match legacy's,
  whose `user_logs` the [legacy bridge](legacy-bridge.md) replays).
- `idempotency_keys` (edge-api idempotency interceptor).
- `identity.user_screen_config` (read-api per-user layouts; its only write).
- `bronze.box_scans` / `gold.po_box_counter` rows (barcode-service and edge-api scanned-boxes).
- Redis cache entries in `app-redis` DB 0 (read-api dataset cache, fail-open).
- Onboarding descriptors and edge-bundle runs (edge-api control plane).

## Configuration that matters

| Knob | Service | Staging | Effect |
|---|---|---|---|
| `QUERY_API_KEYS` | read-api | 5 keys (tenants 3, 2, 4, 2000003, 5) | api-key → tenant map; a wrong entry reads the wrong tenant |
| `REFDATA_FLOW` | read-api | `f3` | reads `packiot_analytics`; anything else reads the retired `packiot` DB |
| `DB_USER` | read-api | `readapi_ro` | NOBYPASSRLS role; `compose.production.yml` still uses `POSTGRES_USER` |
| `REDIS_CACHE_ENABLED` | read-api | `true` | dataset cache-aside on/off |
| `AUTH_BEARER_ENABLED`, `COGNITO_ISSUER`, `COGNITO_CLIENT_ID` | edge-api (issuer/client also read-api) | on, staging pool | accept Cognito JWTs; `aud` must be the `front4-amplify` client |
| `EDGE_API_COGNITO_AUTH_ENABLED` | edge-api | `true` | CS-Admin `?idEnterprise=` target |
| `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | edge-api, read-api | `true` | super-admin switcher, reads and writes |
| `EDGE_API_ONBOARDING_ENABLED`, `EDGE_API_TEARDOWN_ENABLED` | edge-api | `true` | dark-by-default slices (404 when off) |
| `PO_STALENESS_GATE_ENABLED` / `_ENTERPRISES` | edge-api | `true` / `3,4` | 409 on stale PO actions |
| `OPERATOR_WRITE_BLOCKED_ENTERPRISES` | edge-api | `3` | 403 on operator writes to the legacy-mirrored tenant |
| `INTERNAL_API_KEY` | read-api | from `.env` | enables `/internal/*`; empty = disabled |

## Failure modes & signals

| Symptom | Where to look |
|---|---|
| Dashboard tile empty for every tenant | transaction did not stamp `app.tenant_id`, or a `serving` function changed shape; run the dataset SQL as `readapi_ro` with the GUC set |
| Dashboard 500/timeout on long windows | `/v1/query` statement budget is 40 s; narrow the window or use the historian series |
| front4 "Couldn't load workspace data" | Cognito user not linked in `identity.users` ([Identity](identity.md#failure-modes-signals)) |
| Write returns 2xx but nothing changed | DTO key stripped by edge-api's `whitelist` validation |
| Write 404/403 on an id that exists | TenantFence: the credential's tenant does not own it (by design) |
| Operator writes 401 | nginx not stripping the browser `Authorization` before `/api/*` |
| Operator writes 403 on CPACK (staging) | `OPERATOR_WRITE_BLOCKED_ENTERPRISES` — use the sandbox twin |
| Portal entry fails for one API | that service is down; the others still load |
| RED metrics | `http_request_duration_seconds{route,status}` (Prometheus jobs `read-api`, `edge-api`, `operator-gateway`); traces in Tempo |

## History & decisions

- [ADR-0015](../../adr/0015-customer-facing-query-api.md): composable, allowlisted query API.
- [ADR-0026](../../adr/0026-api-layer-consolidation.md): two APIs (edge-api writes, read-api
  reads); retire Hasura, primary-api and back4-api.
- [ADR-0027](../../adr/0027-refdata-api-surface-1-read-contract.md): the client never names a
  tenant; `$1` injection authority.
- [ADR-0031](../../adr/0031-back4-api-retirement-shims-datasets-and-hasura-sequence.md):
  external-contract shims replace back4-api.
- [ADR-0033](../../adr/0033-unified-firebase-jwt-auth.md) /
  [ADR-0034](../../adr/0034-adopt-cognito-amplify-auth.md): Bearer JWTs on both APIs; Cognito
  replaced Firebase (Firebase retired, #159).
- [ADR-0035](../../adr/0035-redis-cache-layer.md): Redis cache-aside for read-api.
- [ADR-0040](../../adr/0040-barcode-traceability-service.md): barcode-service (gapless labels).
- [ADR-0061](../../adr/0061-remove-packml-from-the-cloud.md): id-keyed `/v2` operator reads.
- 2026-09-13: read-api moved to the NOBYPASSRLS role `readapi_ro` (migration `t276`).
- 2026-09-21: downtime-split bug chain (whitelist strip, cross-tenant write by a non-unique id).
- 2026-10-13: complete OpenAPI for every API + portal; refdata `/metrics` and `/openapi.json`
  closed publicly; two cross-tenant fixes — barcode-service `scan_uuid` replay of another
  tenant's scan now 409 `scan_uuid_conflict` (#1688), edge-api `POST /api/downtimes` on another
  tenant's equipment now 403 (edge-api #302).

## Go deeper

- [read-api](../components/read-api.md) · [edge-api](../components/edge-api.md) ·
  [operator-gateway](../components/operator-gateway.md) ·
  [barcode-service](../components/barcode-service.md) · [Superset](../components/superset.md)
- [API reference](../../reference/api/index.md): [edge-api](../../reference/api/edge-api.md) ·
  [read-api](../../reference/api/read-api.md) ·
  [barcode-service](../../reference/api/barcode-service.md) ·
  [operator-gateway](../../reference/api/operator-gateway.md)
- [Service catalog](../../reference/service-catalog.md) ·
  [Add an API endpoint](../../build/develop/add-an-api-endpoint.md)
- [Tenancy and security](../architecture/tenancy-and-security.md) · [Identity](identity.md)
