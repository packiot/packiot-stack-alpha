---
title: front4 (product app)
layer: 3
owner_area: frontends
last_verified: 2026-09-28
---
# front4 (product app)

> **Layer 3 · Components** — the customer-facing OEE web app: its pages, how it
> authenticates and fetches data, how it is built and hosted, and what breaks. For front4
> developers and for whoever is asked "why is the dashboard empty".
> Up: [Frontends](../subsystems/frontends.md)

## Responsibility

front4 shows a client's managers what their factory is doing: live line status (Mission
Control), OEE and its three factors, downtimes, production orders, targets, and embedded
Superset reports. It also lets them edit a few things (justify or split downtimes, change or
delete production orders, set production targets, manage users and roles). It owns no data;
every read goes to [read-api](read-api.md) and every write to [edge-api](edge-api.md).

## At a glance

| | |
|---|---|
| Language / framework | JavaScript + some TypeScript, React 17, MUI 4 and 5, Vite 3, `aws-amplify` 6, axios |
| Repo | `packiot/front4` (submodule `./front4`; the stack pins it but **does not build it**) |
| Integration branch | `staging` (the `./front4` checkout in the stack may lag; compare with `origin/staging`) |
| Hosting | AWS Amplify app `d3l999ijeqpc2y` (us-east-1) |
| Branch → domain | `staging` → `front.staging.packiot.app` and `staging.packiot.com` (+`www`); `production` → `front.prod.packiot.app`; `master` → `go.packiot.com` (legacy, frozen); `development` → `dev.packiot.com` |
| Auto-build | `staging` and `production`: on; `master`, `development`: off |
| Build command | `yarn build:staging` → `vite build --mode staging` → `build/` (not `dist/`) |
| Depends on | read-api (`refdata.staging.packiot.app`), edge-api (`api.staging.packiot.app`), Superset (`bi.staging.packiot.app`), Cognito |
| Depended on by | client users, CS demos |

## Inputs & outputs

**Reads (read-api, `REFDATA_ENABLED`):** `POST /v1/query` with a dataset name, and
`/v1/language-packs`. Bootstrap datasets (`src/Context/VariablesContext.jsx`):
`entities-per-user-role`, `enterprise-config`, `user-roles`, `users`,
`menu-per-user-role`, `shifts`. Page datasets include `mission-control-timeline`,
`live-equipment-*`, `overview-events`, `overview-production-chart-base`,
`production-orders-by-equipment`, `oee-targets-by-equipment`,
`production-targets-by-equipment`, `scrap-targets-by-equipment`, `equipment-info`,
`site-by-equipment`.

**Writes (edge-api, `src/services/edgeApi.js`):**

| Area | Endpoints |
|---|---|
| Downtimes | `POST /api/downtimes/justify`, `/split`, `/split-manual-downtime`, `/edit-manual-event` |
| Production orders | `POST /api/production-orders/change-status`, `/change-time`, `/delete`, `/replace` |
| Targets | `POST /api/production-targets`, `/api/production-targets/scrap`, `PUT /api/production-targets/custom`, `POST …/custom/delete` |
| Users and roles | `GET /api/users`, `/api/user-roles`, `/api/pages`; `POST /api/users/{create,edit,delete}`, `/api/user-roles/{create,edit,delete}` |
| BI | `POST /api/superset/guest-token?lang=…`; `POST /api/admin/integrations/powerbi/embed-token` (legacy PowerBI page) |
| Super-admin | `GET /session/enterprises` |

Every write carries `?idEnterprise=` in the URL, but edge-api ignores it for a normal user
and uses the tenant resolved from the Bearer token.

## Internal design

### Structure

| Path | Role |
|---|---|
| `src/routes.jsx` | route table (lazy pages) |
| `src/pages/*` | `Home`, `_MissionControl`, `Downtimes`, `OEE`, `ProductionOrders`, `TotalProductionUNS`, `SinglePeriod`, `ScrapPeriod`, `MachineSpeed`, `ProductionFlow`, `DashboardRoute` (Overview v1–v6), `SupersetReport`, `ReportsPowerBi`, `Settings/*`, `Login`, `ForgotPassword`, `ResetPassword` |
| `src/Context/VariablesContext.jsx` | bootstrap: fans out the six refdata datasets and rebuilds the shape the app used to get from Hasura |
| `src/Context/AuthContext.jsx`, `src/cognito.js` | Amplify sign-in, session, sign-out |
| `src/services/authToken.js` | the single "which token do I attach" provider (Cognito ID token; Firebase fallback only when Cognito is off) |
| `src/services/refdata.js` | read transport, 401 refresh-and-retry, `REFDATA_ENABLED` / `REFDATA_ANALYTICS_ENABLED` flags |
| `src/services/edgeApi.js` | write transport: Bearer or `x-api-key`, super-admin escalation, one 401 retry |
| `src/services/enterpriseSwitch.js` | super-admin target in localStorage `f4-superadmin-target-enterprise` |
| `src/i18n/` | translations; bundle `GET /api/i18n/front4/:lang` loaded after the session token exists |
| `src/lib/` | OEE math helpers, dashboard definitions, formatting |

