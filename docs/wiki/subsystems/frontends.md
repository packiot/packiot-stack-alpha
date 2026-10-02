---
title: Frontends
layer: 2
owner_area: frontends
last_verified: 2026-09-28
---
# Frontends

> **Layer 2 · Subsystems** — the five browser apps of the new stack: who uses each, which
> API each calls, how each is built and shipped, and where it lives on staging. For
> frontend engineers and anyone debugging "the page is blank".
> Up: [Architecture overview](../architecture/overview.md)

## Purpose

Packiot has three audiences and five single-page apps (SPAs). Plant managers read OEE in
**front4**. Machine operators run production orders and justify downtime in the
**operator** app and scan boxes in the **barcode** app. Packiot's Customer Success (CS)
team onboards and configures clients in **CS Admin** (`csadmin`) and authors per-client
customizations in the **Customization Hub** (`customize`). Every app is a static bundle; all
state and all tenant decisions live in the backends ([edge-api](../components/edge-api.md)
for writes and configuration, [read-api](../components/read-api.md) for tenant-scoped reads,
Superset for BI embeds).

## Boundaries

**Owns:** the SPA code, their build-time configuration (`VITE_*`), the per-app nginx that
serves each bundle and reverse-proxies its APIs same-origin, and client-side resilience
(offline write queues in operator and barcode).

**Does not own:**

- Authentication and tenant resolution — see [Identity](identity.md). A frontend never
  decides which tenant it is; the backend derives it from the credential.
- The APIs themselves — see [Serving & APIs](serving-apis.md).
- The host nginx, CloudFront and WAF in front of the apps — see [Platform](platform.md) and
  [oauth2-proxy and Cognito](../components/oauth2-proxy-and-cognito.md).
- Superset dashboards (served by `bi.staging.packiot.app`, embedded by front4) — see
  [Superset](../components/superset.md).

## Components

| App | Users | Stack | Where it runs (staging) | Layer-3 page |
|---|---|---|---|---|
| **front4** | Client managers, CS | React 17, MUI, Vite 3, Amplify Auth | AWS Amplify app `d3l999ijeqpc2y`, branch `staging` | [front4](../components/front4.md) |
| **operator** (repo `packiot/operator4`) | Machine operators on factory tablets | React 18, MUI, Vite, PWA, Amplify Auth | compose services `operator`, `operator-sbx`, `operator-bispharma` (nginx :80) | [Operator app](../components/operator-app.md) |
| **csadmin** | Packiot CS engineers | React 19, Tailwind v4, Zustand, Amplify Auth | compose service `csadmin` | [CS Admin](../components/csadmin.md) |
| **customize** | Packiot CS engineers | React 19 (a csadmin clone), in-repo | compose service `customize` | [Customization Hub](../components/customize.md) |
| **barcode** (repo `packiot/barcode-scanner-v2`) | Operators at a box-scanning station | React 19, Tailwind v4, Zustand | compose service `barcode-app` (image built by hand) | [Barcode app](../components/barcode-app.md) |

## How it works

Two credential models exist, and which one an app uses decides most of its behaviour:

- **User-token apps** (front4, csadmin, customize) send the signed-in user's Cognito ID
  token as `Authorization: Bearer`. The backend resolves the tenant from the user row
  (`identity.users`), or, for a `cs-admin` group member, honours a `?idEnterprise=` target.
- **Kiosk / factory apps** (operator writes, barcode) never send a user token to the write
  plane. Their container nginx injects the **enterprise api-key** (`x-api-key`) server-side,
  so the browser never holds it and the tenant is whatever that key belongs to. This is why
  each client needs its own operator container (the key is per container).

```text
 browser                       host nginx (EC2, per vhost)          containers on packiot-net
 ───────                       ──────────────────────────          ─────────────────────────
 front4 (Amplify CDN) ─Bearer─▶ api.staging  /api/*  ───────────▶ edge-api :8080
        └────────────Bearer─▶ refdata.staging /v1/* ───────────▶ read-api :9104
        └──guest token iframe▶ bi.staging ───────────────────────▶ superset

 operator  ─(oauth2 cookie)─▶ operator.staging  ─▶ operator nginx ─ /api/*  +x-api-key ─▶ edge-api
                                                               ├── /session (Bearer) ─▶ edge-api
                                                               └── /v1/*   +read key ─▶ read-api
 barcode   ─(oauth2, cs-admin)▶ barcode.staging ─▶ barcode nginx ─/api/* +x-api-key─▶ edge-api
 csadmin   ─(origin-verify only)──▶ csadmin.staging ─▶ csadmin nginx ─/api/* Bearer─▶ edge-api
                                                                   └─/v1/* Bearer─▶ read-api
 customize ─(origin-verify only)──▶ customize.staging ─▶ customize nginx ─/api/* Bearer─▶ edge-api
```

