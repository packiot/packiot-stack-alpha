---
title: Tenancy and security
layer: 1
owner_area: identity
last_verified: 2026-10-13
---
# Tenancy and security

> **Layer 1 · Architecture.** How Packiot keeps each client's data isolated and who may do
> what, across the whole stack (staging unless stated). Up: [Architecture overview](overview.md)

## The two rules

1. **The tenant (enterprise) is always derived server-side from the caller's credential,
   never from a value the caller sends.** A `?idEnterprise=` or body field is at most a
   *target selector* for staff authorised for several tenants, and is validated against that
   authorisation.
2. **Fence a write on the same column the reads scope on.** If the screens that show a row
   find it through `equipments.id_enterprise`, a write must prove the caller owns that
   equipment, not just stamp its own `id_enterprise` on the row. Every id in a request body
   (equipment, PO, event, scan) must be checked against the caller's tenant before it is used,
   including on idempotent-replay and upsert paths.

## Who calls, with what credential

```text
 factory apps (operator)      ──▶ nginx injects the tenant api-key ──▶ edge-api / read-api
 (browser never holds the key)     (per deployment, server side)
 staff & managers (front4,    ──▶ Cognito login in the app (Amplify) ──▶ JWT ──▶ APIs
  csadmin, customize)              user pool us-east-1_0T9t1sTwt
 operator & barcode apps      ──▶ also gated at the nginx edge by oauth2-proxy (Cognito)
 BI (Superset embeds)         ──▶ guest token from edge-api with RLS clause id_enterprise = N
 edge readers                 ──▶ HTTPS raw tags, X-Ingest-Key; Sparkplug group → tenant
```

| Caller | Credential | Tenant resolution |
|---|---|---|
| Factory app / integration | enterprise **api-key** (`x-api-key`, injected by nginx for the operator SPAs; the `?token=` query form is deprecated) | the key's enterprise (edge-api `AuthMiddleware` → `callerEnterpriseId(res)`); read-api `QUERY_API_KEYS` map |
| Manager / staff user | Cognito JWT (`Authorization: Bearer`) | read-api: the user row matched by `id_user_cognito`; edge-api: the user's enterprise. Firebase tokens are rejected (Firebase retired on staging). |
| CS Admin | Cognito JWT in group `cs-admin` | validated target from `?idEnterprise=` |
| Operator super-admin | api-key + a verified `x-operator-superadmin-token` (`OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED`, on in staging) | cross-tenant target, audited |
| barcode-service | Cognito JWT | the token's `custom:id_enterprise` claim |
| Superset guest | short-lived guest token minted by edge-api | Superset applies the RLS clause `id_enterprise = N` to every query |
| Edge reader | `X-Ingest-Key` on the HTTPS front door | Sparkplug group from the body or `X-Ingest-Group` → topic → `packml_register` → equipment → enterprise |

## Defence in depth

