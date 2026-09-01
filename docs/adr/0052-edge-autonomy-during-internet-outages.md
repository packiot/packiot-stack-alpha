# ADR-0052 — Edge autonomy during internet outages (control-plane store-and-forward)

- **Status:** Proposed (design only — no build)
- **Date:** 2026-09-01
- **Relates:** ADR-0045 (shared-ingest onboarding), ADR-0019 C3 (edge-operator SPA),
  the reader store-and-forward spool (edge-api `reader-bundle.ts`),
  [[project_newstack_nodered_retirement]]
- **Deciders:** (pending)

> **Revision note (evidence pass):** the first draft of this ADR asserted that
> operators cannot act during an outage and that a device-side write queue would
> be new work. **Both were wrong** — verified against the live system, not
> assumed. The corrections below are grounded in the proof in §3.

---

## 1. Context

The shared-ingest model (ADR-0045) makes the factory box a **thin reader**: it
polls PLCs and POSTs raw counts to a shared cloud agent. Reads, control-plane
writes, and OEE run in the cloud. We recently added a **reader spool** so a
network outage no longer drops PLC counts (buffer → replay). That covers exactly
one plane/direction: telemetry *out*. This ADR asks what else an outage breaks —
and, corrected against evidence, what is **already handled**.

## 2. Requirement

During an internet outage a factory must be able to **(a) perform operator
actions** (PO control + downtimes) and **(b) retain production data**, then
**reconcile to the cloud on reconnect** with no lost or duplicated actions.

## 3. What is ACTUALLY true today (proof, not assumption)

Verified 2026-09-01 against the live staging system:

| Claim | Evidence | Verdict |
|---|---|---|
| The factory box is thin — no local control plane | `docker ps` on the bispharma box (mi-0114): **one** container `packiot-edge-reader`; `compose.edge.yml` declares only `reader:`; listening ports are only AnyDesk/SSH/RDP — **no `:80`, no `:5432`, no `:1880`, no edge-api** | **TRUE** |
| Operator SPA writes go to **cloud** edge-api | `compose.staging.yml` note: the deployed operator calls `edge-api (/session, /api/*)` + `refdata-api (/v1/*)`; the `:1880` (edge-node-red) regex is **vestigial** | **TRUE** (and my earlier "~19 routes on edge-node-red" was stale — that path is dead for the deployed operator) |
| Operators **cannot** act offline | **FALSE.** The operator ships a durable offline **write queue** (`src/Services/writeQueue.js`, `durableWrite.js`), and the **live bundle has `VITE_PO_WRITE_QUEUE_ENABLED:"true"`** + references the `operator-write-queue` IndexedDB store | **ENABLED — operators DO act offline** |
| A device-side action queue would be new work | **FALSE.** It exists, is enabled, and is tested (`writeQueue.test.js`, `durableWrite.test.js`, `offlineGuard.test.js`, `reachability.test.js`) | already built |

### What the offline write queue actually does (read from source)

- **Durable, device-local.** Writes persist to **IndexedDB** (`operator-write-queue`),
  chosen over `localStorage` explicitly to survive reload / tab-crash / OS-kill on
  the floor tablet.
- **Idempotent.** Each entry's `id` is the idempotency key → a double-replay on a
  flaky reconnect is a no-op (no duplicate downtimes / double PO starts).
- **Ordered.** A monotonic `seq` drains in enqueue order so a PO's start replays
  before its stop.
- **Conflict-safe.** Replay carries the **original action time** + an
  **optimistic-concurrency token**; a stale replay is **refused (409) and parked
  as `review`**, never blindly applied.
- **Resilient.** Transient errors (offline / timeout / 5xx) keep the entry and
  retry with jittered backoff; only a definite client error drops it.
- **Visible.** `OfflineBanner` + `PendingSync` surface queued/needs-review state.

So requirement **(a)** — operator actions during an outage — is **substantially
already met** for the WRITE path, on the operator device.

## 4. The REAL remaining gaps (what evidence leaves open)

1. **Offline READS.** The operator reads current-PO / entity lists from cloud
   `refdata-api`. Offline, those reads fail — the operator can *queue writes* but
   is acting **semi-blind** (can't refresh what the current PO / recent counts
   are). The write queue buffers *intent*, not *view state*.
2. **Single-device durability.** The queue lives in **one tablet's** IndexedDB. If
   that device dies/rotates, its pending queue is lost, and a second device on the
   same line has no shared offline truth. There is no **box-side** store.
3. **Telemetry↔control timeline join on reconnect.** The reader spool replays
   counts with original `scan_ts`; the operator queue replays actions with original
   action time. Both are timestamp-preserving, but nothing *verifies* they
   reconcile onto the same timeline (e.g. a downtime window vs the counts inside
   it). Worth an explicit reconciliation check, not an assumption.

## 5. The designed-but-undeployed answer already in the tree

`ADR-0019 C3` defines an **on-box edge-operator mode** (`operator.mode: edge`):
`Dockerfile.edge` + `nginx.edge.conf.template` serve the operator SPA **on the
box**, proxying to **factory-local** `edge-api:8080` + `refdata-api:9104`. That is
exactly the fix for gaps #1 and #2 — local reads + a box-side store shared across
devices. **Proof it is not live:** `Dockerfile.edge` appears in **no** compose
file, and the bispharma box runs only the reader. So the capability is designed
and scaffolded but **not deployed** for any tenant.

## 6. Recommendation (corrected)

**Do not rebuild what exists.** Reframed around evidence:

1. **Confirm + keep the device write-queue on.** It's live on staging
   (`VITE_PO_WRITE_QUEUE_ENABLED=true`). Make that flag an explicit, codified
   per-env build arg so it can't silently regress. (Requirement (a): met.)
2. **Decide the box-side tier per client.** Gaps #1/#2 (offline reads +
   multi-device durability) are answered by the **ADR-0019 edge-operator mode**,
   which is designed but undeployed. Deploy it **only** for tenants whose outage
   profile needs offline reads or multi-device resilience — don't default every
   box back to a fat edge. Requirement (b) (local storage + sync) is delivered by
   that mode's local edge-api + DB, not by new invention.
3. **Add a reconcile check** that the spool's telemetry timeline and the operator
   queue's action timeline agree on reconnect (gap #3) — small, high-value.

The only genuinely *new* build here is (3) plus wiring/deploying (2) where needed;
(1) is a codification of an already-live flag. The heavy "operator-side queue"
work I first proposed is **already done**.

## 7. Open questions for the deciders

1. Realistic **outage duration** to design for (minutes / hours / a shift)? Sets
   how much offline **read** capability gap #1 needs.
2. **One shared kiosk** per line (device queue may suffice) or **multiple
   devices** (pushes to the ADR-0019 box-side store)?
3. Which tenants actually have **unreliable internet** — is the edge-operator mode
   a per-client capability or a default?
