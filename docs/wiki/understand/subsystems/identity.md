---
title: Identity and access
layer: 2
owner_area: identity
last_verified: 2026-10-13
---
# Identity and access

> **Layer 2 · Subsystems** — how a person or a factory device proves who it is, how that
> identity becomes a tenant, and how the tenant is enforced down to the database. For
> anyone touching login, users, roles or the tenant fence.
> Up: [Tenancy and security](../architecture/tenancy-and-security.md)

## Purpose

Identity answers two questions for every request: **who is calling** (authentication, or
authN) and **which enterprise's data may they touch** (authorization, or authZ). AWS Cognito
owns credentials. The analytics DB owns the mapping from a Cognito identity to an enterprise
and a role (`identity.users`, `identity.user_roles`). Factory devices and kiosk apps do not
log in as people; they use an **enterprise api-key**. Every backend derives the tenant
server-side from one of these credentials and never trusts a tenant id sent by the client,
except as a validated *target* for staff.

This page describes **staging**. The new-stack production compose points at the same Cognito
pool (with its own `oauth2-proxy-prod` client), but production has not been promoted (draft
PR #1653); production clients still log in to the legacy platform.

## Boundaries

**Owns:**

- The Cognito user pools, app clients, the hosted-UI domain and the user-migration Lambda
  (`terraform/staging/cognito.tf`, `cognito_dev.tf`, `cognito_migration_lambda.tf`).
- The edge sign-in gate: oauth2-proxy + host-nginx `auth_request` + the redis session store.
- The tables `identity.users`, `identity.user_roles` and the `api_key` column of
  `enterprises` (analytics DB).
- The authentication middleware of edge-api (`AuthMiddleware`), read-api (`authMiddleware`)
  and barcode-service, and the operator super-admin escalation.
- The per-transaction tenant GUC `app.tenant_id` that database row-level security (RLS) reads.

**Does not own:**

- What each dataset or endpoint returns — see [Serving & APIs](serving-apis.md).
- The RLS policies themselves — see [Analytics DB](analytics-db.md).
- CloudFront, WAF and the origin lock — see [Platform](platform.md).
- Telemetry ingest keys for edge boxes (`X-Ingest-Key`) — see [Edge](edge.md) and
  [Ingestion](ingestion.md).

## Components

| Component | What it does | Runtime | Layer-3 page |
|---|---|---|---|
| Cognito pool `packiot-staging` (`us-east-1_0T9t1sTwt`) | Holds users, passwords, the `cs-admin` group, custom attribute `id_enterprise`; issues ID tokens | AWS managed | [oauth2-proxy and Cognito](../components/oauth2-proxy-and-cognito.md) |
| App client `front4-amplify` | Public SPA client (no secret); used by front4, operator, csadmin, customize | AWS managed | same |
| App clients `oauth2-proxy-staging`, `oauth2-proxy-prod` | Confidential code-flow clients for the edge gate (hosted-UI domain `packiot-auth`) | AWS managed | same |
| Cognito pool `packiot-dev` + client `dev-spa` | Local development only (ADR-0060); ids in Secrets Manager `packiot/dev/cognito` | AWS managed | [Local development](../../build/develop/local-development.md) |
| `oauth2-proxy` | Forward-auth for host nginx; sessions in redis | container `oauth2-proxy` (:4180, loopback) | [oauth2-proxy and Cognito](../components/oauth2-proxy-and-cognito.md) |
| `cognito-user-migration` Lambda | Copies a Firebase user into Cognito on first login | Lambda, Node 20, arm64 | same |
| edge-api `AuthMiddleware` | Bearer JWT or api-key → `res.locals.callerEnterpriseId` | container `edge-api` | [edge-api](../components/edge-api.md) |
| read-api `authMiddleware` | `X-Api-Key` or Cognito Bearer → tenant bound as `$1` and `app.tenant_id` | container `read-api` | [read-api](../components/read-api.md) |
| barcode-service auth | Cognito Bearer → tenant from the signed `custom:id_enterprise` claim | container `barcode-service` | [barcode-service](../components/barcode-service.md) |
| `identity.users`, `identity.user_roles` | User → enterprise and role; `super_user` flag | analytics DB | [Analytics DB](analytics-db.md) |

## How it works

### Ways in

| Path | Who | Credential | Tenant comes from |
|---|---|---|---|
| **User token** | front4, csadmin, customize, operator `/session` | Cognito **ID token** (RS256, verified against the pool JWKS; `iss`, `aud` = `front4-amplify`, `exp`) | `identity.users` row whose `id_user_cognito` = token `sub` |
| **CS Admin token** | csadmin, customize | same ID token, `cognito:groups` contains `cs-admin` | the request's `?idEnterprise=` (edge-api honours it only for this group) |
| **api-key** | operator, barcode app, integrations | `x-api-key` = `enterprises.api_key` (edge-api) or a `QUERY_API_KEYS` entry (read-api) | the key's enterprise |
| **Claim** | scanner clients of barcode-service | Cognito ID/access token | `custom:id_enterprise` claim; no positive value → 401 |

- **edge-api** takes the Bearer path whenever `AUTH_BEARER_ENABLED` is on and an
  `Authorization: Bearer` header is present, and **fails closed**: a bad token is a 401,
  never a fall-back to the api-key. The deprecated `?token=` query string is still accepted
  as an api-key and logged as a warning.
- **read-api** accepts exactly two credentials: an `X-Api-Key` wins if present (a bad key
  401s, no fall-through); otherwise a Cognito Bearer. Firebase tokens are rejected (#159).
- **barcode-service** reads the tenant from the `custom:id_enterprise` attribute. Nothing in
  this repo or edge-api sets that attribute when creating users, so it must be set on the
  Cognito user by hand; the barcode *app* avoids this by writing through edge-api with a key.

```text
  person                              edge (host nginx)              backends
  ──────                              ─────────────────              ────────
  Cognito login ── ID token ─────────────────────────────────────▶ edge-api / read-api
   (Amplify SDK in the SPA)                                        verify JWKS → sub
                                                                   → identity.users
                                                                   → id_enterprise, role
  browser ── cookie ──▶ nginx auth_request ─▶ oauth2-proxy ─▶ redis (session)
                          any user: operator, operator-sbx, operator-bispharma
                          cs-admin: barcode, api root + /docs, grafana, db, rabbitmq
                          401 → 302 auth.staging.packiot.app/oauth2/start
                                 → Cognito hosted UI (packiot-auth) → /oauth2/callback

  kiosk nginx (operator, barcode) ── x-api-key (injected) ──▶ edge-api → enterprises.api_key
```

Two layers are easy to confuse:

1. **The edge gate** (oauth2-proxy) only decides whether the browser may load the page at
   all. It does not tell the backend who the user is (`OAUTH2_PROXY_PASS_ACCESS_TOKEN` is
   `false`). front4 (Amplify), csadmin and customize (`none-originverify`) are not behind it;
   `api.staging` bypasses it for `/api/*` and `/session*`.
2. **The application login** (Amplify SDK in the SPA against the `front4-amplify` client)
   produces the ID token the APIs trust. The operator app therefore asks for credentials
   twice on a fresh browser: once at the hosted UI (edge gate), once in its own login form.

### The two users tables

| Table | Database | Who reads it | Status |
|---|---|---|---|
| `identity.users` (+ `identity.user_roles`) | analytics DB `packiot_analytics` | read-api and edge-api (`POSTGRES_DB: packiot_analytics` since 2026-09-08) | **authoritative on staging** |
| `users` | legacy DB (`packiot40`/tsp12) | legacy production apps (e.g. front4 on `go.packiot.com`) | legacy |

The schema was named `auth` until migration `t247-auth-to-identity` renamed it; the
analytics DB `search_path` includes `identity`, so bare `users` resolves there. Key columns:
`id_user_cognito` (the link to Cognito `sub`, partial unique index), `id_enterprise`,
`user_roles` (a scalar FK to `identity.user_roles.id_user_role` despite the plural name),
`user_name`, `user_email`, `active`, `internal_user`.

### Linking a Cognito user to a row

A Cognito user with no matching `identity.users.id_user_cognito` authenticates but resolves
to no tenant, so every API call 401s. Three mechanisms create the link:

1. **Born-linked**: csadmin's Users page calls `POST /api/cognito-users` (CS-Admin only),
   which runs `AdminCreateUser` (Cognito emails an invite), adds `cs`-type users to the
   `cs-admin` group, and writes the `users` row with `id_user_cognito` in the same call.
2. **Link-on-login self-heal**: edge-api (`linkCognitoByEmail`) and read-api bind a
   verified-email Cognito token to the **earliest** `users` row with that email and
   `id_user_cognito IS NULL`, then re-resolve. It targets one row because the same email
   can exist in a real tenant and its sandbox clone (fix of 2026-09-03).
3. **By hand**: `UPDATE identity.users SET id_user_cognito = '<sub>' WHERE id_user = …`.

The operator `/session` endpoint does **not** use `id_user_cognito`; it looks the user up by
`identity.users.user_name = <verified email>` (active users only). An operator user therefore
needs `user_name` set to the email.

### Super-admin (operator and front4)

A super-admin can switch the operator app, or front4, onto any enterprise. All of these must
hold, checked on every request:

1. `identity.user_roles.super_user = true` for the user's role (live DB, never from the token);
2. the verified email is in `OPERATOR_SUPERADMIN_ALLOWLIST` (default: one built-in address);
3. `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED=true` on **both** edge-api and read-api;
4. the target enterprise exists and is active.

The client sends `?idEnterprise=<target>` plus the header `x-operator-superadmin-token`
(its Cognito ID token); the operator nginx forwards that header to read-api. Both APIs
verify it RS256/JWKS. Any failure falls back to the home tenant, never a 401 and never a
leak. The super-admin user belongs to the internal enterprise `PACKIOT-ADMIN` (id 1000000);
its password is in Secrets Manager.

### Tenant into the database: the RLS GUC

read-api connects as `readapi_ro` (NOSUPERUSER, NOBYPASSRLS; migration
`t276-readapi-ro-nobypassrls`). For every tenant-scoped read it opens a transaction, runs
`SELECT set_config('app.tenant_id', '<id>', true)` (transaction-local, safe behind pgbouncer
transaction pooling) and then the query with the tenant also bound as `$1`. RLS policies on
tenant tables compare rows against that GUC. Superset guest tokens carry an RLS clause
`id_enterprise = N` minted by edge-api (`POST /api/superset/guest-token`) from the caller's
own tenant. Note: `compose.production.yml` still runs read-api as `POSTGRES_USER`, which
bypasses RLS; switch it to `readapi_ro` before promotion.

## Interfaces

| Interface | Producer → consumer | Detail |
|---|---|---|
| Cognito JWKS | Cognito → edge-api, read-api, barcode-service | `<issuer>/.well-known/jwks.json` for pool `us-east-1_0T9t1sTwt` |
| `/oauth2/auth`, `/oauth2/auth-csadmin` | host nginx → oauth2-proxy | internal subrequests; the second requires group `cs-admin` |
| `auth.staging.packiot.app/oauth2/*` | browser → oauth2-proxy | start, callback, sign_out; everything else 404 |
| `POST /session`, `/session/switch`, `GET /session/enterprises` | operator, front4 → edge-api | Cognito-authed bootstrap and super-admin switch |
| `/api/cognito-users` | csadmin → edge-api | CS-Admin-only user management |
| `x-api-key` | kiosk nginx, integrations → edge-api, read-api | tenant key |

API detail: [edge-api](../../reference/api/edge-api.md), [read-api](../../reference/api/read-api.md),
[barcode-service](../../reference/api/barcode-service.md); services in the
[service catalog](../../reference/service-catalog.md).

## Data it owns

| Data | Where | Lifecycle |
|---|---|---|
| Cognito users, group `cs-admin` | Cognito pool | created by csadmin or the AWS CLI; group membership managed by edge-api or by hand |
| `identity.users`, `identity.user_roles` | analytics DB | created at onboarding; soft-deleted with `active` |
| `enterprises.api_key` | analytics DB | `randomUUID()` at enterprise creation |
| Read keys | `QUERY_API_KEYS` on read-api (`key:enterprise` pairs in `compose.staging.yml`) | edited in compose; five tenants on staging |
| oauth2-proxy sessions | `app-redis` DB 1 | lost when `app-redis` restarts (`--appendonly no --save ""`) |
| E2E QA users | Secrets Manager `packiot/staging/e2e-test-creds` | see `e2e/README.md` |

## Configuration that matters

| Variable | Service | Staging value | Effect |
|---|---|---|---|
| `AUTH_BEARER_ENABLED` | edge-api | `true` | enables the Bearer path |
| `EDGE_API_COGNITO_AUTH_ENABLED`, `COGNITO_CS_ADMIN_GROUP` | edge-api | `true`, `cs-admin` | enables the CS-Admin `?idEnterprise=` target |
| `COGNITO_ISSUER`, `COGNITO_CLIENT_ID` | edge-api, read-api, barcode-service | staging pool; `front4-amplify` client | `aud` check: a token from another client (or the dev pool) 401s |
| `COGNITO_AUTH_ENABLED` | read-api | `true` | no effect today (nothing reads it); Cognito is always on |
| `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | edge-api, read-api | `true` | one switch for picker, switch, cross-tenant reads and writes |
| `OPERATOR_SUPERADMIN_ALLOWLIST` | edge-api, read-api | unset → built-in default | who may be super-admin |
| `QUERY_API_KEYS` | read-api | keys for tenants 3, 2, 4, 2000003, 5 | read keys for kiosk apps and integrations |
| `OAUTH2_PROXY_SESSION_STORE_TYPE` | oauth2-proxy | `redis` | keeps the cookie small (see failure modes) |
| `MIGRATION_ENABLED` | migration Lambda | `true` | Firebase → Cognito copy on first login |
| `service_auth` | `terraform/staging/variables.tf` | per vhost | which edge gate each vhost gets |

## Failure modes & signals

| Symptom | Cause | Fix / where to look |
|---|---|---|
| front4 renders with no data; every `/v1/query` 401 | Cognito `sub` not linked in `identity.users` (2026-09-03: duplicate email across real + sandbox rows broke the self-heal) | link the row; self-heal now targets one row |
| "Couldn't load your workspace data", then a render crash | role has empty `permissions.desktop.line` (2026-08-17) | grant the role its lines; read-api caches the tenant lookup for 5 min |
| Operator login: 401 "No operator account for this identity" | `identity.users.user_name` ≠ the Cognito email | set `user_name` to the email |
| barcode-service 401 for a valid user | no `custom:id_enterprise` on the Cognito user | set the attribute, or use the barcode app (edge-api + key) |
| Super-admin writes land in the home tenant | write verifier expected HS256 (#188, fixed 2026-09-06) | both verifiers are RS256/JWKS |
| All admin UIs: CloudFront 403 "Request blocked" | oauth2-proxy cookie grew past WAF's 8 KB cookie limit (2026-09-13) | redis session store (PR #1219); clear `*.staging.packiot.app` cookies once |
| Everyone is logged out at once | `app-redis` restarted (sessions not persisted) | log in again |
| Every request 401 in local dev | token from the dev pool sent to staging, or vice versa | match `COGNITO_ISSUER`/`COGNITO_CLIENT_ID` to the pool |

## History & decisions

- **ADR-0033**: unified JWT auth on edge-api (Bearer dual-accept, `TenantFence`).
- **ADR-0034**: Cognito replaces Firebase; oauth2-proxy replaces Authentik (2026-08-05);
  operator Cognito-only (2026-09-03); Firebase retired from edge-api and read-api (#159).
- **ADR-0027**: read contract, the client never names a tenant (super-admin is the one
  flag-gated exception).
- **ADR-0056**: one app database with schemas; the `identity` schema name (t247).
- **ADR-0060**: separate `packiot-dev` Cognito pool for local development.
- Migration `t276`: read-api stops running as a BYPASSRLS superuser (2026-09-13).
- 2026-10-13: two cross-tenant fixes — barcode-service `scan_uuid` replay of another tenant's
  scan → 409 `scan_uuid_conflict` (#1688); edge-api downtime upsert on another tenant's
  equipment → 403 (edge-api #302). See [Tenancy and security](../architecture/tenancy-and-security.md).

## Go deeper

- [oauth2-proxy and Cognito](../components/oauth2-proxy-and-cognito.md)
- [edge-api](../components/edge-api.md) · [read-api](../components/read-api.md) ·
  [barcode-service](../components/barcode-service.md)
- [Frontends](frontends.md) · [Tenancy and security](../architecture/tenancy-and-security.md)
- Runbook: `docs/runbooks/oauth2-proxy-cognito-migration.md`
