# The Edge-Operator (offline floor operation)

How a client's shop floor keeps **operating** — starting/stopping production
orders, justifying downtime — through an internet outage, not just *seeing* live
numbers. This is the **action half** of on-prem autonomy: the operator SPA runs
**on the factory box** with a local read-cache and a durable write-forwarder, so
operators keep working while the link is down.

> **Where this sits.** [On-Prem Offline Operation](11-on-prem-offline-operation.md)
> keeps the floor *seeing* live counts (a read-only dashboard off an on-box cache).
> This page is the next layer: the *operator itself* on the box, so the floor keeps
> *doing* — reads served from a local cache, writes buffered and forwarded to the
> cloud on reconnect. It is **opt-in per client** (ADR-0054), on top of on-prem
> offline, and it does **not** make the box a second source of truth.

## The one-line model (Option A — durable-forward-only)

The **cloud edge-api stays the single authoritative writer.** The box does two
things during an outage: serve reads from a local cache, and hold writes durably
until the cloud is back — then forward them exactly once.

```
operator tablet ─▶ operator SPA served FROM the box (nginx.edge.conf.template)
                     │
   /v1 reads ───────┼─▶ REFDATA_UPSTREAM, with an nginx stale-cache:
                     │     online  → fresh (30s); OUTAGE → last good snapshot
                     │
   /api writes ─────┴─▶ EDGE_API_UPSTREAM = factory-local write-forwarder:
                           online  → forward to CLOUD edge-api, return its answer
                           OUTAGE  → durably queue on the box (SQLite outbox),
                                     return 202 {queued}; drain FIFO on reconnect,
                                     Idempotency-Key preserved → cloud dedups
```

Two design choices make this safe:

