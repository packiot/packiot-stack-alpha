---
title: CS Admin (csadmin)
layer: 3
owner_area: frontends
last_verified: 2026-09-28
---
# CS Admin (csadmin)

> **Layer 3 · Components** — the internal console Packiot's Customer Success team uses to
> create and configure client tenants: pages, auth and tenant targeting, API calls, build
> and deploy, and known failures. For csadmin developers and CS engineers who need to know
> what a button really does.
> Up: [Frontends](../subsystems/frontends.md)

## Responsibility

csadmin is the control plane UI for tenant setup. A CS engineer uses it to build the
factory hierarchy (enterprise → site → area → lines, machines, sectors), shifts, teams,
targets and downtime reasons; to run the onboarding wizard that enrols the edge box,
generates and deploys the edge config and cuts the tenant over; to operate the box (Box
Ops); and to manage users, roles, login accounts and translations. It **does not** author
customizations (derive rules, Node-RED flows, OEE profile): since 2026-09-25 (csadmin #110)
those live only in the [Customization Hub](customize.md). Every action is an
[edge-api](edge-api.md) call on the selected tenant.

## At a glance

| | |
|---|---|
| Language / framework | TypeScript, React 19, Tailwind v4, shadcn/Radix, react-hook-form + Zod, Zustand, `aws-amplify` 6, axios, sonner |
| Repo | `packiot/csadmin` (submodule `./csadmin`, branch `staging`) |
| Container | `csadmin` (nginx :80), host port `127.0.0.1:8084`, static IP `172.18.0.40` |
| Image | built by `docker compose build` from `csadmin/Dockerfile.staging` |
| URL | staging `csadmin.staging.packiot.app`; the new-stack production compose also runs `csadmin` |
| Edge gate | `none-originverify`: CloudFront origin lock only, no oauth2 gate; the app has its own Cognito login |
| Depends on | edge-api (`/api/*`), read-api (`/v1/*`), Cognito |
| Sibling | Customization Hub (`customize.<env>`), linked with `?idEnterprise=` |

## Inputs & outputs

The SPA calls same-origin paths; the container nginx proxies them with the user's Bearer
**unchanged** (no key injection):

| Path | Upstream | Notes |
|---|---|---|
| `/api/*` | `edge-api:8080` | 120 s read timeout |
| `/api/edge-ssm/session/stream` | `edge-api:8080` | WebSocket upgrade, 3600 s (Box Ops live session) |
| `/v1/*` | `refdata-api:9104` (read-api) | reads |

Main edge-api groups used (`csadmin/src/api/*.ts`): `enterprises`, `sites`, `areas`,
`equipments`, `lines`, `shifts` / `shift-hours`, `teams`, `production-targets`,
`downtime-reasons`, `packml-register`, `plc-status`, `onboarding/*` (descriptor, generate,
apply-register, validate, capture/*, readiness, cutover, reset, apply-line-meters,
onprem-offline, operator-edge, barcode-edge, mark-deployed, artifacts, simulate),
`edge-ssm/*` (activation, status, deploy-bundle, deploy-onprem, health, logs, restart,
session, webui, …), `edge-bundle/*`, `promote/{plan,bundle,apply}`, `teardown/*`, `users`,
`user-roles`, `cognito-users`, `i18n/*`, `language-packs`. See
[API endpoints](../reference/api-endpoints.md).

## Internal design

### Structure

| Path | Role |
|---|---|
| `src/App.tsx` | routes: `/login`, `/enterprises`, `/enterprises/new`, `/enterprises/:id/edit`, `/app/*` |
| `src/components/app-shell.tsx` | nav; redirects to `/enterprises` when no tenant is selected |
| `src/stores/enterprise-store.ts` | selected tenant, persisted in localStorage `csadmin.enterprise` |
| `src/hooks/use-enterprise-from-url.ts` | selects the tenant named by `?idEnterprise=` on arrival, then strips it |
| `src/lib/api-client.ts` | axios: attach Bearer; append `?idEnterprise=<selected>` to every call except `/api/enterprises*` |
| `src/lib/cognito.ts`, `src/contexts/auth-context.tsx`, `src/lib/auth-token.ts` | Amplify sign-in and token (Firebase path is compiled in but off) |
| `src/schemas/index.ts` | Zod schemas that gate every Save button |
| `src/lib/onboarding.ts` | wizard steps, status ranks, step gating |
| `src/pages/onboarding/*` | the eight wizard steps |
| `src/lib/shift-time.ts`, `week-fields.ts` | clock time ↔ seconds-from-week-start conversion |

### Navigation (`/app/…`)

| Group | Pages |
|---|---|
| Onboarding | `onboarding` (wizard, `?step=`) |
| Factory | `site`, `area`, `machines`, `sectors`, `lines`, `shift`, `team`, `production-targets`, `downtime-reasons` |
| Edge & PLC | `edge` (edge config and bundle runs), `box` (Box Ops over SSM), `packml-register`, `sensors`, `plc-status` |
| Access | `users` (app users), `roles`, `cognito-users` ("Login Users") |
| Other | `translations`, Customization Hub ↗ (external), `remove-client` (teardown) |

### Tenant targeting

csadmin is cross-tenant. The Bearer token of a `cs-admin` group member plus
`?idEnterprise=<selected>` makes edge-api set `callerEnterpriseId` to the target
(`authMethod = 'bearer-cs'`); every write is still fenced to that target. A signed-in user
**not** in `cs-admin` falls back to their own tenant: they need an `identity.users` row, or
`GET /api/enterprises` 401s.

### Onboarding wizard

Eight steps (`ONBOARDING_STEPS`): **Set up the client box**, **Review the plant**,
**Connect the PLCs**, **Set up shifts**, **Go live (dry run)**, **Confirm counts are real**,
**Flip it on**, **Promote to production**. The lifecycle status on the descriptor is
`draft → generated → deployed → captured → validated → cutover`. The step procedure is in
[Onboarding a client](../operations/onboarding-a-client.md).

## Configuration

Build args (`compose.staging.yml` → `Dockerfile.staging`):

| Variable | Default in Dockerfile | Staging | Effect |
|---|---|---|---|
| `VITE_EDGE_API_URL` | `""` | not passed (compose passes `VITE_API_BASE_URL`, which the Dockerfile ignores) | `""` = same-origin |
| `VITE_AUTH_COGNITO_ENABLED` | `true` | `true` | Cognito login; without it no Bearer is sent |
| `VITE_COGNITO_USER_POOL_ID` | `us-east-1_0T9t1sTwt` | same | |
| `VITE_COGNITO_CLIENT_ID` | `front4-amplify` client | same | must match edge-api `COGNITO_CLIENT_ID` (`aud` check) |
| `VITE_FIREBASE_*` | `""` | unset | legacy path, unused |
| `VITE_CUSTOMIZE_URL` | unset | unset | sibling link; derived `csadmin.<env>` → `customize.<env>` |
| `VITE_PROMOTE_APPLY_ENABLED` | unset | unset | the "Promote to production" apply button stays disabled |

Backend flags csadmin depends on (edge-api): `EDGE_API_ONBOARDING_ENABLED=true` (else the
wizard shows a disabled state), `EDGE_API_COGNITO_AUTH_ENABLED=true`,
`COGNITO_CS_ADMIN_GROUP=cs-admin`, `ONBOARD_GENERATE_URL`
(`http://sparkplug-decoder:9105/v1/onboard/generate`), `ONBOARD_API_KEY`.

## Data & invariants

- csadmin stores nothing server-side itself; it is a thin client over edge-api.
- The `cs-admin` claim comes from the signature-verified token; the browser cannot forge it.
- Enterprise-level routes are never auto-scoped (the enterprise is the object itself).
- `index.html` is served `Cache-Control: no-store, must-revalidate`; hashed assets are
  `immutable` for 30 days.
- DTO fields are whitelisted by edge-api's `ValidationPipe` (`whitelist: true`); a field
  without a class-validator decorator is silently dropped, not rejected.

## Observability

- Browser devtools / the sonner toast (every non-401 API error is toasted unless the call
  sets `skipErrorToast`).
- edge-api logs and `user_logs` audit rows (each controller sets `res.locals.logData`;
  CS cross-tenant writes record the acting CS identity).
- The Playwright projects `csadmin` and `sandbox-csadmin`.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| No Bearer (fixed 2026-09-20, stack PR #1338) | enterprises list empty, every `/api` 401 | Cognito build args missing, Amplify never configured | build args in compose (now also Dockerfile defaults) |
| Non-staff user 401 on `/api/enterprises` | cannot pick a tenant | user not in `cs-admin` and has no `identity.users` row | add to `cs-admin`, or create the row |
| New code not visible (2026-09-15) | old UI after a deploy | browser reused a stale `index.html` | `no-store` on `index.html` (csadmin #105); hard refresh once |
| Line create 500 | every new line fails | `overview_version` (jsonb) sent as a JS array → `text[]` | send `JSON.stringify([{version}])` (csadmin #62) |
| Old equipment un-editable | Save blocked "Select an overview version" | migration left structural fields NULL | edit uses a schema without the structural refine |
| Week fields corrupted | shift windows shift by days | form sent `weekday` instead of raw seconds | raw-seconds schema + round-trip guard |
| Mission Control grey for new equipment | NULL thresholds | form defaulted 40/35 (inverted) | defaults 30/85 (csadmin #106) + backfill |
| Customization lost on save (2026-09-25) | derive rules vanish after an onboarding save | onboarding save overwrote `equipment[].derived` / `customizations` | re-read the latest descriptor before saving (`withLatestCustomizations`) |
| Wizard "disabled" | wizard shows a disabled panel | `EDGE_API_ONBOARDING_ENABLED` false | enable on edge-api |

## Operating it

- **Deploy**: merge to csadmin `staging` (no CI, no bump workflow), then in the stack:
  `git update-index --cacheinfo 160000,<sha>,csadmin`, open a PR to `staging`, wait for
  "Validate compose files", merge. `deploy-staging.yml` rebuilds the image.
- **Recreate only csadmin**: `docker compose -p stack -f compose.staging.yml -f compose.superset.yml up -d --build --no-deps csadmin`
  (from the runner work directory on the app host).
- **Unsafe from csadmin**: Remove client (teardown), Box Ops restart/deregister and deploy on
  a live client box, Reset onboarding. Rehearse on the sandbox tenant (2000003) first.

## Tests

- `npm run test:run` (vitest; `src/**/*.spec.ts(x)` including `i18n.spec.ts`), `npm run lint`,
  `npm run build` (`tsc -b && vite build`).
- Stack Playwright: `npm run test:csadmin` in `e2e/`; mutating journeys run against the
  sandbox and `--heal` restores it.

## Source map

| Path | What's there |
|---|---|
| `csadmin/Dockerfile.staging`, `csadmin/nginx.staging.conf.template` | image, same-origin proxy |
| `csadmin/src/App.tsx`, `src/components/app-shell.tsx` | routes, nav |
| `csadmin/src/lib/api-client.ts` | Bearer + tenant targeting |
| `csadmin/src/api/*.ts` | one client module per edge-api resource |
| `csadmin/src/schemas/index.ts` | form validation |
| `csadmin/src/pages/onboarding/*`, `src/lib/onboarding.ts` | wizard |
| `csadmin/docs/API-CONTRACT.md`, `ARCHITECTURE.md` | in-repo design notes |
| `compose.staging.yml` (`csadmin`) | build args, ports |
| `edge-api/src/middleware/auth.middleware.ts` | `bearer-cs` escalation |
