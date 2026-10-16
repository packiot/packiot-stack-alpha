# Barcode on the client box — onboard + deploy via the existing csadmin→SSM rail

**Status:** Proposed (edge-api + csadmin increments implemented + hardproofed on
staging; box deploy GATED) · **Date:** 2026-09-14 · **Task:** #230 edge-barcode ·
**Owner:** pending USER sign-off

The user's gap: *"csadmin needs to onboard and deploy [barcode] on the client box
as well"* — like it does operator/edge. This doc proves the current state, shows
that barcode rides the **exact same** csadmin→SSM on-prem rail as operator-edge,
and records what was implemented vs. what remains.

---

## 1. Current state (PROVEN)

### 1.1 The barcode functional path works end-to-end (Part 1)

Barcode was folded into edge-api as the `scanned-boxes` slice. The whole path was
hardproofed live on staging through the REAL edge nginx artifact (the
`barcode-app` container, built from barcode-scanner-v2 `Dockerfile.edge`, which
injects the sandbox enterprise api-key server-side):

- `POST /api/scanned-boxes` → **201**, `labelSeq` 3→4 (gapless +1), `total` +7 →
  writes `bronze.box_scans`, upserts `gold.po_box_counter`.
  - Route: `edge-api/src/usecases/scanned-boxes/record-scan/record-scan.controller.ts`.
  - Idempotency: `uq_box_scans_scan_uuid` (offline-outbox replay-safe) +
    `uq_box_scans_po_label` (gapless per-PO seq) — replay of the same `scanUuid`
    returned **200 `replayed:true`** with the counter unchanged (no double-count).
- `GET /api/scanned-boxes?idProductionOrder=…` → **200** (total/boxCount/lastLabelSeq/scans).
- Tenant is resolved SERVER-SIDE from the api-key
  (`res.locals.callerEnterpriseId`) — the body carries no tenant
  (`record-scan/dto/record-scan.dto.ts`).

**Wiring scope (live DB):** `bronze.box_scans` has 41 scans, `gold.po_box_counter`
4 rows — **all** `id_enterprise = 2000003` (SANDBOX-CPACK). NOT Bispharma (5), NOT
CPACK-Staging (3). Barcode is exercised **only on the sandbox tenant** today.

**Phase-0 confirmed:** no DB routine or view reads `gold.po_box_counter` (only a
`public.box_scans_no_mutate` guard trigger references `box_scans`). The box path is
durable scan/label ingest that does **not** feed OEE.

**Cloud SPA:** `barcode.staging.packiot.app` is up behind the cs-admin oauth2 gate
(302 → auth). The cloud instance is `barcode-app` in `compose.staging.yml`
(image `barcode-app:staging`, nginx injects the SANDBOX api-key). A separate
`barcode-service` (Go) container also runs but the scan WRITE path was repointed to
the same-origin edge-api plane (barcode-scanner-v2 commits `d0a0448`/`653a6b0`), so
`barcode-service` is superseded for the box/offline path.

### 1.2 How csadmin deploys to the SSM-managed client box (the rail)

Per **ADR-0049**, the client factory box is enrolled as an **AWS SSM managed
instance** (`mi-…`, tagged `managed-by=packiot-edge-api`). csadmin reaches it
outbound-only; **deploy = `ssm:SendCommand` (`AWS-RunShellScript`)** from
edge-api's `edge-ssm` slice. Two artifacts are pushed:

1. **The reader bundle** (Tier-1 PLC connectivity plane) —
   `deployWithBundle` → `bundlePushScript` base64-writes `compose.edge.yml` +
   generated `<tenant>/` + certs, then `docker compose up -d`
   (`edge-ssm/shared/edge-ssm.service.ts`).
2. **The on-prem fat-edge app stack** (ADR-0053/0054) — for a tenant with
   `descriptor.onprem_offline = true`, Go-live ALSO runs a second SendCommand:
   `onpremDeployScript` base64-pushes `compose.onprem-edge.yml` (rendered by
   `renderOnpremCompose`, `edge-ssm/shared/onprem-compose.ts`) + `.env.onprem`, then
   `docker compose … up -d --build`.

