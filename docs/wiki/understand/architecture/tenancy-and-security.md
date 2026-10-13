---
title: Tenancy and security
layer: 1
owner_area: identity
last_verified: 2026-09-28
---
# Tenancy and security

> **Layer 1 · Architecture.** How Packiot keeps each client's data isolated and who may do
> what, across the whole stack. Up: [Architecture overview](overview.md)

## The one rule

**The tenant (enterprise) is always derived server-side from the caller's credential, never
from a value the caller sends.** A `?idEnterprise=` or body field is at most a *target
selector* for staff who are authorised for several tenants, and is validated against that
authorisation.

## Who calls, with what credential

```text
 factory apps (operator, barcode) ──▶ nginx injects the tenant api-key ──▶ edge-api / read-api
 (browser never holds the key)         (per-deployment, server side)
 staff & managers (front4, csadmin,  ──▶ Cognito login in the app (Amplify) ──▶ JWT ──▶ APIs
  customize)                            user pool us-east-1_0T9t1sTwt
 operator & barcode apps             ──▶ also gated at the edge by oauth2-proxy (Cognito hosted UI)
 BI (Superset embeds)               ──▶ guest token carrying an RLS clause (id_enterprise = N)
 edge boxes                          ──▶ Sparkplug over MQTT; the topic's group maps to a tenant
```

| Caller | Credential | Tenant resolution |
|---|---|---|
| Factory app / integration | enterprise **api-key** (`x-api-key`, injected by nginx for the SPAs) | the key's enterprise (edge-api `AuthMiddleware` → `res.locals.callerEnterpriseId`) |
| Manager / operator user | Cognito JWT | the user row in `identity.users` (read-api) / the user's enterprise (edge-api) |
| CS Admin | Cognito JWT in group `cs-admin` | validated target from `?idEnterprise=` |
| Operator super-admin | api-key + a verified `x-operator-superadmin-token` (feature-flagged) | cross-tenant target, audited |
| Superset guest | guest token from `edge-api` | RLS clause `id_enterprise = N` → Postgres GUC `app.tenant_id` |
| Edge box | MQTT connection to the ingest broker | Sparkplug group/topic → `core.topic_routing` → equipment → enterprise |

## Defence in depth

| Layer | Mechanism | Where |
|---|---|---|
| API | Controllers are meant to read the tenant through `callerEnterpriseId(res)`, and fenced mutations assert the target equipment / PO belongs to it (`TenantFence`). **Not yet universal** — see the exceptions under *Known sharp edges*. | [edge-api](../components/edge-api.md) |
| API | Every read-api dataset is tenant-scoped (`WHERE id_enterprise = $1`, CI test `TestEveryDatasetIsTenantScoped`) and stamps `app.tenant_id` per query. | [read-api](../components/read-api.md) |
| Database role | read-api connects as **`readapi_ro`** (NOSUPERUSER, NOBYPASSRLS; migration `t276`), historian reads as `historian_svc`, Superset as `superset_ro`. | [Analytics DB](../subsystems/analytics-db.md) |
| Database RLS | `FORCE ROW LEVEL SECURITY` + `tenant_isolation` policies on tenant tables (`core.equipments`, `core.production_orders`, `gold.equipment_oee_*`, …) keyed on `app.tenant_id`. | `db/superset/02-tenant-rls.sql` |
| Writes by key | Mutations address rows by their true key and tenant, never by a non-unique id (`id_equipment_event` is not unique across tenants). | 2026-09-21 incident |
| Edge | Boxes are reached only through AWS SSM (no inbound ports); box operations are audited. | [Edge box](../components/edge-box.md) |
| Network | Public entry through CloudFront + WAF; operator and barcode apps additionally gated by oauth2-proxy at the edge. csadmin and customize are **not** edge-gated (origin-verify only) and front4 is served by Amplify, so all three rely on in-app Cognito login plus API-side authorisation. Secrets live in AWS Secrets Manager. | [Platform](../subsystems/platform.md), [oauth2-proxy & Cognito](../components/oauth2-proxy-and-cognito.md) |

## Known sharp edges

- **Sandbox twin (2000003) shares ids with CPACK (+2,000,000).** Any code that matches on a
  non-unique id can cross tenants. The 2026-09-21 downtime-split bug wrote from the sandbox
  into CPACK this way; fixed by tenant-pinning (edge-api #266). The event closer matches on
  the true key since 2026-09-28.
- **An endpoint that forgets `callerEnterpriseId`** trusts the client. `GET /api/lines` did
  until 2026-09-28 (edge-api #272). As of 2026-09-28 several control-plane mutations still do
  (areas, sites, shifts, shift-hours, topic routing, equipment create, reasons, PO CSV import):
  they take the tenant from the body or query and update by id without a tenant predicate. See
  [edge-api › failure modes](../components/edge-api.md#failure-modes). Reviewers: grep new
  controllers for `req.query.idEnterprise` / `input.idEnterprise`.
- **edge-api's request logger writes full request headers**, including `x-api-key` and
  `Authorization`, to container logs (and so to Loki). Treat those logs as sensitive until fixed.
- **Definer views and RLS.** Recreating an RLS'd definer view as a superuser flips its owner
  and silently disables the fence; change serving views through migrations, not ad hoc.

Go deeper: [Identity](../subsystems/identity.md) ·
[oauth2-proxy & Cognito](../components/oauth2-proxy-and-cognito.md) ·
[edge-api](../components/edge-api.md) · [read-api](../components/read-api.md)
