---
title: Identity and access
layer: 2
owner_area: identity
last_verified: 2026-09-28
---
# Identity and access

> **Layer 2 · Subsystems** — how a person or a factory device proves who it is, how that
> identity becomes a tenant, and how the tenant is enforced down to the database. For
> anyone touching login, users, roles or the tenant fence.
> Up: [Tenancy and security](../architecture/tenancy-and-security.md)

## Purpose

Identity answers two questions for every request: **who is calling** (authentication, or
authN) and **which enterprise's data may they touch** (authorization, or authZ). AWS Cognito
owns credentials. The application database owns the mapping from a Cognito identity to an
enterprise and a role (`identity.users`, `identity.user_roles`). Factory devices and kiosk
apps do not log in as people; they use an **enterprise api-key**. Every backend derives the
tenant server-side from one of these credentials and never trusts a tenant id sent by the
client, except as a validated *target* for staff.

## Boundaries

**Owns:**

- The Cognito user pool, its app clients, the hosted-UI domain and the user-migration Lambda
  (`terraform/staging/cognito.tf`, `cognito_migration_lambda.tf`).
- The edge sign-in gate: oauth2-proxy + host-nginx `auth_request` + the redis session store.
- The tables `identity.users`, `identity.user_roles` (analytics DB) and the `api_key` column
  of `enterprises`.
- The three authentication paths in edge-api's `AuthMiddleware` and read-api's
  `authMiddleware`, and the operator super-admin escalation.
- The per-transaction tenant GUC `app.tenant_id` that database row-level security (RLS) reads.

**Does not own:**

- What each dataset or endpoint returns — see [Serving & APIs](serving-apis.md).
- The RLS policies themselves — see [Analytics DB](analytics-db.md).
- CloudFront, WAF and the origin lock — see [Platform](platform.md).
- MQTT/ingest authentication for edge boxes (`X-Ingest-Key`) — see [Ingestion](ingestion.md).

## Components

| Component | What it does | Runtime | Layer-3 page |
|---|---|---|---|
| Cognito pool `packiot-staging` (`us-east-1_0T9t1sTwt`) | Holds users, passwords, the `cs-admin` group; issues ID tokens | AWS managed | [oauth2-proxy and Cognito](../components/oauth2-proxy-and-cognito.md) |
| App client `front4-amplify` | Public SPA client (no secret); used by front4, operator, csadmin, customize | AWS managed | same |
| App clients `oauth2-proxy-staging`, `oauth2-proxy-prod` | Confidential code-flow clients for the edge gate | AWS managed | same |
| `oauth2-proxy` | Forward-auth for host nginx; sessions in redis | container `oauth2-proxy` (:4180, loopback) | same |
| `cognito-user-migration` Lambda | Copies a Firebase user into Cognito on first login | Lambda, Node 20, arm64 | same |
| edge-api `AuthMiddleware` | Bearer JWT or api-key → `res.locals.callerEnterpriseId` | container `edge-api` | [edge-api](../components/edge-api.md) |
| read-api `authMiddleware` | read key or Bearer JWT → tenant bound as `$1` and `app.tenant_id` | container `read-api` | [read-api](../components/read-api.md) |
| `identity.users`, `identity.user_roles` | User → enterprise and role; `super_user` flag | analytics DB | [Analytics DB](analytics-db.md) |

## How it works

### Three ways in

| Path | Who | Credential | Tenant comes from |
|---|---|---|---|
| **User token** | front4, csadmin, customize, operator `/session` | Cognito **ID token** (RS256, verified against the pool JWKS; `iss`, `aud` = `front4-amplify` client, `exp`) | `identity.users` row whose `id_user_cognito` = token `sub` |
| **CS Admin token** | csadmin, customize | same ID token, `cognito:groups` contains `cs-admin` | the request's `?idEnterprise=` (honoured only for this group) |
| **api-key** | operator writes, barcode, edge boxes, integrations | `x-api-key` = `enterprises.api_key` (edge-api) or a read key from `QUERY_API_KEYS` (read-api) | the key's enterprise |

edge-api picks the Bearer path whenever `AUTH_BEARER_ENABLED` is on and an
`Authorization: Bearer` header is present, and **fails closed**: a bad token is a 401,
never a fall-back to the api-key. read-api does the opposite precedence: an `X-Api-Key`
wins if present. The deprecated `?token=` query string is still accepted by edge-api as an
api-key and logged as a warning.

```text
  person                              edge (host nginx)              backends
  ──────                              ─────────────────              ────────
  Cognito login ── ID token ─────────────────────────────────────▶ edge-api / read-api
   (Amplify SDK in the SPA)                                        verify JWKS → sub
                                                                   → identity.users
                                                                   → id_enterprise, role
  browser ── cookie ──▶ nginx auth_request ─▶ oauth2-proxy ─▶ redis (session)
                          (operator, barcode, api root, grafana, db, rabbitmq)
                          401 → 302 auth.staging.packiot.app/oauth2/start
                                 → Cognito hosted UI (packiot-auth) → /oauth2/callback

  kiosk nginx (operator, barcode) ── x-api-key (injected) ──▶ edge-api → enterprises.api_key
```

