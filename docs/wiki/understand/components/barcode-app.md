---
title: Barcode app (barcode-scanner-v2)
layer: 3
owner_area: frontends
last_verified: 2026-09-28
---
# Barcode app (barcode-scanner-v2)

> **Layer 3 · Components** — the box-scanning and label-printing station app: branch model,
> auth, the offline outbox, samples, the line drawer, how it is built and deployed, and what
> has broken. For barcode developers and whoever deploys it.
> Up: [Frontends](../subsystems/frontends.md)

## Responsibility

At the end of a line an operator scans (or types) the barcode of each finished box and the
app prints a thermal label with a **gapless, server-allocated label number** for the running
production order (PO). It also issues **sample labels**, which are counted separately from
production. It must keep scanning and printing through an internet outage, so every scan
goes to a durable IndexedDB outbox first. The server authority is [edge-api](edge-api.md)
(`/api/scanned-boxes`, `/api/samples`).

## At a glance

| | |
|---|---|
| Language / framework | TypeScript, React 19, Vite, Tailwind v4, shadcn/ui, Zustand, `react-barcode` |
| Repo | `packiot/barcode-scanner-v2` (separate repo, not a stack submodule) |
| Integration branch | **`staging`** (created 2026-09-28; default branch is still `main`) |
| Images | CI publishes `ghcr.io/packiot/barcode-edge:staging` and `:staging-<sha>` (from `staging`), `:main` (from `main`); linux/amd64 + arm64 |
| Cloud instance (staging) | compose service `barcode-app`, image **`barcode-app:staging` built by hand on the app host**, host port `127.0.0.1:8092`, static IP `172.18.0.50` |
| URL | `barcode.staging.packiot.app` (oauth2 tier `csadmin`: staff-only demo/test) |
| Tenant on staging | the sandbox twin 2000003 (its nginx injects the sandbox api-key) |
| On-prem | `barcode-edge` service rendered into `compose.onprem-edge.yml` when the tenant's descriptor has `barcode_edge=true` |
| Live version (2026-09-28) | `barcode-scanner-v2@a5270e7` (PR #8); rollback tag `barcode-app:staging-20260928-3eb4f0e` |

## Inputs & outputs

Same-origin; the container nginx (`nginx.edge.conf.template`) proxies `/api/` to
`${EDGE_API_UPSTREAM}` adding `x-api-key: ${EDGE_API_KEY}`, and `/v1/` to
`${REFDATA_UPSTREAM}` with `${REFDATA_API_KEY}` (unused by the current build).

| Call | Purpose |
|---|---|
| `GET /api/lines` | line drawer (flat tp=3 rows, grouped by site/area in `src/lib/group-lines.ts`) |
| `GET /api/production-orders/current?idEquipment=<line>` | running PO for the picked line (includes `nm_product`, edge-api #271) |
| `POST /api/scanned-boxes` | record a scan; body `RecordScanDto` (camelCase: `scanUuid`, `idProductionOrder`, `idEquipment`, `qty`, `scanType`, `mode`, `rawBarcode`, optional `labelSeq`); returns `boxScanId`, `labelSeq`, `total`, `replayed` |
| `GET /api/scanned-boxes?idProductionOrder=&idEquipment=` | seed the "Caixas lidas" feed and total on load |
| `GET /api/samples?idEquipment=&idProductionOrder=` | sample rows |
| `POST /api/samples/create`, `POST /api/samples/delete` | sample total and sample labels |

The tenant is always the api-key's enterprise; edge-api fences equipment and PO to it and
overwrites any `idEnterprise` in the body.

## Internal design

### Structure

| Path | Role |
|---|---|
| `src/pages/main.tsx` | the station page: PO card, progress, scanner panel, reads table, samples |
| `src/components/barcode-scanner-panel.tsx`, `src/lib/scan-controller.ts` | keyboard-wedge input (`order;number;boxQty`, separators `;` or `ç`), validation, `submitScan()` |
| `src/lib/offline-queue.ts` | IndexedDB outbox (scan store keyed by `scan_uuid`) + cached PO counter |
| `src/lib/scans.ts` | edge-api scan client |
| `src/lib/samples.ts`, `src/lib/sample-label.ts` | sample persistence and numbering |
| `src/stores/line-selection-store.ts` | picked line, persisted |
| `src/components/app-shell.tsx` | line drawer |
| `src/components/tag.tsx`, `src/print.css` | thermal label (CODE128), printed with `window.print()` |
| `src/contexts/auth-context.tsx` | login or kiosk identity |
| `src/lib/api.ts` | axios `edgeApi` (6 s timeout, so it falls back to the outbox fast) |

Routes: `/login`, `/home`, anything else → `/login`.

### Scan flow and offline outbox

```text
 scan "1234;7;150" ─▶ validate (3 parts, order == running PO)
      ─▶ outbox.put(scan_uuid, request)           (always first; survives a crash)
      ├─ online: POST /api/scanned-boxes ─▶ labelSeq from server ─▶ print ─▶ outbox.delete
      └─ offline / 5xx / timeout: keep queued ─▶ optimistic next number from cached PO ─▶ print
 reconnect ('online' event, or 15 s poll while pending)
      ─▶ drainQueue: FIFO, one in flight
           2xx or idempotent replay ─▶ delete
           retryable (offline, 5xx)  ─▶ stop, keep the rest
           permanent 4xx (400/403/409) ─▶ drop that row, report it, continue
```

edge-api allocates `label_seq` under an advisory lock (gapless per PO) and is idempotent on
`scan_uuid`, so a replay never double-counts. An optimistic offline number can differ from
the server's; the server value wins on drain.

### Samples (since 2026-09-28, PR #8)

Product decision: samples are a **separate count** from production. Every sample row is
written with `shouldIncrement: false`, so edge-api never creates a companion
`scanned_boxes` row and box totals and reports stay pure production.

| `box_order_number` | Meaning | `increment` |
|---|---|---|
| `0` | the sample total the operator set for this PO and line | the total |
| `1, 2, …` | one printed sample label | its quantity |

A sample label is saved before it prints (a failed save prints nothing). The next number is
the highest issued + 1, so a deleted number is never reused. Changing the total deletes and
recreates the box-0 row (edge-api's edit only touches `should_increment` rows). Sample
writes go straight to edge-api; they are **not** in the offline outbox.

### Line drawer

The operator picks a line in a drawer fed by `GET /api/lines`. The choice is persisted in
localStorage key `packiot.selectedLine` (Zustand `persist`), so a kiosk reload keeps the
station. `VITE_STATION_EQUIPMENT_ID` is only a build-time default before anyone picks. The
drawer lists tp=3 lines only; POs run on lines on line-metered tenants. `GET /api/lines`
ignored the tenant fence until edge-api #272 (2026-09-28).

### Auth

The data plane never uses a user token: `edgeApi` deliberately sends no Bearer, because
edge-api commits to the Bearer path when it sees one. **Kiosk mode** is on when neither
Firebase nor Cognito is configured (or `VITE_AUTH_MODE=kiosk`): there is no login screen and
the station identity is `station-<id>`. Who may open the page is decided upstream (the
`csadmin` oauth2 tier on staging).

## Configuration

Build-time (`.env.example`):

| Variable | Effect |
|---|---|
| `VITE_EDGE_API_URL` | `""` = same-origin (production). Set only for local dev |
| `VITE_EDGE_API_KEY` | dev-only direct key; never set in an image |
| `VITE_STATION_EQUIPMENT_ID` | default line before the drawer is used (the CI image bakes none) |
| `VITE_AUTH_MODE` | `kiosk` forces kiosk mode |
| `VITE_AUTH_COGNITO_ENABLED`, `VITE_COGNITO_*`, `VITE_FIREBASE_*` | login screen only |

Runtime (container env, `compose.staging.yml`):

| Variable | Staging | Effect |
|---|---|---|
| `EDGE_API_UPSTREAM` | `http://edge-api:8080` | write/list plane |
| `EDGE_API_KEY` | `${BARCODE_EDGE_API_KEY}` (sandbox 2000003 `enterprises.api_key`, from `/opt/packiot/.env`) | tenant |
| `REFDATA_UPSTREAM`, `REFDATA_API_KEY` | `http://read-api:9104`, `${BARCODE_REFDATA_API_KEY}` | wired for parity, unused |

## Data & invariants

- Label numbers are gapless per PO and assigned by the server; the browser never decides
  them when online.
- `scan_uuid` is both the outbox key and the server idempotency key.
- Samples never change `scanned_boxes` or the production count.
- The api-key never reaches the browser in a deployed image.

## Observability

- In-app: pending-outbox badge, dropped-scan warnings (`onDropped`).
- edge-api logs for `/api/scanned-boxes` and `/api/samples`; rows in `scanned_boxes`
  (`box_order_number != 0` = real scans) and `sample_boxes`.
- `docker logs barcode-app` on the app host (nginx access log).

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Crash after every scan (fixed 2026-09-25, #6) | white screen right after a successful (201) scan | label printer read `.length` of a null client/product | null-safe label fields |
| Hard-coded "L03" / mock samples (fixed #6) | wrong station name; sample panel showing 315 | test fixtures in the UI | station name from the picked line; real samples |
| Empty progress bar over 100% (fixed #6) | bar disappears | negative translate | clamped |
| Picker showed machines only (fixed #6) | no PO found | POs run on lines | picker lists lines |
| White page on edge build (#238) | `#root` empty | Firebase initialised with undefined config | kiosk mode |
| Three different "produced" numbers (open, 2026-09-25) | PO net production differs between `production_orders`, operator runtime and front4 | unreconciled sources | not fixed |
| Wired to the old scan API | scans fail | the first build targeted the Phase-0 [barcode-service](barcode-service.md) `POST /v1/scans`, which never shipped to clients | the app now writes to edge-api `/api/scanned-boxes` (task #230) |
| Image cannot be pulled on the app host | `docker pull ghcr.io/…` unauthorized | host has no GHCR login; no `read:packages` token provisioned | build on the host (below) until a read-only token is delivered via Secrets Manager |

## Operating it

**Deploy to staging today (manual):**

1. Merge to `staging` in barcode-scanner-v2 (CI `ci.yml` runs lint, vitest and build).
2. Build `dist/` locally (`npm ci && npm run build`), copy it to the app host (SSM, verify
   sha256), and `docker build` the runtime stage of `Dockerfile.edge` (nginx 1.27-alpine +
   `dist/` + `nginx.edge.conf.template`) as `barcode-app:staging`. Tag the previous image
   first as `barcode-app:staging-<date>-<sha>` for rollback.
3. Recreate: `docker compose -p stack -f compose.staging.yml up -d --no-deps barcode-app`
   (use the compose files from the container's labels).
4. Smoke: open the drawer, pick a sandbox line, scan, check the label number and the
   sample total, reload and confirm the line persisted.

**Rollback:** retag the saved image as `barcode-app:staging` and recreate.

**On-prem:** set `barcode_edge=true` with csadmin's onboarding (Connect the PLCs →
barcode card, `POST /api/onboarding/barcode-edge`); the on-prem deploy adds the service
with image `${BARCODE_EDGE_IMAGE:-ghcr.io/packiot/barcode-edge:staging}`
(`edge-api/src/usecases/edge-ssm/shared/onprem-compose.ts`). It only matters together with
`onprem_offline`.

## Tests

`npm run test:run` (vitest; `src/test/offline-queue.test.ts` proves enqueue offline →
optimistic numbers → drain once → second drain no-op), `npm run lint`, `npm run build`.
CI: `.github/workflows/ci.yml` (PRs and pushes to `staging`/`main`);
`.github/workflows/build-edge.yml` publishes the images.

## Source map

| Path (barcode-scanner-v2) | What's there |
|---|---|
| `src/lib/offline-queue.ts`, `src/lib/scan-controller.ts`, `src/lib/scans.ts` | outbox, scan flow, API |
| `src/lib/samples.ts`, `src/lib/sample-label.ts` | samples |
| `src/stores/line-selection-store.ts`, `src/components/app-shell.tsx` | line drawer |
| `src/contexts/auth-context.tsx` | kiosk mode |
| `src/components/tag.tsx`, `src/print.css` | label |
| `Dockerfile.edge`, `nginx.edge.conf.template` | image, key injection |
| `.github/workflows/ci.yml`, `build-edge.yml` | CI, image publish |
| stack `compose.staging.yml` (`barcode-app`) | cloud instance |
| stack `edge-api/src/usecases/scanned-boxes/`, `samples/`, `onboarding/barcode-edge/` | server side |
| stack `edge-api/src/usecases/edge-ssm/shared/onprem-compose.ts` | on-prem `barcode-edge` service render |
