---
title: Customization Hub (customize)
layer: 3
owner_area: frontends
last_verified: 2026-09-28
---
# Customization Hub (customize)

> **Layer 3 · Components** — the internal SPA where CS engineers author per-client
> customizations on an already-onboarded tenant: derive rules, the OEE profile, Node-RED
> flows, and read-only views of integrations and PLC connections. For whoever changes a
> client's data processing without a code change.
> Up: [Frontends](../subsystems/frontends.md)

## Responsibility

Different factories need different processing: a derived counter, a Node-RED function on
the box, a tolerance on counter spikes. ADR-0058 makes these **config-as-data on the tenant
descriptor** (the ADR-0045 `client_descriptors` row). The Customization Hub is the only UI
that edits them. CS Admin sets up the tenant and its PLC connection; the Hub builds on top
of it. Since csadmin #110 / stack #1458 (2026-09-25), csadmin no longer authors any
customization.

## At a glance

| | |
|---|---|
| Language / framework | TypeScript, React 19, Tailwind v4, Zustand, `aws-amplify` 6 (started as a csadmin clone) |
| Repo path | `customize/` in this repo (not a submodule) |
| Container | `customize` (nginx :80), host port `127.0.0.1:8086`, static IP `172.18.0.51` |
| Image | `customize/Dockerfile.staging`, built by every stack deploy |
| URL | `customize.staging.packiot.app` |
| Edge gate | `none-originverify` (origin lock only; own Cognito login) |
| Depends on | edge-api (`/api/*` only; the nginx has no `/v1` proxy) |
| Sibling | CS Admin; links carry `?idEnterprise=` |

## Inputs & outputs

All calls go to edge-api with the user's Bearer and `?idEnterprise=<selected>` (same client
as csadmin):

| Page | Reads | Writes |
|---|---|---|
| Hub (`/app/hub`) | `GET /api/onboarding/descriptor` (counts of rules, integrations, flows; recent rules) | — |
| Derive rules (`/app/customizations`) | descriptor | `POST /api/onboarding/simulate` (dry run against sample tags), `POST /api/onboarding/descriptor` (save), optional regenerate |
| OEE profile (`/app/oee-profile`) | `descriptor.oee_profile` | saves `oee_profile` on the descriptor |
| Integrations (`/app/integrations`) | `descriptor.capabilities.integrations` | read-only |
| Node-RED (`/app/node-red`) | `descriptor.customizations` | saves descriptor flows; live box editor via `POST /api/edge-ssm/webui` then `/api/edge-ssm/webui/<session>/?ticket=…` |
| PLC connections (`/app/plc-connections`) | descriptor PLC blocks, `GET /api/plc-status` | read-only; each item deep-links to the owning csadmin page |
| Enterprises (`/enterprises`) | `GET /api/enterprises` | create/edit exist in the API client (inherited from csadmin) |

## Internal design

- **Routes** (`src/App.tsx`): `/login`, `/enterprises`, `/app/{hub, customizations,
  oee-profile, integrations, node-red, plc-connections}`.
- **Tenant**: `src/stores` persists the selected enterprise per origin; on arrival from
  csadmin, `?idEnterprise=N` selects the tenant and is stripped (csadmin and customize are
  different origins and share no localStorage).
- **Lost-update guard**: csadmin's onboarding save re-reads the latest descriptor and keeps
  `equipment[].derived`, `customizations` and `oee_profile` as the Hub last saved them
  (`withLatestCustomizations`), so the two apps can edit one descriptor safely.
- **Derive rules** (`src/lib/derive-rules.ts`): declarative `expr` rules per equipment,
  simulated by edge-api, which proxies to the decoder's onboard API
  (`ONBOARD_SIMULATE_URL`, default derived from `ONBOARD_GENERATE_URL`).
- **OEE profile**: every knob defaults to "platform default" (unset). Only `spike_margin` is
  consumed today (the decoder's counter-anomaly guard via `oeeprofile.Watcher`, applied on
  its next config refresh). Other knobs are stored for later migration off env lists.
- **Integrations** show connector type, driver, reads/writes, dedup key and the `dsn_ref`
  pointer (`secret://…`); never a credential. Authoring a connector is an engineering change
  (ADR-0019).
- **Node-RED live editor** is the box's own Node-RED UI through edge-api's SSM-backed
  reverse proxy (ADR-0057). For twin/sandbox tenants (id ≥ 2,000,000) edge-api serves it
  read-only and mocks mutating box operations.

## Configuration

Build args (`compose.staging.yml` → `customize/Dockerfile.staging`):

| Variable | Staging | Effect |
|---|---|---|
| `VITE_AUTH_COGNITO_ENABLED` | `true` | Cognito login; without it no Bearer and every call 401s |
| `VITE_COGNITO_USER_POOL_ID`, `VITE_COGNITO_CLIENT_ID` | pool, `front4-amplify` client | |
| `VITE_EDGE_API_URL` | unset → same-origin | compose passes `VITE_API_BASE_URL`, which is not read |
| `VITE_CSADMIN_URL` | unset | sibling link; derived `customize.<env>` → `csadmin.<env>` |

The user must be in the Cognito `cs-admin` group for cross-tenant access (same rules as
[CS Admin](csadmin.md#tenant-targeting)).

## Data & invariants

- Customizations are versioned with the descriptor (`version`, `updated_at`); there is no
  per-rule timestamp, so "recent" means "on the current descriptor".
- No secret values are stored or shown; integration DSNs are `secret://` references and the
  loader's CI lint rejects inline secrets.
- A saved rule does nothing on the box until the edge config is regenerated and deployed.

## Observability

Browser devtools; edge-api logs for `onboarding/*` and `edge-ssm/*`; Playwright projects
`customize`, `sandbox-customize`.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Every `/api` 401 (fixed 2026-09-20, PR #1338) | empty hub | Cognito build args missing | build args in compose |
| Opens on the wrong client | hub shows another tenant | arrived without `?idEnterprise=` | use csadmin's link; tenant hand-off added 2026-09-25 (#110/#1458) |
| Live editor blank on sandbox boxes | Node-RED editor never loads | the dind simulation boxes cannot run Node-RED (nested overlay; 2026-09-16) | use a hybrid `mi-` box; do not retry heavy docker ops on the shared app host |
| Rule saved but no effect | derived metric missing | descriptor saved, config not regenerated / deployed | regenerate and deploy from csadmin's Go-live step |

## Operating it

Merge to stack `staging` (customize is in-repo); the deploy rebuilds it. Recreate alone with
`docker compose -p stack -f compose.staging.yml -f compose.superset.yml up -d --build --no-deps customize`.
DNS/CloudFront for the subdomain: `docs/plans/customize-frontend-infra.md`.

## Tests

No unit tests or test script in `customize/package.json` (`npm run lint`, `npm run build`
only). End-to-end: `npm run test:customize` in `e2e/`.

## Source map

| Path | What's there |
|---|---|
| `customize/src/App.tsx` | routes |
| `customize/src/pages/*.tsx` | hub, derive rules, OEE profile, integrations, Node-RED, PLC connections |
| `customize/src/lib/derive-rules.ts`, `node-red-customizations.ts`, `sibling-apps.ts` | rule model, flows, cross-links |
| `customize/src/api/*.ts` | edge-api clients |
| `customize/Dockerfile.staging`, `customize/nginx.staging.conf.template` | image and proxy |
| `compose.staging.yml` (`customize`) | build args, port |
| `docs/adr/0058-client-customization-capability.md`, `docs/adr/0019-edge-customization-capabilities.md` | design |
