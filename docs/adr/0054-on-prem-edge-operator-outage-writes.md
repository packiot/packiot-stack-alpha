# ADR-0054 — On-prem edge-operator: offline-tolerant operator writes (ADR-0019-C3 realization)

- **Status**: Accepted (2026-09-02) — decider: Emmanuel Podestá. Realizes the
  deployment pattern designed in [0019-C3](reference/designs/0019-C3-edge-operator-spa.md);
  supersedes the "design-only" status of C3 for the **non-C1** scope.
- **Context inputs**: three hard-proof review agents (2026-09-02) — cloud operator
  route map, on-prem operator posture, edge-operator build-surface map. Every claim
  below is tagged **[PROVEN]** (live box read / file:line) or **[DESIGN-ONLY]**.

## Context — proven current state

**Cloud operator [PROVEN].** The deployed staging operator (box `i-06c9547a2c7091ab7`)
is fully ADR-0018 migrated: `src/Services/endpoints.js` sends reads → refdata (`/v1/*`),
writes + `/session` → edge-api (`/api/*`). No `edge-nodered` container exists; 6 read
routes live-probed 200. The vestigial edge-nodered nginx block was retired
(operator #114). There is **no gap in the cloud operator**.

**On-prem operator [PROVEN], box `mi-0114b66366e2d6613` (bispharma).** `docker ps -a`:
`packiot-edge-reader` + `sim-bisnago-l60` + the fat-edge stack (`onprem-mosquitto`,
`onprem-agent`, `onprem-transformer` LOCAL_DECODE_ONLY, `onprem-dashboard` :1881).
**No operator, no edge-api, no refdata, no Postgres on the box** (`ss -tlnp` for
`:80/:443/:5432/:1880` → none). The site runs the **cloud** operator over the internet.
During an internet outage:
- Telemetry OUT buffers in the reader spool (`_SPOOL_MAX=20000`, fsync, replays) — durable.
- The floor keeps a **read-only** live-state dashboard (`edge-dashboard`, 3 routes,
  Snapshot read only) — outage-immune by construction.
- Operator WRITES are captured to the tablet's IndexedDB queue (`durableWrite.js` +
  `writeQueue.js`, idempotency key + staleness gate) and replay to the **cloud**
  edge-api on reconnect — but do **not land** while offline, and reads go blind
  (no local read layer).

