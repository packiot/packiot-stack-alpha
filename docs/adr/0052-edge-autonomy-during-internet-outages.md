# ADR-0052 — Edge autonomy during internet outages (control-plane store-and-forward)

- **Status:** Proposed (design only — no build)
- **Date:** 2026-09-01
- **Supersedes/relates:** ADR-0045 (client onboarding / shared-ingest), the reader
  store-and-forward spool (edge-api `reader-bundle.ts`), [[project_newstack_nodered_retirement]]
- **Deciders:** (pending)

---

## 1. Context

The shared-ingest onboarding model (ADR-0045) makes the factory box a **thin
reader**: it polls PLCs and POSTs raw counts to a shared cloud agent. Everything
else — the control plane (PO start/stop/pause/finish, downtime creation +
justification, event/setup, box scans, samples), reads, and OEE — runs in the
**cloud** (edge-api / refdata-api / oeecloud-worker). This is deliberate: thin
edge, central upgrades, cheap onboarding.

We recently added a **reader spool** so a network outage no longer drops PLC
counts (buffer on failure, replay on reconnect). That fixed exactly **one plane
and one direction**: telemetry *out*.

It does **not** make the factory autonomous during an outage. This ADR confronts
the gap the reader spool does not close.

## 2. Problem

During an internet outage at a factory, with today's thin-reader architecture:

1. **Operators cannot act.** Start/stop a PO, justify a downtime, set an event —
   all POST to **cloud** edge-api over the internet. Offline, every one of these
   fails. The line keeps running physically, but **no control action and no
   operator-attributed event is recorded** for the whole outage window.
2. **There is no local store.** The box has no local DB or local control surface,
   so there is nothing to accept an action offline and reconcile later.
3. **Counts survive, context is lost.** The reader spool preserves the *counts*
   (cumulative totalizers replay), but the counts land with **no PO context and no
   downtime attribution** for the window — because the PO/downtime state that
   contextualizes them was never recorded. You get "N units were made" but not
   "under which order, interrupted by which stops."

The legacy architecture did not have this gap: `edge-node-red` ran **on the
factory box**, so operators kept working through an outage and it forwarded when
the link returned. The shared-ingest move pulled that control plane into the
cloud and **has not yet replaced its offline capability**. (Operator is currently
*half-migrated*: `edge-node-red` still serves ~19 operator action routes — so for
some tenants offline behavior today depends on where that legacy box stack runs,
which is itself being retired.)

