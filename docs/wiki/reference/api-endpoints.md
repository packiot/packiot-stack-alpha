---
title: API endpoints
layer: 4
owner_area: serving
last_verified: 2026-09-28
---
# API endpoints

> **Layer 4 · Reference** — every HTTP endpoint of read-api, edge-api, operator-gateway and
> barcode-service: method, path, authentication, where the tenant comes from, and purpose.
> Generated from the controllers and route registries on 2026-09-28.
> Up: [Serving & APIs](../subsystems/serving-apis.md)

## Legend

**Auth**

| Code | Meaning |
|---|---|
| `std` | edge-api `/api/*` middleware: `x-api-key` (tenant api-key; deprecated `?token=` still works) **or** `Authorization: Bearer <Cognito ID token>` |
| `CS` | `std` plus CS-Admin required (Cognito group `cs-admin`); 403 otherwise. Some CS slices also sit behind a feature flag (404 when off) |
| `cognito` | Cognito ID token verified by the service itself |
| `key\|bearer` | read-api: `X-Api-Key` from `QUERY_API_KEYS`, or Cognito Bearer resolved through `identity.users` |
| `ext` | external-shim auth: `x-api-key` from the same key map, bound to one owner enterprise |
| `internal` | `X-Internal-Key` shared secret |
| `ingest` | `X-Ingest-Key` shared secret over TLS |
| `none` | no authentication |

**Tenant source**