All `*.staging.packiot.app` vhosts sit behind CloudFront + WAF; host nginx 403s any request
that lacks CloudFront's `X-Origin-Verify` header. front4 is the exception: Amplify hosts it,
not the app box.

### Build and deploy paths

| App | Source of truth | Build | Deploy trigger | Staging URL |
|---|---|---|---|---|
| front4 | `packiot/front4` branch `staging` (submodule `./front4`, not built by the stack) | Amplify runs `yarn build:staging` (`.env.staging`) | push to front4 `staging` (Amplify `enableAutoBuild=true`) | `front.staging.packiot.app`, `staging.packiot.com` |
| operator | `packiot/operator4` branch `staging` (submodule `./operator`) | `operator/Dockerfile.staging` inside `docker compose build` | stack `deploy-staging.yml` after a submodule-pointer bump (operator4's `bump-stack-submodule.yml` opens the bump PR) | `operator.staging.packiot.app`, `operator-sbx…`, `operator-bispharma…` |
| csadmin | `packiot/csadmin` branch `staging` (submodule `./csadmin`) | `csadmin/Dockerfile.staging` inside `docker compose build` | stack deploy after a manual submodule-pointer bump (csadmin has no CI and no bump workflow) | `csadmin.staging.packiot.app` |
| customize | this repo, `customize/` | `customize/Dockerfile.staging` inside `docker compose build` | any merge to stack `staging` | `customize.staging.packiot.app` |
| barcode | `packiot/barcode-scanner-v2` branch `staging` | CI publishes `ghcr.io/packiot/barcode-edge:staging`; the staging host cannot pull it, so the image `barcode-app:staging` is built on the host by hand | manual (see [Barcode app](../components/barcode-app.md#operating-it)) | `barcode.staging.packiot.app` |

`deploy-staging.yml` initialises only `edge-api edge-node-red operator csadmin` and then
runs `docker compose -f compose.staging.yml -f compose.superset.yml -p stack build` and
`up -d --remove-orphans`. front4 and barcode are never rebuilt by a stack deploy.

!!! note "`VITE_*` is compile-time"
    Vite bakes every `VITE_*` value into the JavaScript at `vite build`. Changing a compose
    `environment:` value and restarting does nothing for these; they must be passed as
    `build.args` and the image rebuilt (compose.staging.yml does this for operator, csadmin
    and customize). Runtime `environment:` only feeds the nginx templates (api-keys).

## Interfaces

| From | To | Protocol / path | Credential |
|---|---|---|---|
| front4 | edge-api | HTTPS `api.staging.packiot.app/api/*`, `/session/enterprises` | Cognito ID token (Bearer) |
| front4 | read-api | HTTPS `refdata.staging.packiot.app/v1/query`, `/v1/language-packs` | Cognito ID token (Bearer) |
| front4 | Superset | iframe `bi.staging.packiot.app`, token from `POST /api/superset/guest-token` | Superset guest token (RLS `id_enterprise = N`) |
| operator | edge-api | same-origin `/api/*` (writes), `/session*` (bootstrap) | nginx-injected `x-api-key`; Bearer on `/session` |
| operator | read-api | same-origin `/v1/*` | nginx-injected read key from `QUERY_API_KEYS` |
| csadmin | edge-api, read-api | same-origin `/api/*`, `/v1/*` | Cognito ID token (Bearer) + `?idEnterprise=` |
| customize | edge-api | same-origin `/api/*` (no `/v1` proxy) | Cognito ID token (Bearer) + `?idEnterprise=` |
| barcode | edge-api | same-origin `/api/scanned-boxes`, `/api/samples*`, `/api/lines`, `/api/production-orders/current` | nginx-injected `x-api-key` |

The exact endpoint lists are on each layer-3 page and in
[API endpoints](../reference/api-endpoints.md).

## Data it owns

Frontends own no server-side data. Client-side state that matters operationally:

| App | Store | Key | Lifetime |
|---|---|---|---|
| front4 | localStorage | `f4-superadmin-target-enterprise` (super-admin target) | until cleared |
| operator | IndexedDB `operator-write-queue` / store `writes` | offline PO and downtime writes | until replayed or discarded |
| operator | Service worker cache (PWA) | the app shell | until SW update |
| csadmin | localStorage `csadmin.enterprise` | selected tenant | until cleared |
| barcode | IndexedDB outbox keyed by `scan_uuid`; localStorage `packiot.selectedLine` | offline scans; picked line | until drained / cleared |

## Configuration that matters

| Knob | Where | Effect |
|---|---|---|
| `VITE_REFDATA_ENABLED`, `VITE_REFDATA_ANALYTICS` | front4 `.env.staging` | `true` = reads go to read-api and writes use the Bearer; `false` = legacy Hasura/back4 path with `x-api-key` |
| `VITE_AUTH_COGNITO_ENABLED` + pool/client ids | front4 `.env.staging`; build args for csadmin/customize | without them Amplify is never configured, no Bearer is sent and edge-api 401s everything |
| `VITE_PO_WRITE_QUEUE_ENABLED` | operator build arg (`"true"` on staging) | enables the offline durable write queue |
| `EDGE_API_KEY`, `REFDATA_API_KEY` | operator and barcode container env (from `/opt/packiot/.env`) | which tenant the container writes and reads as; empty = fail closed (401) |
| `service_auth` map | `terraform/staging/variables.tf` | per-vhost edge gate: `csadmin` (cs-admin group), `any` (any pool user), `api`, `none-originverify` |

## Failure modes & signals

| Symptom | Likely cause | Where to look |
|---|---|---|
| front4 "Couldn't load your workspace data", no nav | Cognito user not linked in `identity.users` (read-api 401s every `/v1/query`) | [Identity](identity.md#failure-modes-signals) |
| csadmin/customize list is empty, every `/api` 401 | Cognito build args missing, no Bearer sent (fixed 2026-09-20, PR #1338) | [CS Admin](../components/csadmin.md#failure-modes) |
| Operator writes 404 "Equipment not found" for a non-CPACK user | user is on the CPACK operator container; its api-key fences them out | [Operator app](../components/operator-app.md#failure-modes) |
| "My deploy didn't land" | stale `index.html` in the browser, or a PWA service worker | csadmin sends `no-store` on `index.html` since 2026-09-15; hard refresh |
| Every `*.staging` admin UI returns CloudFront 403 "Request blocked" | oversized oauth2 cookie tripping WAF (fixed with the redis session store, 2026-09-13) | [oauth2-proxy and Cognito](../components/oauth2-proxy-and-cognito.md#failure-modes) |
| Superset charts 400 "CSRF session token missing" in front4 | front4 opened from `staging.packiot.com` (third-party cookie to `bi.staging.packiot.app`) | use `front.staging.packiot.app` |

The cross-frontend Playwright suite in `e2e/` (projects `front4`, `operator`, `csadmin`,
`customize` and `sandbox-*`) is the fastest end-to-end signal; see `e2e/TESTING.md`.

## History & decisions

- **ADR-0026** (API consolidation): front4 moved off Hasura and back4 onto read-api + edge-api
  (W1 read cutover shipped 2026-08-07).
- **ADR-0027** (read contract): the client never names a tenant on `/v1`.
- **ADR-0034** (Cognito): Firebase retired on the new stack; operator went Cognito-only on
  2026-09-03, front4's Firebase path retired on staging (#270, 2026-09-03).
- **ADR-0058** (customization): customizations moved out of csadmin into the Customization
  Hub (csadmin #110, 2026-09-25).
- 2026-09-24: `operator-bispharma` added because a Bispharma user on the CPACK operator wrote
  as CPACK and was fenced out.

ADR files are in `docs/adr/`; see the [ADR index](../reference/adr-index.md).

## Go deeper

- [front4](../components/front4.md) · [Operator app](../components/operator-app.md) ·
  [CS Admin](../components/csadmin.md) · [Customization Hub](../components/customize.md) ·
  [Barcode app](../components/barcode-app.md)
- [Identity](identity.md) and [oauth2-proxy and Cognito](../components/oauth2-proxy-and-cognito.md)
- [Onboarding a client](../operations/onboarding-a-client.md) — csadmin in use