### Main routes

`/login`, `/forgot-password`, `/reset-password/*`, `/public-report/:dataset/:reportId`
(anonymous), then under the authenticated layout: `/home`, `/mission-control` (also
`/MissionControl`, `/NewMissionControl`), `/downtimes`, `/OEE`, `/production-orders`,
`/total-production`, `/single-period`, `/scrap-period`, `/machine-speed`,
`/production-flow`, `/overview/v{1,3,4,5,6}/:lineId`, `/overview/d/:lineId/:dashboardId`,
`/report`, `/reports`, `/report/:dataset/:reportId`; and `/settings/{targets,
users-and-permissions, production-orders, downtime-reasons}`. The menu shown is filtered by
the `menu-per-user-role` dataset, which is built from `identity.user_roles.permissions`
and the `pages` catalogue.

### Auth flow

1. The Login page calls Amplify `signIn` against the `front4-amplify` client
   (`VITE_COGNITO_USER_POOL_ID`, `VITE_COGNITO_USER_POOL_CLIENT_ID`).
2. `getAuthToken()` returns the Cognito **ID token** (it carries `aud` and `email`; the
   access token has neither). Amplify refreshes it from the 30-day refresh token.
3. Every refdata and edge-api call sends `Authorization: Bearer <id token>`. read-api and
   edge-api resolve the tenant from `identity.users.id_user_cognito`.