| Code | Meaning |
|---|---|
| `caller` | server-derived: edge-api `callerEnterpriseId(res)` / read-api resolved `customer_id` (bound as `$1`) |
| `CS target` | the `?idEnterprise=` a CS-Admin selects (honoured only for CS-Admin tokens) |
| `request ⚠` | the controller reads `?idEnterprise=` or a body `idEnterprise` itself. For an api-key caller `?idEnterprise=` must match the key (checked by the middleware); a body value, or any value from a Bearer user, is **not** checked. See [edge-api review note](../components/edge-api.md#failure-modes) |
| `path ⚠` | taken from the URL path, not checked against the caller |
| `key` | resolved from the presented api-key inside the service |
| `global` | not tenant data (shared i18n, health) |

Super-admin escalation (`?idEnterprise=` + `x-operator-superadmin-token`) can re-target
`caller` on both APIs when `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` is on.

## read-api

Base URL on staging: `https://refdata.staging.packiot.app` (front4) or `/v1/*` behind an
operator deployment's nginx. Details: [read-api](../components/read-api.md).

| Method | Path | Auth | Tenant | Purpose |
|---|---|---|---|---|
| GET | `/v1/events-timeline?topics=a,b` | key\|bearer | caller | Event timeline per topic (`serving.events_timeline`) |
| GET | `/v1/pending-downtime?topics=` | key\|bearer | caller | Unjustified downtimes (`serving.pending_downtime`) |
| GET | `/v1/shift-hours?topic=` | key\|bearer | caller | Shift calendar for a topic |
| GET | `/v1/shift-hours-by-enterprise?topic=` | key\|bearer | caller | Same, legacy name (`?enterprise=` ignored) |
| GET | `/v1/day-week-begin?topic=` | key\|bearer | caller | Day/week boundaries |
| GET | `/v1/operator-po-list` | key\|bearer | caller | Operator PO list (`v_operator_po_list_setup_4`) |
| GET | `/v1/operator-po-details` | key\|bearer | caller | Running PO details (`v_operator_po_details_3`) |
| GET | `/v1/operator-entities` | key\|bearer | caller | Operator entity tree |
| GET | `/v1/entities-per-user-role` | key\|bearer | caller | Role → entity tree |
| GET | `/v1/language-packs` | key\|bearer | global | i18n packs |
| GET | `/v1/downtime-reasons?topics=` | key\|bearer | caller | Reason trees per equipment |
| GET | `/v1/catalog` | key\|bearer | global | Metrics, dimensions, grains, dataset list |
| POST | `/v1/query` | key\|bearer | caller | Named dataset `{"dataset": …}` or metric composer; 40 s timeout, 10,000 rows |
| GET, PUT | `/v1/screen-config?user=&screen=` | key\|bearer | caller | Per-user layout JSON (≤ 64 KiB) |
| GET | `/v1/dashboard-config?dashboard_id=[&user=]` | key\|bearer | caller | Dashboard baseline ‖ user override |
| POST | `/v1/historian/production-series` | key\|bearer | caller | Daily gross/net per equipment, hot + cold (≤ 5 years) |
| POST | `/v1/historian/downtime-series` | key\|bearer | caller | Daily downtime per equipment, hot + cold |
| GET | `/internal/resolve-device?device_key=[&enterprise=]` | internal | request (service) | `device_key` → `id_equipment` for edge-transformer |
| GET | `/ext/neopac/sap-report` | ext | owner | Neopac SAP report (frozen contract) |
| GET | `/ext/neopac/sap-report-sync` | ext | owner | Neopac SAP sync, paginated |
| GET | `/ext/montebello/data-sync` | ext | owner | Montebello data sync |
| GET | `/ext/montebello/events` | ext | owner | Montebello events |
| GET | `/ext/incoplast/events` | ext | owner | Incoplast events |
| GET | `/ext/incoplast/jobs` | ext | owner | Incoplast jobs |
| GET | `/integration/job_data_integration/:id_enterprise` | ext | owner | Legacy back4 contract (Montebello) |
| GET | `/integration/get-shift-validation/:id_enterprise` | ext | owner | Legacy back4 contract (Montebello) |
| GET | `/integration/job_report/:id_enterprise` | ext | owner | Legacy back4 contract (Incoplast) |
| GET | `/healthz` | none | global | Pool ping + counters |
| GET | `/metrics` | none | global | Prometheus |

An external shim whose owner env (`EXTERNAL_*_CUSTOMER_ID`) is unset answers 401 to
everyone.

## edge-api

Base URL on staging: `https://api.staging.packiot.app` (`/api/*`, `/session*` bypass the SSO
gate) or `/api/*` behind each SPA's nginx. Mutations are `POST`, including deletes. Every
successful mutation writes a `user_logs` row. Details: [edge-api](../components/edge-api.md).

### Session and platform

| Method | Path | Auth | Tenant | Purpose |
|---|---|---|---|---|
| POST | `/session` | cognito | user (super-admin may pass `idEnterprise`) | Operator login: entities, permissions, `super_user` |
| POST | `/session/switch` | cognito | user; super-admin target | Re-scope the operator session |
| GET | `/session/enterprises` | cognito | super-admin only | Tenant picker |
| GET | `/health` | none | global | Liveness |
| GET | `/metrics` | none | global | Prometheus |
| GET | `/packiot/docs` | none (SSO gate on the public host) | global | Swagger UI |

### Production orders

| Method | Path | Auth | Tenant | Purpose |
|---|---|---|---|---|
| POST | `/api/production-orders/create` | std | caller | Create PO (status 1) |
| POST | `/api/production-orders/create-and-start` | std | caller | Create and start |
| POST | `/api/production-orders/start` | std | caller | Start a PO (staleness gate) |
| POST | `/api/production-orders/stop` | std | caller | Finish or pause |
| POST | `/api/production-orders/setup` | std | caller | Close current, optionally open next |
| POST | `/api/production-orders/change-status` | std | caller | Status transition |
| POST | `/api/production-orders/change-time` | std | caller | Move start time |
| POST | `/api/production-orders/replace` | std | caller | Edit quantity / order in place |
| POST | `/api/production-orders/delete` | std | caller | Delete a PO |
| GET | `/api/production-orders/current` | std | caller | Running PO for an equipment (barcode app) |
| POST | `/api/admin/production-orders/csv/validate` | std | request ⚠ | Dry-run a PO CSV |
| POST | `/api/admin/production-orders/csv/import` | std | request ⚠ | Upsert POs from CSV (ERP connector) |

### Downtimes

| Method | Path | Auth | Tenant | Purpose |
|---|---|---|---|---|
| POST | `/api/downtimes` | std | caller | Upsert a base downtime event (`downtime-event-created`) |
| POST | `/api/downtimes/justify` | std | caller | Classify an event (`event-justified` / `event-edited`) |
| POST | `/api/downtimes/split` | std | caller | Split an automated event |
| POST | `/api/downtimes/split-manual-downtime` | std | caller | Split a manual event |
| POST | `/api/downtimes/create-manual-event` | std | caller | Operator-authored downtime |
| POST | `/api/downtimes/edit-manual-event` | std | caller | Edit it |
| POST | `/api/downtimes/delete-manual-event` | std | caller | Delete it |
| GET | `/api/downtimes/pending` | std | caller | Unjustified events |
| GET | `/api/downtimes/justified` | std | caller | Justified events |
| GET | `/api/downtimes/line-member-stops` | std | caller | Member-machine stops under a line |

### Scans and samples

| Method | Path | Auth | Tenant | Purpose |
|---|---|---|---|---|
| POST | `/api/scanned-boxes` | std | caller | Gapless box scan (advisory-locked per PO) |
| GET | `/api/scanned-boxes` | std | caller | List scans |
| GET | `/api/samples` | std | caller | List samples |
| POST | `/api/samples/create`, `/edit`, `/delete` | std | caller | Sample rows |
| GET | `/api/labels` | std | caller | Label data |

### Hierarchy and configuration

| Method | Path | Auth | Tenant | Purpose |
|---|---|---|---|---|
| GET | `/api/enterprises` | CS | CS target | List tenants |
| GET | `/api/enterprises/:id` | CS | path | One tenant |
| POST | `/api/enterprises/create`, `/edit`, `/delete` | CS | request | Tenant lifecycle (create generates the api-key) |
| GET | `/api/sites` | std | caller | Sites |
| POST | `/api/sites/create`, `/edit`, `/delete` | std | request ⚠ | Site writes |
| GET | `/api/areas` | std | caller | Areas |
| POST | `/api/areas/create`, `/edit`, `/delete` | std | request ⚠ | Area writes |
| GET | `/api/equipments` | std | caller | Equipment |
| POST | `/api/equipments/create` | std | request ⚠ | Create equipment |
| POST | `/api/equipments/edit`, `/delete` | std | caller | Edit / soft-delete |
| POST | `/api/equipments/:id/move` | std | caller | Move within the hierarchy |
| GET | `/api/equipments/:id/reasons` | std | request ⚠ | Reason tree |
| POST | `/api/equipments/:id/reasons` | std | caller | Update reason tree |
| GET | `/api/lines` | std | caller | Lines (fenced since #272, 2026-09-28) |
| GET | `/api/entities/tree` | std | caller | Enterprise → site → area → equipment tree |
| GET | `/api/teams` | std | caller | Teams |
| POST | `/api/teams/create`, `/edit`, `/delete` | std | caller | Team writes |
| GET | `/api/packml-register` | std | caller | Topic registrations |
| POST | `/api/packml-register/create`, `/edit`, `/delete` | std | request ⚠ | Topic registration writes |
| GET | `/api/packml-config/generate` | std | caller | PackML config for a line |
| GET | `/api/shifts` | std | caller | Shift definitions |
| POST | `/api/shifts/create`, `/edit`, `/delete` | std | request ⚠ | Shift writes |
| GET | `/api/shift-hours` | std | caller | Shift calendar |
| POST | `/api/shift-hours/create`, `/edit`, `/delete` | std | request ⚠ | Calendar writes |
| GET | `/api/production-targets` | std | request ⚠ | Targets |
| POST | `/api/production-targets` | std | caller | Set default target (update-only) |
| POST | `/api/production-targets/scrap` | std | caller | Scrap target |
| PUT | `/api/production-targets/custom` | std | caller | Custom target |
| POST | `/api/production-targets/custom/delete` | std | caller | Remove custom target |
| POST | `/api/admin/downtime-reasons` | std | caller | Store reason tree |
| POST | `/api/admin/downtime-reasons/upload` | std | request ⚠ | Upload reasons CSV |
| GET | `/api/admin/downtime-reasons/download/:idEquipment` | std | request ⚠ | Download reasons CSV |

### Users, roles, i18n

| Method | Path | Auth | Tenant | Purpose |
|---|---|---|---|---|
| GET | `/api/users`, `/api/users/:id` | std | caller | Users |
| POST | `/api/users/create`, `/edit`, `/delete` | std | caller | User writes (role fenced) |
| GET | `/api/user-roles`, `/api/user-roles/:id` | std | caller | Roles |
| POST | `/api/user-roles/create`, `/edit`, `/delete` | std | caller | Role writes |
| GET | `/api/pages` | std | caller | Menu pages for the caller's role |
| GET, POST | `/api/cognito-users` | CS | CS target | List / create Cognito users |
| POST | `/api/cognito-users/disable`, `/enable` | CS | CS target | Toggle a Cognito user |
| GET | `/api/language-packs` | std | global | Language packs |
| POST | `/api/language-packs/create`, `/edit`, `/delete` | std | global | Language pack writes |
| GET | `/api/i18n/:app/:language` | std | caller | Resolved translations (tenant overlay) |
| POST | `/api/i18n/tenant-upsert` | std | caller | Tenant overlay key |
| POST | `/api/i18n/upsert`, `/api/i18n/import` | CS | global | Global translations |
| GET | `/api/i18n/export` | CS | global | Export translations |

### Telemetry status and BI

| Method | Path | Auth | Tenant | Purpose |
|---|---|---|---|---|
| GET | `/api/plc-status` | std | caller | Per-equipment liveness from analytics telemetry |
| GET | `/api/plc-status/plc-probe` | std | request ⚠ | Probe PLC reachability |
| GET | `/api/plc-status/:idEnterprise/agent-health?host=` | std | path ⚠ | Fetch an agent's `/healthz` + `/metrics` from the cloud |
| POST | `/api/superset/guest-token` | std | caller | Superset guest token with RLS `id_enterprise = N` |
| POST | `/api/admin/integrations/powerbi/embed-token` | std | none ⚠ (body names report/workspace) | Power BI embed token |
| POST | `/api/admin/integrations/powerbi/refresh-dataset`, `/refresh-dataset-token` | std | none ⚠ | Power BI refresh |

### Edge boxes, bundles, commands

| Method | Path | Auth | Tenant | Purpose |
|---|---|---|---|---|
| POST | `/api/edge-ssm/activation` | CS | CS target | Mint an SSM hybrid activation |
| GET | `/api/edge-ssm/status`, `/status/detailed`, `/health`, `/logs` | CS | CS target | Box state, health snapshot, logs |
| POST | `/api/edge-ssm/deploy`, `/deploy-bundle`, `/deploy-onprem`, `/restart`, `/bootstrap`, `/deregister` | CS | CS target | Box operations via SSM RunCommand (mocked for twin tenants) |
| POST | `/api/edge-ssm/apply-agent-config` | CS | CS target | Push tenant config to the shared sparkplug-agent |
| GET | `/api/edge-ssm/deploy/:commandId`, `/command/:commandId` | CS | CS target | Command result |
| GET | `/api/edge-ssm/connect` | CS | CS target | Port-forward instructions |
| POST | `/api/edge-ssm/session`; DELETE `/api/edge-ssm/session/:sessionId` | CS | CS target | Browser shell via edge-session-broker |
| POST | `/api/edge-ssm/webui` | CS | CS target | Open the box's Node-RED/dashboard through the reverse proxy |
| POST | `/api/edge-bundle/generate`, `/deploy` | CS | CS target | Build / deploy an edge bundle (GitHub workflow) |
| GET | `/api/edge-bundle/runs`, `/download` | CS | CS target | Bundle runs and artifacts |
| POST | `/api/commands/param-write`, `/api/commands/po-setup` | std | key | Publish an edge command to RabbitMQ (`COMMANDS_ENABLED`) |

### Onboarding, promotion, teardown (all CS, dark-by-default flags)

| Method | Path | Tenant | Purpose |
|---|---|---|---|
| GET, POST | `/api/onboarding/descriptor` | CS target | Read / upsert the tenant descriptor |
| PUT | `/api/onboarding/artifacts` | CS target | Edit generated artifacts |
| POST | `/api/onboarding/generate`, `/simulate` | CS target | Generate configs / preview derive rules (proxied to the decoder) |
| GET | `/api/onboarding/validate`, `/readiness`, `/plc-tag-map` | CS target | Checks and tag map |
| POST | `/api/onboarding/capture/start`, `/stop`, `/confirm`; GET `/capture/report` | CS target | Tag capture session |
| POST | `/api/onboarding/apply-register`, `/apply-line-meters`, `/cutover`, `/mark-deployed`, `/reset` | CS target | Apply and finish onboarding |
| GET, POST | `/api/onboarding/operator-edge`, `/barcode-edge`, `/onprem-offline` | CS target | On-prem app options |
| POST | `/api/promote/plan`, `/apply`; GET `/api/promote/bundle` | CS target | Staging → production config promotion |
| GET | `/api/teardown/plan` | CS target | Teardown dry run |
| POST | `/api/teardown/telemetry`, `/config`, `/shifts`, `/hierarchy`, `/identity`, `/box` | CS target | Staged client removal (protected tenants refused) |

## operator-gateway

Internal only on staging (`https://operator-gateway:8443`). Details:
[operator-gateway](../components/operator-gateway.md).

| Method | Path | Auth | Tenant | Purpose → edge-api |
|---|---|---|---|---|
| POST | `/operator/downtime` | ingest | configured enterprise | create/edit manual event |
| POST | `/operator/po` | ingest | configured enterprise | `create-and-start` |
| POST | `/operator/po/stop` | ingest | configured enterprise | `stop` |
| POST | `/operator/po/setup` | ingest | configured enterprise | `setup` |
| POST | `/operator/po/replace` | ingest | configured enterprise | `replace` |
| POST | `/operator/po/change-status` | ingest | configured enterprise | `change-status` |
| POST | `/operator/po/change-time` | ingest | configured enterprise | `change-time` |
| POST | `/operator/split` | ingest | configured enterprise | `downtimes/split` |
| GET | `/healthz`, `/metrics` | none | global | Health (incl. DB), Prometheus |

## barcode-service

Staging: `https://scan.staging.packiot.app` (superseded by edge-api `/api/scanned-boxes`).
Details: [barcode-service](../components/barcode-service.md).

| Method | Path | Auth | Tenant | Purpose |
|---|---|---|---|---|
| POST | `/v1/scans` | cognito | `custom:id_enterprise` claim | Gapless scan write |
| GET | `/v1/scans/stream?id_production_order=` | cognito | claim | SSE of accepted scans |
| GET | `/healthz`, `/metrics` | none | global | Health, placeholder metrics |
