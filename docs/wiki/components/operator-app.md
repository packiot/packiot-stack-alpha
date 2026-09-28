---
title: Operator app (operator4)
layer: 3
owner_area: frontends
last_verified: 2026-09-28
---
# Operator app (operator4)

> **Layer 3 · Components** — the shop-floor tablet app where operators start and change
> production orders and justify downtime: structure, auth, API calls, the offline write
> queue, deployment per tenant, and known failures. For operator developers and on-call.
> Up: [Frontends](../subsystems/frontends.md)

## Responsibility

The operator app is the only place a machine operator touches Packiot. For the line (or
machine) they pick it shows the running production order (PO), production so far, pending
and solved downtime events, and lets them start / create-and-start / replace / change a PO,
set up a PO, justify a stop, add or edit a manual event and split a downtime. It must keep
working on flaky factory Wi-Fi, so writes are durable offline (queued in IndexedDB and
replayed with their original action time).

## At a glance

| | |
|---|---|
| Language / framework | JavaScript, React 18, MUI 5, Vite, `vite-plugin-pwa`, `aws-amplify`, `idb`, i18next |
| Repo | `packiot/operator4` (submodule `./operator`, branch `staging`) |
| Containers (staging) | `operator` (CPACK, ent 3, host port 8083), `operator-sbx` (sandbox 2000003, 8085), `operator-bispharma` (ent 5, 8087). One image, three runtime configs |
| Image | built from `operator/Dockerfile.staging` by `docker compose build`; nginx 1.27-alpine serving `dist/` |
| URLs | `operator.staging.packiot.app`, `operator-sbx.staging.packiot.app`, `operator-bispharma.staging.packiot.app` |
| Edge gate | oauth2-proxy tier `any` (any Cognito pool user) |
| Depends on | edge-api (`/api/*`, `/session*`), read-api (`/v1/*`), Cognito |
| On-prem variant | `operator/Dockerfile.edge` + `nginx.edge.conf.template` (the edge-operator on a factory box) |

## Inputs & outputs

All calls are same-origin; the container nginx proxies them.

| Path (browser) | Proxied to | Credential added by nginx | Used for |
|---|---|---|---|
| `/session`, `/session/switch`, `/session/enterprises` | `edge-api:8080` | none; the SPA sends its Cognito Bearer | bootstrap: entity tree, language, `super_user` |
| `/api/*` | `edge-api:8080` | `x-api-key: ${EDGE_API_KEY}`; `Authorization` is **cleared** | writes |
| `/v1/*` | `refdata-api:9104` (read-api alias) | `x-api-key: ${REFDATA_API_KEY}`; forwards `x-operator-superadmin-token` | reads |

Writes (`src/Services/endpoints.js`): `POST /api/production-orders/{start, create-and-start,
replace, setup, create}`, `POST /api/downtimes/{justify, create-manual-event,
edit-manual-event, split}`. Reads: `/v1/operator-entities`, `/v1/operator-po-list`,
`/v1/operator-po-details`, `/v1/pending-downtime`, `/v1/events-timeline`,
`/v1/downtime-reasons`, `/v1/language-packs`; translations `GET /api/i18n/front4/:lang`.

