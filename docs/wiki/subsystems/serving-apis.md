---
title: Serving & APIs
layer: 2
owner_area: serving
last_verified: 2026-09-28
---
# Serving & APIs

> **Layer 2 · Subsystems** — the HTTP surface of the new stack: which API serves which app,
> how each authenticates and picks the tenant, and the `serving.*` SQL layer the read side
> is built on. For anyone adding an endpoint or tracing a request from a browser to a table.
> Up: [Architecture overview](../architecture/overview.md)

## Purpose

Apps never talk to the database directly. Two services form the API layer (ADR-0026):
**read-api** answers every read with tenant-scoped, allowlisted SQL over the `serving`
schema, and **edge-api** performs every human-initiated write and all control-plane work
(configuration, onboarding, edge boxes). Two smaller services sit at the edges: the
**operator-gateway** turns a client's own operator system into edge-api calls, and the
**barcode-service** is an earlier scan-ingest service now superseded by edge-api. Both main
APIs share one security rule: the tenant comes from the credential, never from the request.

## Boundaries

**Owns**

- The HTTP contracts the SPAs, edge boxes and integrations depend on.
- Authentication (api-keys, Cognito JWT verification) and tenant derivation for API calls.
- The write paths into operational tables and the `user_logs` audit trail.
- The read models' *query* side: dataset registry, caching, windows and limits.

**Does not own**

- The `serving.*` SQL functions' and views' **definitions** and the tables behind them: these
  are migrations in the [Analytics DB](analytics-db.md).
- Derived numbers (OEE, rollups, downtime derivation): [Compute](compute.md).
- Telemetry ingest (`ingest.*` endpoints, MQTT): [Ingestion](ingestion.md).
- User identity itself (Cognito pool, oauth2-proxy SSO gate): [Identity](identity.md).
- BI dashboards: [Superset](../components/superset.md) (edge-api only mints its guest tokens).

## Components

| Component | What it does | Runtime | Staging entry point | Layer 3 |
|---|---|---|---|---|
| read-api (refdata-api) | All dashboard and operator reads; ~66 named datasets over `serving.*`; historian door; external shims | Go | `refdata.staging.packiot.app`, and `/v1/*` behind each operator SPA | [read-api](../components/read-api.md) |
| edge-api | All writes (POs, downtimes, scans, config), onboarding, box ops over SSM, BI tokens | NestJS | `api.staging.packiot.app` (`/api/*`, `/session*`), and `/api/*` behind each SPA | [edge-api](../components/edge-api.md) |
| operator-gateway | Client Node-RED tee → edge-api (Incoplast, ent 4) | Go, TLS | internal only (`operator-gateway:8443`) | [operator-gateway](../components/operator-gateway.md) |
| barcode-service | Gapless box-scan ingest + SSE; superseded by edge-api `/api/scanned-boxes` | Go | `scan.staging.packiot.app/v1/scans` | [barcode-service](../components/barcode-service.md) |
| `serving` schema | SQL functions/views the read side calls | Postgres | — | [Analytics DB schemas](../components/analytics-db-schemas.md) |

## How it works

```text
                     ┌─────────────── browser / device ───────────────┐
 operator app (per-tenant nginx)   front4          csadmin / customize    barcode app
   │ /api/* + injected x-api-key    │ Bearer        │ Bearer (cs-admin)    │ /api/* + injected key
   │ /v1/*  + injected x-api-key    │ (Cognito)     │ + ?idEnterprise=N    │
   │ /session  (Cognito Bearer)     │               │                      │
   ▼                                ▼               ▼                      ▼
 ┌──────────────────────┐  ┌──────────────────────────────────────────────────────┐
 │ read-api  :9104      │  │ edge-api  :8080                                      │
 │ tenant = key map or  │  │ tenant = api-key owner | user's enterprise |         │
 │  identity.users(sub) │  │  CS-Admin target | verified super-admin target       │
 │ $1 + app.tenant_id   │  │ TenantFence → DAO → user_logs audit                  │
 └─────────┬────────────┘  └──────────┬──────────────────────┬────────────────────┘
           │ readapi_ro (RLS)         │ pgbouncer            │ SSM, Cognito, Superset,
           ▼                          ▼                      ▼ RabbitMQ, GitHub
   serving.* fns/views ──▶ packiot_analytics (core / silver / gold / identity / config)
           │
           └──▶ hist-gateway (historian, S3 parquet) for long windows

 client Node-RED tee ──X-Ingest-Key──▶ operator-gateway ──api-key──▶ edge-api
```