1. **Cloud remains authoritative.** The box owns no PO state and runs **no local
   Postgres** — it only guarantees a write is *not lost* and lands *exactly once*
   when connectivity returns. (The locally-authoritative alternative — Option B, a
   local DB + bidirectional sync — is **designed but gated on the C1 command
   channel**; see [Relation to ADR-0054](#relation-to-adr-0054).)
2. **Reads survive an outage without lying about it.** The `/v1` cache serves the
   last good snapshot when the cloud is unreachable, but is deliberately
   **GET-only** — the SPA's reachability probe is a **HEAD**, so it always reaches
   the upstream and still detects the outage (a cached HEAD would give a false
   "reachable" and suppress the offline banner + write buffering).

## What actually runs on the box

The edge-operator adds one container to the on-prem stack
(`compose.onprem-edge.yml`, emitted by the onboarding generator when
`operator_edge=true`):

| Container | Role | Notes |
|---|---|---|
| `onprem-operator` | the operator SPA + its edge nginx | the same SPA build (`Dockerfile.edge`), with the offline write-queue **baked in** (`VITE_PO_WRITE_QUEUE_ENABLED=true`). nginx proxies `/api`+`/session`→`EDGE_API_UPSTREAM`, `/v1`→`REFDATA_UPSTREAM`, injecting the tenant api-key server-side (the browser never holds it). `/v1` has a stale read-cache |

It sits beside the fat-edge visibility stack (mosquitto + agent + transformer +
dashboard — see [On-Prem Offline Operation](11-on-prem-offline-operation.md)) and,
in the full Option-A deployment, the factory-local **write-forwarder** the
operator's `/api` points at.

## Reads offline — the `/v1` stale cache

The operator's edge nginx caches `GET /v1/*` responses. While online they stay
fresh for 30 seconds; when `REFDATA_UPSTREAM` is unreachable (transport error,
timeout, or a 5xx) nginx serves the **last good snapshot** (`proxy_cache_use_stale`)
so the operator keeps its PO/downtime context instead of blank reads.

- **GET-only** (`proxy_cache_methods GET`) — see the reachability note above.
- `proxy_cache_path` lives at the nginx **http** context; the operator's edge
  config renders into `conf.d/*.conf`, included inside `http{}`.

Citation: `operator` `nginx.edge.conf.template` (the `/v1/` location + the
`proxy_cache_path`); `operator` `src/Services/reachability.js` (the HEAD probe,
`PROBE_PATH` default `/v1/language-packs`).

## Writes offline — the forward-outbox

The operator's `/api` points at a **factory-local write-forwarder** that reuses the
same crash-safe SQLite store-and-forward as the reader/agent
(`internal/outbox`, ADR-0011). Its contract:

| Situation | What the forwarder does |
|---|---|
| Cloud reachable | forward the write to the cloud edge-api; return its **real** response verbatim |
| Cloud returns a real **4xx** (e.g. a stale-state 409) | that's an *answer*, not an outage — return it, **never queue** it (buffering a rejected write would replay it forever) |
| Cloud **unreachable** (transport error, or a gateway 502/503/504) | append the write to the on-box outbox, return **202 `{queued}`**; a drain replays it FIFO on reconnect |
| Reconnect | replay each queued write **exactly once**, preserving its `Idempotency-Key` so the cloud dedups; delete the row on a definitive response |

This upgrades today's *single-tablet* offline buffer (the SPA's IndexedDB queue) to
a **shared, box-resident** durable queue — a lost or swapped tablet no longer loses
its unreplayed actions.

Citation: `services/sparkplug-decoder/internal/writeforward` (the forward-or-queue
+ drain engine, unit-tested against a stub cloud); `internal/outbox` (ADR-0011).

> **Shipped vs. in-flight.** The write-forwarder **engine** (`internal/writeforward`)
> is merged and unit-proven. Its **deploy layer** — the `cmd/edge-write-forwarder`
> HTTP service (`/api` + a factory-local bcrypt `/session` + a drain ticker), the
> compose wiring that points the operator's `EDGE_API_UPSTREAM` at it, and the live
> outage-cycle validation on the box — is the tracked next step. Until it lands, an
> edge-operator deployment points `EDGE_API_UPSTREAM` at the **cloud** edge-api:
> reads still survive an outage via the `/v1` cache, and writes buffer in the SPA's
> own IndexedDB queue (per-tablet) rather than the shared box outbox.

## Turning it on — the onboarding toggle

The edge-operator is **opt-in per client**, on top of on-prem offline. In the
CS-Admin onboarding **"Connect the PLCs"** step, beneath the *"Enable on-prem
offline operation"* card, an **"Enable edge-operator"** toggle sets a single
descriptor flag: `client_descriptors.descriptor.operator_edge = true`.

The edge-api contract behind the toggle (mirrors the on-prem-offline one):

- `GET /api/onboarding/operator-edge` → `{ enabled }` (reads
  `descriptor.operator_edge`; 404 when the tenant has no descriptor row yet).
- `POST /api/onboarding/operator-edge` → merge-sets the flag in place, preserving
  every other descriptor key incl. `onprem_offline` (audit event
  `onboarding.operator-edge`).

**What the flag drives:** the on-prem **Deploy** step's generated
`compose.onprem-edge.yml` includes the `onprem-operator` service **only when
`operator_edge=true`** (default off ⇒ the emitted compose is exactly the proven
fat-edge stack).

Citations: `csadmin` `src/components/onboarding/operator-edge-card.tsx`;
`edge-api` `src/usecases/onboarding/operator-edge/operator-edge.controller.ts`;
`edge-api` `src/usecases/edge-ssm/shared/onprem-compose.ts`
(`renderOnpremCompose`, the `operatorEdge`-gated service).

> **Prerequisite:** the edge-operator rides the same factory box as the fat-edge
> stack, so **on-prem offline should be enabled too**. The toggle is advisory (it
> does not gate wizard progression); you can turn it on later.

## Cloud vs. edge — the same SPA, different proxy targets

The edge deployment is a **deployment pattern, not a new app** (ADR-0019-C3). The
operator SPA became, in [ADR-0018](../adr/0018-operator-frontend-integration-makeover.md),
a static container whose backends are *proxy targets*: reads→refdata, writes+login
→edge-api. Edge deployment just repoints those targets at factory-local services.

| Concern | Cloud operator (default) | Edge-operator (opt-in) |
|---|---|---|
| static SPA | served from the cloud | same image, **on the box** |
| `/v1` reads | → cloud refdata | → local cache (stale-serve on outage) |
| `/api` writes, `/session` | → cloud edge-api | → factory-local write-forwarder → cloud |
| PLC parameter write-back | — (not needed) | → the C1 command channel (**gated**) |

The cloud operator is unchanged and remains the default for every client. The
edge-operator is the same SPA, deployed at the edge, for a client whose outage
profile warrants it.

## Relation to ADR-0054

ADR-0054 realizes the edge-operator deployment (ADR-0019-C3) for the **non-C1**
scope, choosing **Option A (durable-forward-only)** and recording **Option B
(locally-authoritative, local Postgres + bidirectional sync) as a design-only
future gated on the C1 PLC command channel**. Increments (all on `origin/staging`):

| # | What | Where |
|---|---|---|
| 1 | offline write-queue baked into the edge image | `operator` `Dockerfile.edge` |
| 2 | generator emits `compose.onprem-edge.yml` + the gated `operator-edge` service | `edge-api` `onprem-compose.ts` |
| 3 | `/v1` stale read-cache (GET-only) | `operator` `nginx.edge.conf.template` |
| 4 (core) | the write forward-outbox engine | `services/sparkplug-decoder/internal/writeforward` |
| 5 | settable `operator_edge` flag + the CS-Admin toggle | `edge-api` onboarding slice + `csadmin` card |

Full rationale + the PROVEN-vs-DESIGN-ONLY split are in
`docs/adr/0054-on-prem-edge-operator-outage-writes.md`.

## Quick reference

| Question | Answer |
|---|---|
| Does the box become a source of truth? | **No** (Option A). The cloud edge-api stays the single authoritative writer; the box buffers + forwards. |
| Can operators keep working offline? | **Reads** — yes, from the local `/v1` cache. **Writes** — accepted + buffered, and they *land* on reconnect (not before). |
| Does an outage silently swallow a write? | No — a real 4xx is returned as an answer; only an unreachable cloud queues, and queued writes replay exactly once (idempotency-keyed). |
| Why is the read cache GET-only? | So the SPA's HEAD reachability probe still detects the outage (a cached HEAD ⇒ false "reachable" ⇒ no offline banner). |
| How is it turned on? | The **"Enable edge-operator"** onboarding toggle → `descriptor.operator_edge=true` → the deploy emits the `onprem-operator` service. |
| Prerequisite? | On-prem offline (the operator rides the same fat-edge box). |
| What about PLC parameter write-back? | Needs the C1 command channel — **gated**; the edge-operator can read + justify + control POs without it. |

See also: [On-Prem Offline Operation](11-on-prem-offline-operation.md) ·
[Outage Resilience & Offline Operation](10-outage-resilience-and-offline.md) ·
[Frontends, Infra & Auth](07-frontends-infra-auth.md) ·
[Onboarding a Client](02-onboarding.md#3-connect-the-plcs).