Because nginx replaces the credential, **the tenant of every write is the tenant of the
container's `EDGE_API_KEY`**, whoever is logged in. The login only decides which lines the
user sees (their role's entity scope).

## Internal design

### Structure

| Path | Role |
|---|---|
| `src/routes.jsx` | `/` (Login), `/home` (tabs: running PO / events), `/home/change` (ChangeJob), `*` |
| `src/Context/AuthContext.jsx` | Cognito SRP sign-in, then `POST /session` with the Bearer; stores entities and language |
| `src/Services/cognito.js` | Amplify configure, `signIn`, fresh ID token on every call, sign-out |
| `src/Services/api.js` | axios instance; attaches a fresh Cognito ID token; super-admin extras |
| `src/Services/endpoints.js` | every read and write |
| `src/Services/durableWrite.js` | offline policy: action time, `expectedState`, `Idempotency-Key`, replay, 409 review |
| `src/Services/writeQueue.js` | IndexedDB store `operator-write-queue` / `writes` |
| `src/Services/reachability.js`, `offlineGuard.js` | online probe (default path `/v1/language-packs`) and offline blocking |
| `src/Context/PendingSyncContext.jsx`, `src/Components/PendingSync` | pending badge and 409 review tray |
| `src/Components/*` | dialogs: `JustifyEvent`, `SplitDowntime`, `AddManualEvent`, `EditEvent`, `SelectPo`, `EquipmentSetup`, … |
| `pwa.config.js` | service worker config (backend paths excluded from the SPA fallback) |

### Login and session

1. On a fresh browser the host nginx gate sends the user to the Cognito hosted UI.
2. The SPA's own form then signs in with Amplify SRP (`front4-amplify` client). The old
   staging auto-login (`packiot/packiot`) is disabled in `Dockerfile.staging`
   (`VITE_STAGING_AUTO_LOGIN="false"`).
3. `POST /session` with `Authorization: Bearer <id token>`: edge-api verifies it, requires a
   verified email, and finds the operator by `identity.users.user_name = <email>`. The body
   returns `entities`, `user`, `language`, `user_permissions` and `super_user`; no token is
   minted.
4. Entity scope comes from `v_entities_per_user_role_operator` for the user's role.

### Super-admin switch

When `/session` returns `super_user: true`, the header shows an enterprise picker
(`GET /session/enterprises`). Switching calls `POST /session/switch` and then tags reads and
writes with `?idEnterprise=<target>` plus `x-operator-superadmin-token`. edge-api and read-api
re-verify it on every request; see
[Identity](../subsystems/identity.md#super-admin-operator-and-front4).

### Offline durable writes (`VITE_PO_WRITE_QUEUE_ENABLED=true` on staging)

```text
 operator action ─▶ durableWrite(request)
                     │ freeze actionTime, assumedRunningPoId, Idempotency-Key = entry id
                     ├─ online and 2xx ───────────────────────────▶ done
                     └─ offline / network drop ─▶ IndexedDB `writes` (status pending, seq)
 reconnect ─▶ replay in seq order ─▶ edge-api staleness gate
                     ├─ 2xx or duplicate key ─▶ remove
                     └─ structured 409 ─▶ status review ─▶ tray: apply as correction / discard
```

The staleness gate is server-side (`PO_STALENESS_GATE_ENABLED`, enterprises `3,4` on
staging). With the flag off, `durableWrite` is a pass-through and offline writes are
blocked with a toast instead.

## Configuration

Build args (`compose.staging.yml`; baked at `yarn build`):

| Variable | Staging | Effect |
|---|---|---|
| `VITE_API_URL` | `""` (set in the Dockerfile) | same-origin calls |
| `VITE_PO_WRITE_QUEUE_ENABLED` | `true` | offline queue on |
| `VITE_COGNITO_USER_POOL_ID`, `VITE_COGNITO_USER_POOL_CLIENT_ID` | pool, `front4-amplify` client | Cognito login; empty → sign-in throws |
| `VITE_STAGING_AUTO_LOGIN` (+ `_USER`, `_PASS`) | `false` | retired dev convenience |
| `VITE_EQUIPMENT_SETUP_GROUPS` | unset → `PACK,C-PACK` | which groups see the equipment-setup dialog |
| `VITE_REACHABILITY_PROBE_*` | defaults | online probe path, interval, timeout |

Runtime env (container; substituted into the nginx template):

| Variable | `operator` | `operator-sbx` | `operator-bispharma` |
|---|---|---|---|
| `EDGE_API_KEY` | `${OPERATOR_EDGE_API_KEY}` (ent 3 key) | `${OPERATOR_SBX_EDGE_API_KEY}` (2000003) | `${OPERATOR_BISPHARMA_EDGE_API_KEY}` (ent 5) |
| `REFDATA_API_KEY` | CPACK read key | sandbox read key | Bispharma read key |

Values live in `/opt/packiot/.env` on the app host. An empty `EDGE_API_KEY` fails closed
(edge-api 401). Read keys map to tenants in read-api's `QUERY_API_KEYS`.

## Data & invariants

- The browser never holds an enterprise api-key; the Bearer is stripped from `/api/*`.
- One container = one tenant for writes. Adding a client to the operator means adding a
  container, a vhost and two keys (see [Onboarding a client](../operations/onboarding-a-client.md#d-give-people-access)).
- Queued writes carry the operator's action time, not the send time, and are replayed in
  order; the `Idempotency-Key` makes a double send a no-op.

## Observability

- Grafana board `packiot-operator` (operator actions → `user_logs`).
- `docker logs operator` (nginx access log): no requests at all means the break is
  client-side or at the host gate.
- edge-api audit rows (`res.locals.logData` → `user_logs`) for every write.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Wrong-tenant container (2026-09-24) | Bispharma user sees "Sem eventos"; writes 404 "Equipment not found" | user on the CPACK `operator`, whose key fences to ent 3 | use `operator-bispharma`; one container per tenant |
| No operator account | 401 "No operator account for this identity" | `identity.users.user_name` ≠ Cognito email | set `user_name` to the email |
| Blue screen (2026-08) | app loads past the gate, blank blue | auto-login fell back to `packiot/packiot`, `/session` answered 200 `wrong-password` | auto-login disabled; log in with a Cognito user |
| Super-admin writes land at home (#188, fixed 2026-09-06) | reads show the target, writes go home | write verifier expected HS256 | RS256/JWKS verifier in edge-api |
| Downtime always 0 (2026-09-25) | PO shows no downtime | replicator wrote `forced_creation_system=true` on PLC events; view sums `false` only | fixed in the writer (#1455) + backfill |
| PO list shows "PO 36432" and polls 19k rows | wrong labels, slow | stub view `v_operator_po_list_setup_4` | ported legacy view (#1456) |
| ChangeJob empty after reload | no topics | missing localStorage topic fallback | operator4 #129 |
| Fixed but still broken | old UI persists | PWA service worker cache | hard refresh / unregister SW; Playwright needs `serviceWorkers: 'block'` |
| operator-sbx 403 (2026-09-20) | vhost missing on the box | host nginx not re-rendered | add vhost, reload nginx |

## Operating it

- **Deploy**: merge to operator4 `staging`. Its `bump-stack-submodule.yml` opens a stack PR
  bumping `./operator` (auto-merge after "Validate compose files"); the merge triggers
  `deploy-staging.yml`, which rebuilds the image for all three containers. If the bump
  workflow fails (its `PARENT_REPO_TOKEN` was invalid from about 2026-09-14 to 2026-09-25),
  bump the gitlink by hand in a stack PR.
- **Recreate one container** after an `.env` change:
  `docker compose -p stack -f compose.staging.yml up -d --no-deps operator-bispharma`
  (recreate, not `docker restart`, so the new env is read).
- **Add a tenant**: new service block (copy `operator-bispharma`), new host port, new vhost
  in `terraform/staging/user_data/nginx_setup.sh`, `OPERATOR_<X>_EDGE_API_KEY` in
  `/opt/packiot/.env` (copied from `enterprises.api_key`, never printed), a read key in
  `QUERY_API_KEYS`.
- Production (`compose.production.yml`) has no operator SPA container; only
  `operator-gateway`.

## Tests

- `yarn test` (vitest run): `src/test/operator-deployed-contract.test.js`, hooks, PWA config,
  i18n, queue/replay logic. CI: `.github/workflows/build.yml`, `pr-validation.yml`.
- Stack Playwright projects `operator`, `sandbox-operator` (`e2e/tests/operator.spec.ts`);
  they log in through the hosted UI.

## Source map

| Path | What's there |
|---|---|
| `operator/Dockerfile.staging`, `operator/nginx.staging.conf.template` | cloud image and proxy (key injection) |
| `operator/Dockerfile.edge`, `operator/nginx.edge.conf.template` | on-prem edge-operator image |
| `operator/src/Services/*` | auth, API, offline queue |
| `operator/src/Context/AuthContext.jsx` | login + `/session` |
| `operator/.github/workflows/bump-stack-submodule.yml` | stack pointer bump |
| `compose.staging.yml` (`operator`, `operator-sbx`, `operator-bispharma`) | containers, build args, keys |
| `edge-api/src/usecases/session/login/` | `/session` endpoints |
| `edge-api/src/data/DAO/session/session-dao.ts` | operator lookup SQL |