A typical operator action: the operator app posts `POST /api/production-orders/start` to
its own nginx, which injects the tenant's api-key and strips the browser's `Authorization`
header; edge-api resolves the tenant from the key, fences the PO id to it, writes
`core.production_orders` and the runtime window, and records `order-started` in
`user_logs`. The operator app then re-polls `GET /v1/operator-po-details`, which read-api
answers from `serving.v_operator_po_details_3` scoped to the same tenant.

## Interfaces

### Who calls what, with which credential

| Caller | API | Credential | Tenant source |
|---|---|---|---|
| Operator app (CPACK, sandbox, Bispharma deployments) | edge-api `/api/*` | `x-api-key` injected by that deployment's nginx | key owner (`enterprises.api_key`) |
| Operator app | edge-api `/session*` | Cognito ID token (Bearer) | user row; super-admin may switch |
| Operator app | read-api `/v1/*` | `x-api-key` injected by nginx (`QUERY_API_KEYS`) | key map |
| Operator super-admin | both | api-key + `x-operator-superadmin-token` + `?idEnterprise=` | verified target (flag-gated) |
| front4 | read-api `/v1/query`, `/v1/historian/*`, configs | Cognito Bearer | `identity.users.id_user_cognito` |
| front4 | edge-api settings, `/api/superset/guest-token` | Cognito Bearer | user's enterprise |
| csadmin, customize | edge-api control plane | Cognito Bearer in group `cs-admin` + `?idEnterprise=N` | `N` (CS-Admin) |
| Barcode app | edge-api `/api/scanned-boxes`, `/api/samples`, `/api/production-orders/current` | injected `x-api-key` | key owner |
| operator-gateway | edge-api | tenant api-key + `?idEnterprise=` | key owner |
| edge-transformer | read-api `/internal/resolve-device` | `X-Internal-Key` | explicit (service-to-service) |
| External integrations (Neopac SAP, Montebello, Incoplast, Power BI) | read-api `/ext/*`, `/integration/*` | `x-api-key` from the same key map, bound to an owner env | owner binding |
| ERP connector | edge-api `/api/admin/production-orders/csv/import` | tenant api-key | key owner |

Endpoint-level detail: [API endpoints](../reference/api-endpoints.md).

### The `serving` schema

read-api does not query raw tables for anything non-trivial; it calls functions and views in
`serving`, all taking the enterprise as their first argument or exposing `id_enterprise`.
Functions are SECURITY INVOKER (they run as `readapi_ro`, so RLS applies and needs the
`app.tenant_id` GUC); views run with their owner's rights (`postgres`), so for views the
`$1` predicate is the only fence.

| Area | Objects |
|---|---|
| Operator app | `v_operator_po_list_setup_4`, `v_operator_po_details_3`, `v_operator_entities_2`, `v_entities_per_user_role_operator`, `events_timeline`, `pending_downtime` |
| Mission Control / home | `mission_control`, `mission_control_area`, `mission_control_timeline`, `home` |
| OEE | `oee_score`, `oee_score_by_team`, `oee_progress`, `equipment_scrap_capability`, `targets` |
| Overview | `overview_job_info`, `overview_events`, `overview_events_v3`, `overview_production_chart`, `production_chart`, `production_chart_legacy`, `production_health`, `overview_takt`, `overview_scrap_rate` |
| Downtimes | `downtime_summary`, `downtime_by_category`, `downtime_duration_by_category`, `downtime_events`, `downtime_events_v2`, `downtime_events_v3` (+ table `downtime_events_resolved`, refreshed by `refresh_downtime_events_resolved` every 2 min) |
| Production | `total_production_by_team`, `single_period_by_team`, `single_period_by_team_v4`, `production_orders`, `production_orders_with_runtimes`, `production_flow`, `machine_speed`, `events_timeline_by_po`, `events_timeline_full` |
| Bootstrap / menus | `v_entities_per_user_role`, `v_menu_per_user_role` |
| Reports / integrations | `v_report_downtimes`, `report_*`, `sap_site_report`, `sap_report_data_sync`, `data_sync`, `downtime_sync`, `production_data_sync`, `production_information` |
| Barcode | `v_po_box_totals` |

