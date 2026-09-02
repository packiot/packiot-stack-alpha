# ADR-0052 — Edge autonomy during internet outages

- **Status:** Informational — the device-side capability is **already built and live**;
  one residual gap is a blocked, decision-gated follow-up (below).
- **Date:** 2026-09-01
- **Relates:** ADR-0045 (shared-ingest onboarding), ADR-0019 C3 (edge-operator SPA),
  the reader store-and-forward spool (edge-api `reader-bundle.ts`)
- **Deciders:** (only the residual gap needs a decision)

> **Two evidence passes revised this ADR down to almost nothing.** The first draft
> asserted operators can't act offline and that offline reads + a device queue
> would be new work. Verified against the **live** system, all of that was already
> built. What follows is the proof, not the assumptions.

---

## 1. Question

During an internet outage at a factory, can operators still **(a) act** (PO
control + downtimes) and **(b) see data + have it stored/synced**, with the thin
box + the reader spool we have?

## 2. Answer (proven): yes, device-side — it is already live

The operator SPA is a **PWA** whose deployed build already carries **both** halves
of offline autonomy on the operator's own device. Evidence is from the **live
deployed operator container**, not source assumptions:

| Capability | Proof (live `operator` container / deployed bundle) | State |
|---|---|---|
| **Offline reads** | serves `sw.js` + `workbox-*.js` + `manifest.webmanifest`; `StaleWhileRevalidate` and `/v1/` are compiled into `sw.js`. `pwa.config.js`: `GET /v1/*` refdata reads are runtime-cached SWR (`REFDATA_CACHE_NAME`, 24h); writes/login excluded | **LIVE** — offline shows last-known reads |
| **Offline writes** | live bundle contains `VITE_PO_WRITE_QUEUE_ENABLED:"true"` + the `operator-write-queue` IndexedDB store | **LIVE** — actions queued, not lost |
| Write durability/correctness | `writeQueue.js`/`durableWrite.js`: IndexedDB (survives reload/crash), idempotency key, monotonic `seq` (PO-ordered replay), optimistic-concurrency token (stale replay → 409 `review`), jittered retry; tested | correct by construction |
| Box thinness (why device-side is what matters) | `docker ps` on the bispharma box = one container `packiot-edge-reader`; no `:80/:5432/:1880`/edge-api | thin, confirmed |

So requirement **(a)** and the **read** half of **(b)** are **met, live, today** —
on the tablet, independent of the thin box. The reader spool separately preserves
the **telemetry** so counts aren't lost.

## 3. The one genuine residual gap

**Multi-device / box-side shared durability.** The read cache and the write queue
live in **one tablet's** browser storage. Consequences:

- If that device dies / is wiped / rotates, its **pending write queue is lost**.
- A **second device** on the same line has **no shared offline truth** (its cache
  + queue are independent).
- The SWR read cache can be **up to 24h stale** in a long outage (bounded, but the
  operator should know the data's age).

This is the *only* part not covered device-side. The fix is a **box-side shared
store** so multiple devices share one offline truth that survives any single
device — i.e. **ADR-0019 C3's on-box edge-operator mode** (operator SPA + factory-
local edge-api + local refdata + a local store, syncing to cloud on reconnect).

## 4. Status of the box-side fix (proven): designed, blocked, undeployed

- `docs/adr/reference/designs/0019-C3-edge-operator-spa.md` — **Status: design
  (2026-07-08), blocked on C1 (edge command channel).**
- Its two core pieces — a **local read layer** and **write buffering that syncs to
  cloud** — are listed as *needs*, and are **not built** (edge-api has no
  local-mode / cloud-sync code; `Dockerfile.edge` is in **no** compose file).
- So the box-side tier is a real multi-part build (unblock C1 → local refdata
  cache/store → cloud-sync worker → deploy the edge stack per box), **not** a flag
  or a deploy of something finished.

## 5. Recommendation

- **Do not build anything device-side** — reads (SWR SW cache) and writes (durable
  queue) are already live. The earlier "build the operator queue / read cache"
  proposals were redundant; proof retired them.
- **Codify what's live so it can't regress silently:** the write-queue build-arg is
  already explicit in `compose.staging.yml`; add an equivalent guard/test that the
  service worker + `/v1` SWR cache stay in the build (a smoke check that `sw.js`
  ships and matches `/v1/`).
- **Treat the box-side tier as a per-client decision, not a default.** It only buys
  multi-device + single-device-loss resilience, at the cost of unblocking C1 and
  reintroducing an on-box stack. Justify it against a specific client's outage +
  device profile (see questions) before building.

## 6. Open questions (only for the box-side decision)

1. Realistic **outage duration**? A 24h SWR read cache + device queue covers a
   shift comfortably; only multi-hour/multi-day or device-loss scenarios need the
   box-side tier.
2. **One shared kiosk** per line (device-side is enough) or **multiple devices**
   (pushes to the box-side shared store)?
3. Which clients have both **unreliable internet** *and* a **device-loss / multi-
   device** exposure — i.e. who actually needs ADR-0019 C3?

## 7. What this ADR changed

Nothing to implement. It converted an assumed gap ("operators can't work offline")
into a proven fact ("they already can, on the device") and narrowed the real
open work to one blocked, decision-gated item. Lesson recorded: verify against
`origin/staging` + the **live deployed artifact** (grep the served bundle / sw.js)
before asserting a capability is missing.