| Layer | Mechanism | Where |
|---|---|---|
| API (writes) | Controllers read the tenant with `callerEnterpriseId(res)`, overwrite any body/query tenant with it, and `TenantFence.assertRefs` checks every referenced id belongs to it (cross-tenant write fence, 2026-09-28). A foreign id is a 404, so the response does not reveal that the row exists. | [edge-api](../components/edge-api.md) |
| API (reads) | Every read-api dataset is tenant-scoped (`WHERE id_enterprise = $1`; CI test `TestEveryDatasetIsTenantScoped`) and stamps `app.tenant_id` per query. | [read-api](../components/read-api.md) |
| Database role | read-api connects as **`readapi_ro`** (NOSUPERUSER, NOBYPASSRLS; migration `t276`); Superset as `superset_ro`; read-api and Superset reach the historian gateway as `historian_svc`. operator-gateway's resolver connects as **`operator_gateway`** (NOBYPASSRLS, 10 `SELECT` columns, read-only sessions; migration `t-operator-gateway-role`) and stamps its enterprise per transaction, so RLS backs its fence. Writers (edge-api, stream-engine) connect as owners and bypass RLS, so for them the app fence is the only fence. | [Analytics DB](../subsystems/analytics-db.md) |
| Database RLS | `FORCE ROW LEVEL SECURITY` + `tenant_isolation` policies keyed on `app.tenant_id` (`is_all_tenant() OR id_enterprise = current_tenant()`) on tenant tables such as `core.equipments`, `core.production_orders`, `gold.equipment_oee_*`, `core.topic_routing`, `core.device_bindings`. `serving.*` views are `security_invoker` (`t280`), so RLS applies through them. | `db/superset/02-tenant-rls.sql`, `db/migrations/` |
| Mirror tenant (staging) | edge-api refuses PO, downtime and shift writes for enterprise 3 (`OPERATOR_WRITE_BLOCKED_ENTERPRISES=3` → 403 `MIRROR_TENANT_WRITE_BLOCKED`), because CPACK is replicated from legacy. | [Legacy bridge](../subsystems/legacy-bridge.md) |
| Logs | edge-api's request logger redacts credentials (`x-api-key`, `Authorization`, cookies, `?token=`) and credential-like body keys before writing (`src/middleware/redact.ts`, 2026-09-28). | [edge-api](../components/edge-api.md) |
| Edge | Boxes are reached only through AWS SSM (no inbound ports); box operations are audited; mutating box ops are mocked for twin tenants (ids ≥ 2,000,000). | [Edge box](../components/edge-box.md) |
| Network | Public entry through CloudFront + WAF to nginx. operator and barcode apps and staff consoles are gated by oauth2-proxy; csadmin and customize are origin-verify only and front4 is on Amplify, so those three rely on in-app Cognito plus API-side authorisation. Secrets live in AWS Secrets Manager. | [Platform](../subsystems/platform.md), [oauth2-proxy & Cognito](../components/oauth2-proxy-and-cognito.md) |

## Incidents that shaped the rules

| Date | What happened | Fix |
|---|---|---|
| 2026-09-21 | The downtime split matched on `id_equipment_event`, which is not unique across tenants; the sandbox (ids +2,000,000 of CPACK's) wrote into CPACK. | tenant-pinned DAO (edge-api #266); the event closer matches on the true key (2026-09-28) |
| 2026-09-28 | `GET /api/lines` and several control-plane mutations took the tenant from the body or query. | `callerEnterpriseId` + `TenantFence` on every controller (edge-api #272 and the cross-tenant write fence) |
| 2026-10-13 | barcode-service's idempotent replay looked up `scan_uuid` before the tenant fence, so another tenant's `scan_uuid` returned that tenant's box id, label sequence and PO total. | the replay checks the row's owner; a foreign `scan_uuid` is `409 scan_uuid_conflict` (#1688) |
| 2026-10-13 | edge-api `POST /api/downtimes` (upsert) stamped the caller's `id_enterprise` but never checked that each event's equipment belonged to the caller; reads scope on `equipments.id_enterprise`, so the event showed up in the other tenant's downtimes. | foreign equipment → 403 and nothing written; the DAO insert is also guarded (edge-api #302) |

The last two are rule 2 in action.

## Known sharp edges

- **Sandbox twin (2000003) shares ids with CPACK (+2,000,000).** Any code that matches on a
  non-unique id can cross tenants; address rows by their true key and tenant.
- **The shared ingest door trusts the request for the tenant.** `sparkplug-agent-shared` has
  one `X-Ingest-Key` for all tenants and routes by the Sparkplug group in the body or the
  `X-Ingest-Group` header; the extra fence is network-level (the security group admits only
  each onboarded box's source address on `:8449`). A key holder inside that allowlist could
  claim another group.
- **Production MQTT ACL not wired.** `compose.production.yml` mounts `mosquitto.prod.conf`
  (mTLS on `:8883`, no `acl_file`); the per-tenant ACL `prod-ingest.acl` is only loaded by
  `mosquitto-prod-ingest.conf`. See [brokers](../components/brokers.md).
- **Views and RLS.** A `serving.*` view recreated without `security_invoker = on` evaluates RLS
  as its owner (a superuser) and silently stops fencing; change serving views only through
  migrations.
- **Reviewers:** grep new controllers for `req.query.idEnterprise` / `input.idEnterprise` used
  before `callerEnterpriseId`, and new writes for ids that skip `TenantFence`.

Go deeper: [Identity](../subsystems/identity.md) ·
[oauth2-proxy & Cognito](../components/oauth2-proxy-and-cognito.md) ·
[edge-api](../components/edge-api.md) · [read-api](../components/read-api.md) ·
[barcode-service](../components/barcode-service.md)