**Requirement (this ADR's target):** during an internet outage, a factory must be
able to **(a) perform operator actions** (PO control + downtimes) and **(b) store
production data locally**, then **reconcile to the cloud on reconnect** with no
lost or duplicated actions.

## 3. What breaks, precisely (outage failure map)

| Plane | Path today | Offline behavior | Covered by reader spool? |
|---|---|---|---|
| PLC telemetry (counts) | reader → cloud agent → DB | **buffered + replayed** | ✅ yes |
| PO control (start/stop/pause/finish) | operator → cloud edge-api → DB | **fails** — no PO transitions recorded | ❌ no |
| Downtime create + justify | operator → cloud edge-api → DB | **fails** — no downtime/attribution | ❌ no |
| Event / setup / lead-machine actions | operator → cloud edge-api → DB | **fails** | ❌ no |
| Box scans / samples | scanner/operator → cloud → DB | **fails** | ❌ no |
| Reads (dashboards, current PO) | refdata-api (cloud) | **fails** (stale/blank UI) | ❌ no |
| OEE compute | oeecloud-worker (cloud) | n/a (recomputes from data on reconnect) | — |

The **cumulative-totalizer** property softens telemetry loss (the next successful
read carries the accumulated delta), but it does **nothing** for the control
plane: a PO start that never happened cannot be inferred from a totalizer, and a
downtime with no operator reason is just a gap.

## 4. Options

### Option A — Local edge stack on the box (control-plane store-and-forward)

Put a **slim edge stack back on the factory box**: a local edge-api (the same PO
/ downtime / event write endpoints), a **local datastore** (SQLite or a small
Postgres), and a **sync worker**. The operator app points at the **local** edge
during an outage; the local edge accepts actions and persists them; the sync
worker reconciles to the cloud when the link returns.

- **Pros:** true autonomy — closest to the legacy edge-node-red capability;
  operator UX unchanged; reads can be served from the local store too.
- **Cons:** heaviest. Reintroduces an on-box service to build/upgrade/monitor
  (the exact weight the thin-reader model shed). Needs a robust **bidirectional
  sync + conflict model** (§5). Two edge-api instances to keep in lockstep.

### Option B — Operator-side action queueing (PWA offline buffer)

The operator **PWA** (front4/operator) persists each action to a local queue
(IndexedDB) when edge-api is unreachable, and **replays** them on reconnect. No
new on-box service.

- **Pros:** far lighter; nothing new to run at the factory; leans on the device
  already at the line.
- **Cons:** autonomy is only as good as the **operator device** (a shared
  kiosk/tablet). If the device reboots/rotates/battery-dies, the queue is lost.
  Multiple devices → no shared offline truth. **Reads** are still dead offline
  (no local data to render current PO / recent counts). It buffers *intent*, not
  *state*.

### Option C — Hybrid (queue now, local store later)

Ship **B** first (operator-side queue for actions — quick, meaningful) and treat
**A** (local store + local reads) as the durable follow-on where a tenant
genuinely needs multi-device / read-offline autonomy.

## 5. The hard part — reconciliation (applies to A and B)

Buffering actions is easy; **reconciling them without lost/duplicate/contradictory
state is the whole problem.** Any chosen option must define:

- **Idempotency.** Every buffered action carries a **client-generated action id**;
  the cloud upserts on it so a double-replay (flaky reconnect) is a no-op. Without
  this, retries create duplicate downtimes / double PO starts.
- **Ordering & causality.** Actions replay in **original timestamp order** per
  entity (a PO's start must land before its stop). Cross-entity order is looser.
- **PO state-machine reconciliation.** A PO is a state machine (available →
  running → paused/finished). Offline transitions must be validated against the
  server state at replay: replaying "start PO 42" when the cloud already shows 42
  finished is a conflict, not a silent overwrite — it needs an explicit rule
  (reject + surface, or fold into history).
- **Server-allocated ids.** Some rows get server ids (e.g. a new downtime row).
  Offline creation needs a **client temp-id → server-id** remap on sync, and any
  later action referencing the temp id must be rewritten.
- **Time.** Offline events carry the **box/device clock**; skew must be recorded
  (and ideally corrected against a trusted source on reconnect) so downtime
  windows land in the right shift.
- **Telemetry ↔ control join.** The reader spool replays counts with their
  original `scan_ts`; the control replay must use the **same timeline** so counts
  re-associate with the PO/downtime that was active then.
- **Conflict surfacing.** A reconciliation conflict is **shown to CS/operator**,
  never silently dropped — the same "make absence legible" principle we hold
  elsewhere.

**Reusable prior art in-repo:** the twin **operator-action replicator**
(legacy → new-stack), `mirror-worker-go`, and `operator-gateway` already move
operator actions between planes — the idempotency/id-remap machinery there is the
starting point for the sync worker, not a green field.

## 6. Recommendation

**Option C (hybrid), design-gated.** Concretely:

1. **Phase 0 — this ADR + a reconciliation spec.** Nail §5 (action-id idempotency,
   PO state-machine rules, temp-id remap, clock handling) *before* any code. This
   is where the risk lives; it must be reviewed, not improvised.
2. **Phase 1 — operator-side action queue (Option B).** Highest value per unit
   risk: operators keep acting through an outage, actions replay idempotently on
   reconnect. No new on-box service. Reads stay online-only for now (documented).
3. **Phase 2 — local store + local reads (Option A)** *only for tenants that need
   multi-device or read-offline autonomy.* This is the heavy lift; justify it
   per-client rather than defaulting every box back to a fat edge.

Rationale: it restores the **operator-action** capability (your first
requirement) quickly and safely, delivers **local storage + sync** as the Phase-2
store, and avoids reflexively rebuilding the fat edge on every box — we add weight
only where a client's outage profile demands it.

## 7. Consequences

- **Cost/risk:** Phase 1 is a front4/operator + edge-api change (moderate). Phase 2
  reintroduces an on-box service (heavy — build, upgrade path, monitoring, the
  full sync model). Both are dwarfed by the risk of getting §5 wrong: a bad
  reconciliation silently corrupts PO history, which is worse than an outage.
- **Non-goals:** this ADR does **not** cover offline OEE compute (recomputed from
  reconciled data on reconnect) or offline BI.
- **Interaction with the reader spool:** complementary. Spool = telemetry-out
  buffer; this = control-plane buffer + local store. Full autonomy needs both, on
  the same replay timeline.

## 8. Open questions for the deciders

1. What is the **realistic outage duration** to design for (minutes? hours? a
   shift?) — it sets how much local *read* capability Phase 2 needs.
2. Is the operator device a **single shared kiosk** (Option B viable alone) or
   **multiple devices** per line (pushes toward Option A's shared local store)?
3. Which tenants actually have **unreliable internet** — do we need this
   everywhere, or is it a per-client capability?