Change these only through migrations: recreating a definer view as a superuser flips its
owner and silently disables its RLS fence (2026-09-21).

## Data it owns

- `user_logs` rows written by edge-api's audit middleware (the audit trail; the category
  names match the legacy platform's, whose `user_logs` the [legacy bridge](legacy-bridge.md)
  replays).
- `idempotency_keys` (edge-api, 24 h).
- `identity.user_screen_config` (read-api per-user layouts).
- Redis cache entries `refdata:ds:v1:*` (read-api, TTL 15-300 s).
- Onboarding descriptors and edge-bundle runs (edge-api control plane).

## Configuration that matters

| Knob | Service | Effect |
|---|---|---|
| `QUERY_API_KEYS` | read-api | The api-key → tenant map; a wrong entry reads the wrong tenant |
| `REFDATA_FLOW=f3` | read-api | Reads from `packiot_analytics` |
| DB role `readapi_ro` | read-api | RLS co-enforcement; `postgres` would bypass it |
| `REDIS_CACHE_ENABLED` | read-api | Cache-aside on/off |
| `AUTH_BEARER_ENABLED`, `COGNITO_*` | both | Accept Cognito JWTs |
| `EDGE_API_COGNITO_AUTH_ENABLED` | edge-api | CS-Admin cross-tenant target |
| `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | both | Super-admin switcher, reads and writes |
| `EDGE_API_ONBOARDING_ENABLED`, `EDGE_API_TEARDOWN_ENABLED`, `EDGE_API_PROMOTE_ENABLED` | edge-api | Dark-by-default slices (404 when off) |
| `PO_STALENESS_GATE_*` | edge-api | 409 on stale PO actions |

## Failure modes & signals

| Symptom | Where to look |
|---|---|
| Dashboard tile empty for every tenant | read-api tx did not stamp `app.tenant_id`, or a `serving` function changed shape; run the dataset SQL as `readapi_ro` with the GUC set |
| Dashboard 500 on long windows | Timeout (`/v1/query` 40 s); the error body is generic and the DB error is not logged |
| "Couldn't load workspace data" in front4 | User not linked in `identity.users` (analytics DB) |
| Write returns 2xx but nothing changed | DTO key stripped by `whitelist` (edge-api) |
| Write 404 on an id that exists | TenantFence: the credential's tenant does not own it |
| Operator writes 401 | nginx not stripping the browser `Authorization` before `/api/*` |
| RED metrics | `http_request_duration_seconds{route,status}` on both APIs (Prometheus jobs `read-api`, `edge-api`); traces in Tempo from operator-gateway → edge-api → DB |

## History & decisions

- [ADR-0015](../adr/0015-customer-facing-query-api.md): the composable, allowlisted query API
  (read-api's origin).
- [ADR-0026](../adr/0026-api-layer-consolidation.md): two APIs (edge-api writes, read-api
  reads); retire Hasura, primary-api and back4-api.
- [ADR-0027](../adr/0027-refdata-api-surface-1-read-contract.md): the client never names a
  tenant; `$1` injection authority.
- [ADR-0031](../adr/0031-back4-api-retirement-shims-datasets-and-hasura-sequence.md):
  external-contract shims replace back4-api.
- [ADR-0033](../adr/0033-unified-firebase-jwt-auth.md) /
  [ADR-0034](../adr/0034-adopt-cognito-amplify-auth.md): Bearer JWTs on both APIs; Cognito
  replaced Firebase (Firebase retired, #159).
- [ADR-0035](../adr/0035-redis-cache-layer.md): Redis cache-aside for read-api.
- 2026-09-13: read-api moved to the NOBYPASSRLS role `readapi_ro` (RLS co-enforcer).
- 2026-09-21: downtime split bug chain (whitelist strip, cross-tenant write by a non-unique
  id); downtime-events timeout 20 s → 40 s.
- 2026-09-28: historian hot/cold split in read-api (#1474); `GET /api/lines` tenant fence
  (edge-api #272).

## Go deeper

- [read-api](../components/read-api.md) · [edge-api](../components/edge-api.md) ·
  [operator-gateway](../components/operator-gateway.md) ·
  [barcode-service](../components/barcode-service.md)
- [API endpoints](../reference/api-endpoints.md)
- [Tenancy and security](../architecture/tenancy-and-security.md) · [Identity](identity.md)