4. On staging Firebase is retired (#270): `auth` is `null` when Cognito is enabled and the
   app makes no Firebase calls.

### Super-admin switcher

For a super-admin (see [Identity](../subsystems/identity.md#super-admin-operator-and-front4))
the header shows an enterprise picker fed by `GET /session/enterprises`. Picking a tenant
stores it in localStorage; from then on refdata and edge-api calls add `?idEnterprise=<id>`
and `x-operator-superadmin-token: <id token>`. Non-super-admins get 403 on the list and the
header is ignored by the servers.

### Superset

See [Superset](superset.md) for the server side. `SupersetReport` asks edge-api
`POST /api/superset/guest-token?lang=<locale>` for a guest token scoped to the caller's
tenant and embeds `VITE_SUPERSET_URL` with the dashboard
`VITE_SUPERSET_DASHBOARD_UUID` (edge-api returns the pt-BR variant uuid for Portuguese).

## Configuration

Build-time only (`.env.staging`, read by Amplify's `yarn build:staging`):

| Variable | Staging value | Effect |
|---|---|---|
| `VITE_API_URL` | `https://api.staging.packiot.app` | legacy `api` client base; unmigrated legacy routes 404 here on purpose |
| `VITE_EDGE_API` | `https://api.staging.packiot.app` | write plane base |
| `VITE_REFDATA_API_URL` | `https://refdata.staging.packiot.app` | read plane base |
| `VITE_REFDATA_ENABLED` | `true` | reads via read-api; writes with Bearer (else Hasura + `x-api-key`) |
| `VITE_REFDATA_ANALYTICS` | `true` | analytics pages read from read-api |
| `VITE_AUTH_COGNITO_ENABLED` | `true` | Cognito login; Firebase off |
| `VITE_COGNITO_USER_POOL_ID`, `VITE_COGNITO_USER_POOL_CLIENT_ID` | pool `us-east-1_0T9t1sTwt`, `front4-amplify` client | public ids |
| `VITE_COGNITO_LINK_ENABLED` | `false` | client-side link call off; linking is server-side self-heal |
| `VITE_SUPERSET_URL`, `VITE_SUPERSET_DASHBOARD_UUID` | `https://bi.staging.packiot.app`, embed uuid | BI embed |
| `VITE_POSTHOG_*` | unset | analytics wrapper is a no-op when the key is unset |

!!! warning "Production build points at legacy"
    `.env.production` sets `VITE_API_URL=https://api4.packiot.com/` and
    `VITE_EDGE_API=https://edge.api4.packiot.com` (legacy platform). What
    `front.prod.packiot.app` serves end-to-end was not re-verified for this page.

## Data & invariants

- The browser never holds an enterprise api-key on the Bearer path; `enterprise-config`
  deliberately omits `api_key`.
- The client never names its tenant; `?idEnterprise=` only matters for a verified
  super-admin.
- The JWT is kept in memory (`services/sessionToken.js`), not in localStorage.

## Observability

- Browser devtools: every `/v1/query` should be 200. A wall of 401s means the user is not
  linked (see failure modes).
- The CloudFront/host logs for `refdata.staging.packiot.app` and `api.staging.packiot.app`
  (front4 itself is on Amplify; Amplify Console → front4 → staging shows build jobs).
- PostHog session replay when `VITE_POSTHOG_KEY` is set (not set on staging).

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Unlinked Cognito user (2026-09-03) | "laggy and buggy", zero data, 401 on every `/v1/query` | `identity.users.id_user_cognito` not set; self-heal hit two rows with the same email (real + sandbox) and violated the unique index | link the row; self-heal now updates the earliest row only (read-api #1087, edge-api #245) |
| Workspace toast then crash (2026-08-17) | "Couldn't load your workspace data", then `Cannot read properties of undefined (reading 'find')` | CORS allowlist missed the new host; role had empty `permissions.desktop.line` | CORS `map` allowlist in the refdata vhost; `?? []` guards (#253); grant the role its lines |
| Blank authenticated shell (2026-08-07, prod) | white page, clean console | `PageModel` rendered only when Firebase `currentUser` was set | also accept a valid Cognito token (#227) |
| CORS preflight fails | every refdata call `net::ERR_FAILED` | `x-packiot-agent` / `x-user` not in `Access-Control-Allow-Headers`, or the origin not in the allowlist | refdata vhost in `nginx_setup.sh` |
| Settings "Unauthorized" sporadically (#19) | first request after load 401s | request fired before auth hydration | loading gate + one 401 refresh-and-retry in `edgeApi.js` |
| Superset charts 400 "CSRF session token missing" | only on `staging.packiot.com` | Superset cookie is third-party there | use `front.staging.packiot.app` (same site as `bi.staging`) |
| Deep link 404 on Amplify | `/home` returns 404 | missing SPA rewrite | Amplify custom rule rewrites non-asset paths to `/index.html` (200) |
| i18n 401 at boot | English defaults | bundle fetched before the token existed | fetch after `hydrateSessionToken()`, skip when no token (#269, #271) |
| Mission Control layout broken below 1920 px | overlapping cards | theme breakpoints `lg=1440`/`xl=1920` + fixed widths | fluid grid, `minWidth: 0` (#285) |

## Operating it

- **Deploy staging**: merge to front4 `staging`; Amplify builds and publishes both domains.
  The repo's `staging.yml` workflow (FTP upload) is legacy.
- **Deploy `go.packiot.com` (legacy master)** without burning GitHub Actions minutes:
  `aws amplify start-job --app-id d3l999ijeqpc2y --branch-name master --job-type RELEASE`.
- **Test a local build against real staging APIs**: `yarn build:staging`, then serve
  `build/` in Playwright with `page.route('https://front.staging.packiot.app/**', …)`.
  `localhost` fails CORS.
- **Rollback of the read cutover**: set `VITE_REFDATA_ENABLED=false` for the branch and
  rebuild (falls back to Hasura + `x-api-key`; only meaningful where Hasura still exists).

## Tests

- `yarn test` (vitest; `src/**/*.spec.jsx`, MSW handlers in `src/mocks/`), `yarn typecheck`.
- CI: `.github/workflows/ci.yml` runs typecheck, staging build and vitest on PRs to
  `staging` and `production`.
- Cypress (`cypress/`) legacy suite; the maintained end-to-end tests are the stack's
  Playwright projects `front4` and `sandbox-front4` (`e2e/tests/front4.spec.ts`).

## Source map

| Path (front4 repo) | What's there |
|---|---|
| `.env.staging`, `.env.production`, `.env.example` | build-time config |
| `src/routes.jsx` | routes |
| `src/cognito.js`, `src/Context/AuthContext.jsx`, `src/services/authToken.js` | auth |
| `src/services/refdata.js`, `src/services/edgeApi.js`, `src/services/enterpriseSwitch.js` | transports, super-admin |
| `src/Context/VariablesContext.jsx` | bootstrap datasets |
| `src/pages/SupersetReport/index.jsx` | Superset embed |
| `.github/workflows/ci.yml` | CI |
| stack `terraform/staging/user_data/nginx_setup.sh` (refdata vhost) | CORS allowlist for front4 origins |