**The operator SPA already rides rail #2:** `renderOnpremCompose` emits an
`operator-edge` service **gated** on `opts.operatorEdge`, and Go-live sources that
from `row.descriptor?.operator_edge === true`
(`edge-ssm.service.ts:761`). The flag is toggled from csadmin's
`OperatorEdgeCard` (connections step) → `POST /api/onboarding/operator-edge` →
`OperatorEdgeService.set` → DAO `setOperatorEdge` (jsonb merge). The operator edge
image is a **published** ref (`ghcr.io/packiot/operator-edge:staging`) the box
pulls — the SPA source is not in the bundle.

### 1.3 The gap (PROVEN)

**Barcode is in ZERO deploy paths.** `grep -rn barcode` over
`docs/clients/edge-deployment/` (the bundle), `.github/workflows/`, and
`renderOnpremCompose` returns **no hits**. barcode-scanner-v2 already SHIPS a
`Dockerfile.edge` + `nginx.edge.conf.template` (byte-mirroring operator's), so the
box artifact EXISTS — it simply isn't wired into the onboarding-driven deploy.

---

## 2. Design — barcode rides the operator-edge rail

**Principle: reuse, don't invent.** Barcode is a login-less kiosk SPA that mirrors
operator-edge; make it a second gated service in the same generated
`compose.onprem-edge.yml`, toggled by the same descriptor-flag mechanism, deployed
by the same SendCommand.

### 2.1 On-box shape

`barcode-edge` service (container `onprem-barcode`, host port **8082** — dashboard
owns 8080, operator 8081), image `ghcr.io/packiot/barcode-edge:staging` (published
from barcode-scanner-v2 `Dockerfile.edge`; the box pulls it). Its nginx proxies
`/api` (scan writes + list) to `EDGE_API_UPSTREAM` and **injects the enterprise
`x-api-key` server-side**, so the browser never holds the tenant secret.

**The one real difference from operator-edge:** the operator authenticates each
user via Cognito `/session`, so operator-edge needs no api-key. The **barcode
kiosk has no per-user login** — it DEPENDS on the injected key. So `barcode-edge`
wires `EDGE_API_KEY: ${BARCODE_EDGE_API_KEY:-}` = the tenant's `enterprises.api_key`.
Under Option A (mirroring operator-edge) cloud edge-api stays the authoritative
writer; offline tolerance is CLIENT-SIDE (the SPA's IndexedDB outbox buffers scans
through an outage and drains on reconnect — `barcode-scanner-v2 src/lib/offline-queue.ts`).

### 2.2 Ingest path on the box

```
USB wedge scanner ─▶ barcode-edge SPA (:8082, on the box)
                        │ POST /api/scanned-boxes  (same-origin)
                        ▼ nginx injects x-api-key = enterprises.api_key
                     EDGE_API_UPSTREAM  (cloud edge-api, Option A)
                        ▼
                     bronze.box_scans  +  gold.po_box_counter   (gapless, idempotent)
```

Identical contract to the already-proven cloud path (§1.1). Increment 3 (a
factory-local edge-api) points `EDGE_API_UPSTREAM` on-box so writes survive an
outage without relying solely on the SPA outbox — same graduation path as
operator-edge's local-read-cache increment.

### 2.3 csadmin onboarding UX + API

- **Card:** `BarcodeEdgeCard` in the "Connect the PLCs" step, right under
  `OperatorEdgeCard` — an advisory toggle "Run the barcode scanner on the client's
  box (offline scanning)". Optimistic flip + roll-back, mirroring operator-edge.
- **API:** `GET/POST /api/onboarding/barcode-edge` → `descriptor.barcode_edge`
  (jsonb merge, preserves siblings). Only meaningful alongside `onprem_offline`.
- **Deploy:** no new button — Go-live / `POST /api/edge-ssm/deploy-onprem` already
  emits the gated service when `barcode_edge` is set.

---

## 3. What was implemented (this pass) + hardproof

All **staging-only**; nothing pushed to a real client box.

### edge-api (`feat/barcode-edge-onprem-deploy`)
- `onprem-compose.ts`: `barcodeEdge`/`barcodePort`/`barcodeEdgeImage` options +
  a gated `barcode-edge` service (port 8082, api-key injected).
- `edge-ssm.service.ts`: `onpremDeployScript` threads `barcodeEdge`, sourced from
  `descriptor.barcode_edge` at BOTH call sites (Go-live + `deployOnpremStack` —
  also fixed a latent miss where `deployOnpremStack` passed neither flag).
- `client-descriptor-dao.ts` (+interface): `getBarcodeEdge`/`setBarcodeEdge`
  (jsonb merge, mirrors operator_edge).
- New usecase `onboarding/barcode-edge/` (controller + service + dto + module wiring).
- Tests: `onprem-compose.spec.ts` (+2 cases: barcode-only, operator+barcode both) and
  `barcode-edge.service.spec.ts` (6 cases).

**Hardproof:**
- `jest onprem-compose barcode-edge operator-edge` → **18/18 pass**.
- Rendered `renderOnpremCompose({operatorEdge:true, barcodeEdge:true})` →
  `docker compose config` on the app box → **COMPOSE_CONFIG_OK** (valid schema,
  distinct ports 8081/8082).
- DAO SQL round-trip in a **rolled-back** tx against sandbox 2000003:
  set→`true`, read→`true`, siblings (`tenant`/`equipment`) preserved, toggle→`false`,
  rollback → key absent (no live mutation).
- `tsc --noEmit` clean.
- Runtime behavior of the barcode edge nginx artifact itself is already proven
  live (§1.1) — the generated service references that same image.

### csadmin (`feat/barcode-edge-onboarding-toggle`)
- `BarcodeEdgeCard` + `onboardingApi.get/setBarcodeEdge` + `BarcodeEdgeState`,
  rendered under `OperatorEdgeCard`. `tsc --noEmit` clean.

---

## 4. What remains (phased)

| # | Item | Where | Status |
|---|------|-------|--------|
| B1 | Publish `ghcr.io/packiot/barcode-edge:staging` from barcode-scanner-v2 `Dockerfile.edge` (CI) | barcode-scanner-v2 CI | ⬜ (operator-edge has the same dependency) |
| B2 | Source `BARCODE_EDGE_API_KEY` from `enterprises.api_key` at render time (write it into `.env.onprem`) so the kiosk key is turnkey, not hand-seeded | edge-ssm.service `renderOnpremEnv` | ⬜ (needs an enterprises read; today the CS engineer sets it on the box) |
| B3 | Station equipment id: `VITE_STATION_EQUIPMENT_ID` is Vite-BAKED per image → a per-station image, OR add a runtime station picker to the SPA (operator picks equipment in-app; barcode currently bakes it) | barcode-scanner-v2 | ⬜ (the one non-mirror gap) |
| B4 | Box deploy: enable `onprem_offline` + `barcode_edge` on a WITNESSED sandbox box (mi-…) and run deploy-onprem; verify `onprem-barcode` serves + a scan lands | staging box | ⬜ GATED (do not push to a real client box unwitnessed) |
| B5 | Increment 3: point `EDGE_API_UPSTREAM` at a factory-local edge-api for true offline writes | onprem-compose | ⬜ (shared with operator-edge) |

**Risks:** (a) B3 — the baked station id means the published image is
station-specific unless the SPA gains a runtime picker; flagged as the only place
barcode does not cleanly mirror operator. (b) B2 — until the api-key is
render-sourced, a redeploy overwrites `.env.onprem`, so `BARCODE_EDGE_API_KEY`
must be render-injected (not hand-seeded) to be durable. (c) Barcode only meaningful
with `onprem_offline` — the card copy says so but the flag is stored orthogonally.