Two layers are easy to confuse:

1. **The edge gate** (oauth2-proxy) only decides whether the browser may load the page at
   all. It does not tell the backend who the user is; `OAUTH2_PROXY_PASS_ACCESS_TOKEN` is
   `false`. Operator and barcode sit behind it; front4, csadmin and customize do not
   (csadmin and customize are `none-originverify` in `terraform/staging/variables.tf`
   and verified to return 200 without a session on 2026-09-28).
2. **The application login** (Amplify SDK in the SPA, username + password against the
   `front4-amplify` client) produces the ID token the APIs trust. The operator app
   therefore asks for credentials twice on a fresh browser: once at the hosted UI (edge
   gate), once in its own login form.

### The two users tables

| Table | Database | Who reads it | Status |
|---|---|---|---|
| `identity.users` (+ `identity.user_roles`) | analytics DB `packiot_analytics` | read-api (bare `users` resolves here via the database `search_path`), and edge-api since 2026-09-08 (`POSTGRES_DB: packiot_analytics`, PR #1130) | **authoritative on staging** |
| `users` in `packiot` | legacy DB (production `packiot40`/tsp12; also the old F1 `packiot` DB on the staging DB host) | legacy production edge-api and front4 on `go.packiot.com` | legacy |

The schema was named `auth` until migration `t247-auth-to-identity` renamed it; the
analytics DB `search_path` includes `identity` so bare `users` resolves there. Key columns:
`id_user_cognito` (the link to Cognito `sub`, partial unique index), `id_enterprise`,
`user_roles` (a scalar FK to `identity.user_roles.id_user_role` despite the plural name),
`user_name`, `user_email`, `active`, `internal_user`. `id_user_firebase` was dropped.

!!! warning "Unverified"
    Some runbooks from before 2026-09-08 insert a new user into **both** tables. Whether
    any staging service still reads `packiot.users` today was not verified; new-stack code
    paths read only `identity.users`.

### Linking a Cognito user to a row

A Cognito user with no matching `identity.users.id_user_cognito` authenticates but resolves
to no tenant, so every API call 401s. Three mechanisms create the link:

1. **Born-linked**: csadmin's Users page calls `POST /api/cognito-users` (CS-Admin only),
   which runs `AdminCreateUser` (Cognito emails an invite), adds `cs`-type users to the
   `cs-admin` group, and writes the `users` row with `id_user_cognito` in the same call.
   front4's `POST /api/users/create` does the same with a password it sets.
2. **Link-on-login self-heal**: edge-api (`linkCognitoByEmail`) and read-api
   (`linkCognitoSQL`) bind a verified-email Cognito token to the **earliest** `users` row with
   that email and `id_user_cognito IS NULL`, then re-resolve. It targets one row because the
   same email can exist in a real tenant and its sandbox clone (fix of 2026-09-03).
3. **By hand**: `UPDATE identity.users SET id_user_cognito = '<sub>' WHERE id_user = …`.

The operator `/session` endpoint does **not** use `id_user_cognito`; it looks the user up by
`identity.users.user_name = <verified email>`. An operator user therefore needs
`user_name` set to the email.

### Super-admin (operator and front4)

A super-admin can switch the operator app, or front4, onto any enterprise. All of these must
hold, checked on every request:

1. `identity.user_roles.super_user = true` for the user's role (live DB, never from the token);
2. the verified email is in `OPERATOR_SUPERADMIN_ALLOWLIST` (default `dev@packiot.com`);
3. `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED=true` on **both** edge-api and read-api;
4. the target enterprise exists and is active.

The client sends `?idEnterprise=<target>` plus the header `x-operator-superadmin-token`
(its Cognito ID token). edge-api's `OperatorSuperAdminVerifier` and read-api's
`auth_operator_superadmin.go` both verify it RS256/JWKS. Any failure silently falls back to
the home tenant, never a 401 and never a leak. On staging `dev@packiot.com` belongs to the
internal enterprise `PACKIOT-ADMIN` (id 1000000). The password is in Secrets Manager
`packiot/staging/operator/dev-superadmin-password`.

### Tenant into the database: the RLS GUC

read-api connects as `readapi_ro` (NOSUPERUSER, NOBYPASSRLS; migration `t276`). For every
tenant-scoped read it opens a transaction, runs
`SELECT set_config('app.tenant_id', '<id>', true)` (transaction-local, safe behind
pgbouncer transaction pooling) and then the dataset query with the tenant also bound as
`$1`. RLS policies on tenant tables compare rows against `current_tenant()`, which reads that
GUC. The id always comes from the resolved credential, never from the request body.
Superset guest tokens carry an RLS clause `id_enterprise = N` minted by edge-api
(`POST /api/superset/guest-token`) from the caller's own tenant.

## Interfaces

| Interface | Producer → consumer | Detail |
|---|---|---|
| Cognito JWKS | Cognito → edge-api, read-api | `https://cognito-idp.us-east-1.amazonaws.com/us-east-1_0T9t1sTwt/.well-known/jwks.json` |
| `/oauth2/auth`, `/oauth2/auth-csadmin` | host nginx → oauth2-proxy | internal subrequests; the second adds `allowed_groups=cs-admin` |
| `auth.staging.packiot.app/oauth2/*` | browser → oauth2-proxy | start, callback, sign_out; everything else 404 |
| `POST /session`, `/session/switch`, `GET /session/enterprises` | operator, front4 → edge-api | Cognito-authed bootstrap and super-admin switch |
| `POST /api/cognito-users` (+ `disable`, `enable`, `GET`) | csadmin → edge-api | CS-Admin-only user management |
| `x-api-key` | kiosk nginx, edge boxes → edge-api, read-api | tenant key |

## Data it owns

| Data | Where | Lifecycle |
|---|---|---|
| Cognito users, group `cs-admin` | Cognito pool | created by csadmin or the AWS CLI; the `cs-admin` group is managed by hand |
| `identity.users`, `identity.user_roles` | analytics DB | created at onboarding; soft-deleted with `active` |
| `enterprises.api_key` | analytics DB | `randomUUID()` at enterprise creation (`create-enterprise.service.ts`) |
| Read keys | `QUERY_API_KEYS` env on read-api (`key:enterprise` pairs, compose.staging.yml) | edited in compose |
| oauth2-proxy sessions | `app-redis` logical DB 1 | lost when `app-redis` restarts (no persistence configured) |
| E2E QA users | Secrets Manager `packiot/staging/e2e-test-creds` | see `e2e/README.md` |

## Configuration that matters

| Variable | Service | Staging value | Effect |
|---|---|---|---|
| `AUTH_BEARER_ENABLED` | edge-api | `true` | enables the Bearer path |
| `EDGE_API_COGNITO_AUTH_ENABLED`, `COGNITO_CS_ADMIN_GROUP` | edge-api | `true`, `cs-admin` | enables the CS-Admin `?idEnterprise=` escalation |
| `COGNITO_ISSUER`, `COGNITO_CLIENT_ID` | edge-api, read-api | pool issuer; `front4-amplify` client | `aud` check: a token from another client 401s |
| `COGNITO_AUTH_ENABLED` | read-api | `true` | enables the Bearer path on `/v1` |
| `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | edge-api, read-api | `true` | one switch for picker, switch, cross-tenant reads and writes |
| `OPERATOR_SUPERADMIN_ALLOWLIST` | edge-api, read-api | unset → `dev@packiot.com` | who may be super-admin |
| `QUERY_API_KEYS` | read-api | CPACK, sim, Incoplast, sandbox, Bispharma keys | read keys for kiosk apps |
| `OAUTH2_PROXY_SESSION_STORE_TYPE` | oauth2-proxy | `redis` | keeps the cookie small (see failure modes) |
| `MIGRATION_ENABLED` | migration Lambda | `true` since 2026-09-03 | Firebase → Cognito copy on first login |

## Failure modes & signals

| Symptom | Cause | Fix / where to look |
|---|---|---|
| front4 renders with no data; every `/v1/query` 401 | Cognito `sub` not linked in `identity.users` (2026-09-03: duplicate email across real + sandbox rows broke the self-heal) | link the row; self-heal now targets one row |
| "Couldn't load your workspace data", then a render crash | role has empty `permissions.desktop.line` (2026-08-17) | grant the role its lines; read-api caches identity per token, so restart read-api after role changes |
| Operator login: 401 "No operator account for this identity" | `identity.users.user_name` ≠ the Cognito email | set `user_name` to the email |
| Super-admin writes land in the home tenant | write verifier still expected HS256 (#188, fixed 2026-09-06) | both verifiers now RS256/JWKS |
| All admin UIs: CloudFront 403 "Request blocked" | oauth2-proxy cookie store grew past WAF's 8 KB Cookie limit (2026-09-13) | redis session store (PR #1219); users with the old cookie must clear `*.staging.packiot.app` cookies once |
| Everyone is logged out at once | `app-redis` restarted (sessions are not persisted) | log in again |
| read-api returns 401 with no log line | the resolver maps every DB error to 401 | run the resolver SQL against the DB read-api uses |

## History & decisions

- **ADR-0033**: unified JWT auth on edge-api (Bearer dual-accept, `TenantFence`).
- **ADR-0034**: Cognito replaces Firebase; oauth2-proxy replaces Authentik (2026-08-05);
  operator Cognito-only (2026-09-03); Firebase retired from edge-api (#159).
- **ADR-0027**: read contract, the client never names a tenant (super-admin is the one
  flag-gated exception).
- **ADR-0056**: one app database with schemas; the `identity` schema name (t247).
- Migration `t276`: read-api stops running as a BYPASSRLS superuser.

## Go deeper

- [oauth2-proxy and Cognito](../components/oauth2-proxy-and-cognito.md)
- [edge-api](../components/edge-api.md) · [read-api](../components/read-api.md)
- [Frontends](frontends.md) · [Tenancy and security](../architecture/tenancy-and-security.md)
- Runbook: `docs/runbooks/oauth2-proxy-cognito-migration.md`