**Build-surface [PROVEN].** Already built: operator `Dockerfile.edge` (envsubst of
`nginx.edge.conf.template`, `EDGE_API_UPSTREAM`/`REFDATA_UPSTREAM`); the SPA offline
suite (`durableWrite`/`writeQueue`/`reachability`/`offlineGuard`); factory-local
`/session` bcrypt (`login.service.ts:46`, reads `users.operator_pw_hash`); the
onboarding gate (`descriptor.onprem_offline`) + `POST /deploy-onprem`. **Proven-absent**:
(a) the edge image did not bake `VITE_PO_WRITE_QUEUE_ENABLED` — the offline queue was
compiled out (fixed, operator #115); (b) any server-side operator-write outbox;
(c) a local read layer (refdata cache) — `nginx.edge.conf.template:50` itself calls it
a future; (d) generator emission of `compose.onprem-edge.yml` — it is provisioned
**out-of-band** (`edge-ssm.service.ts:830` comment; `git ls-files | grep onprem` empty),
violating the rule that everything on-prem deploys via csadmin onboarding.

## Decision

**Build the offline-tolerant edge-operator using Option A — durable-forward-only —
emitted entirely by the csadmin onboarding generator. Option B (locally-authoritative)
is designed but gated on [C1](reference/designs/0019-C1-edge-command-channel.md).**

### Option A — durable-forward-only (CHOSEN)

- The box serves the operator SPA (`Dockerfile.edge`) + a **local read layer** (refdata
  cache) on `:9104`, and a **factory-local edge-api** serving `/session` (bcrypt, local
  creds) and accepting `/api/*` writes.
- The cloud edge-api remains the **single authoritative writer**. Factory-local edge-api
  is a **buffering forwarder**: online → proxy to cloud; offline → enqueue to a durable
  **box-side outbox** (SQLite, modelled on the reader spool `reader-bundle.ts:585` and
  the sparkplug-agent `outbox.go`) and replay to cloud on reconnect. The SPA's existing
  idempotency-key + staleness-gate (`durableWrite.js`) protects replays.
- The local read layer is a **one-way** cloud→box snapshot cache (reference data +
  `uns_equipment_current_*`), so reads survive an outage. **No bidirectional sync.**

**Why A.** It delivers offline reads + durable offline writes for PO-lifecycle and
downtime justification (exactly C3's non-C1 scope) with **no local Postgres and no
reconciliation engine** — leaning on code that already exists. The box-side outbox
upgrades today's single-tablet IndexedDB buffer to shared, tablet-loss-durable storage.

### Option B — locally authoritative [DESIGN-ONLY, gated on C1]

The box runs a local Postgres; factory-local edge-api writes there and is source-of-truth
during the outage; reads reflect in-outage writes; a **bidirectional** sync reconciles
local↔cloud on reconnect. Rejected **for now** because it owns distributed-DB
reconciliation — conflict resolution, version vectors, a real sync engine — the exact
shadow-DB/mirror-drift class this platform has already been bitten by (refsync FK rot;
shadow-cognito column drift). B is only justified once the floor needs reads that reflect
in-outage writes *and* local OEE, which co-arrives with C1 PLC write-back. Revisit B
when C1 lands; until then A is strictly sufficient.

## Increment plan (no C1; each independently provable, no live-box mutation to ship)

| # | Increment | Delivers | Proof | Status |
|---|-----------|----------|-------|--------|
| 1 | Bake `VITE_PO_WRITE_QUEUE_ENABLED=true` into `Dockerfile.edge` | offline write buffer actually enabled in the edge image | existing `durableWrite`/`writeQueue` tests; grep built `dist` | **DONE — operator #115** |
| 2 | Generator emits `compose.onprem-edge.yml` (proven fat-edge stack) + a flag-gated `operator-edge` service | closes the out-of-band violation; operator deployable via onboarding | `onprem-compose.spec.ts`: PyYAML-validates the render, default == proven fat-edge stack, flag-on adds operator-edge with correct upstreams; edge-ssm suite 121/121 | **DONE — edge-api #239** |
| 3 | Local read layer on `:9104` (snapshot cache: pull reference + `uns_equipment_current_*` → local SQLite, serve `/v1`) | reads survive an outage | unit test cache-fallback (serve last snapshot when upstream down); rendered-compose wiring test | planned |
| 4 | Factory-local edge-api forward-outbox (`/session` local + `/api` enqueue→forward) | durable offline writes that replay to cloud | replay test against a stubbed cloud edge-api (503→200) | planned |
| 5 | Descriptor sub-flag `operator.mode:'edge'` (only if dashboard-only boxes must exclude the operator) | separates "run dashboard" from "run operator SPA" | DAO + gate unit tests | optional |

Increment 1 is decision-free and shipped. 2 is the codification keystone. 3 is the
largest net-new build. 4 is small given the reader-spool precedent. All 1–4 are identical
under A vs B, so B can be reconsidered later without rework of 1–4.

## Consequences

- **Positive**: offline-tolerant operator (reads + durable writes) with no new DB and no
  reconciliation engine; the on-prem stack becomes fully onboarding-generated (no
  hand-committed compose); the box-side outbox removes single-tablet write-loss risk.
- **Negative / accepted**: during an outage the operator sees optimistic write state only
  (reads reflect the last cloud snapshot, not in-outage writes) — acceptable for
  PO-lifecycle + justification; a long outage means a larger replay + more 409
  reconciliation into the review tray; PLC parameter write-back stays unavailable until C1.
- **Follow-up**: revisit Option B when C1 lands. The one-way snapshot cache (increment 3)
  is the natural seam to later promote to a local replica if B is ever chosen.

## References
- [0019-C3 edge-operator SPA design](reference/designs/0019-C3-edge-operator-spa.md) — the deployment pattern this realizes.
- [0018 operator integration makeover](0018-operator-frontend-integration-makeover.md) — the read/write split that makes edge deployment a proxy-target change.
- [0053 on-prem ingest edge](0053-on-prem-ingest-edge-for-outage-autonomy.md) — the reader spool + fat-edge stack this extends.
- [0052 on-prem outage gaps] / [0019-C1 edge command channel](reference/designs/0019-C1-edge-command-channel.md) — the offline-reads / write-durability gaps and the PLC write-back dependency.
