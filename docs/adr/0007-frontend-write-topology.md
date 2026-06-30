# ADR 0007 — Frontend write topology: synchronous-local-or-queued-remote

**Status:** Deferred (was Proposed; deferred 2026-06-30)
**Date:** 2026-06-29
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team
**Supersedes:** none
**Extends:** [ADR-0001](./0001-edge-persistence-local-timescaledb.md) (offline data persistence), [ADR-0005](./0005-edge-nodered-self-hosted-runner-deploys.md) (per-factory deploys)

---

## DEFERRED — 2026-06-30

The internet-outage tolerance program this ADR is part of has been **deferred**. The team's current judgment is that the cost-to-customer of building offline-tolerant writes is not yet justified by the observed outage frequency, and the architectural complexity (per-factory queues, intent reconciliation, dual-write UX, etc.) is best parked until a clearer business signal arrives.

This ADR is preserved here as **future-revivable planning**. If/when the team revisits offline tolerance, this is the starting point — the analysis below is still valid, the architecture is still sound, the dependencies on [ADR-0001](./0001-edge-persistence-local-timescaledb.md) (also deferred) are unchanged.

**Revival conditions to watch for:**
- Recurring customer complaints about lost operator actions during connectivity blips
- New customer in a geography with unreliable connectivity (e.g. remote factories)
- Compliance requirement for guaranteed-execution operator actions

The original content below is preserved verbatim. No edits.

---

## Context

### Today's write path is cloud-coupled end-to-end

Every operator click — justify event, start PO, scan box, manual downtime — travels:

```
operator browser → factory edge-api → cloud TimescaleDB (HTTPS over the internet)
```

When the cloud is unreachable from a factory (internet outage, GCP region degradation, cloud DB maintenance window), the operator screen returns 5xx and the action is **lost**. There is no local buffer. OEE attribution is later wrong; the box that was scanned isn't counted; the PO whose start time was 10:00 sharp shows up as starting at whenever-internet-came-back-plus-a-few-seconds.

ADR-0001 already committed to making factory-side data **persistable locally** (TimescaleDB at the factory, logical replication to cloud). That ADR is about the *storage* layer. This ADR is the *API surface* corollary: now that data CAN survive locally, the write APIs need to actually USE that local storage when the cloud is unreachable, AND we need to define what happens to writes that originate OUTSIDE the factory.

### The "out-of-factory write" problem

Today's world is single-tenant per request: every write goes to one cloud DB. As factories gain autonomy under ADR-0001, the data-of-record for a given factory's events lives at the factory. But Customer Success engineers, regional managers, customer admins, and BI users routinely need to perform writes that touch a specific factory's data from outside that factory's network:

- A regional manager remotely starts a PO on factory X's line 4
- A support engineer fixes a stuck downtime on factory Y from a Slack thread
- A customer admin updates the schedule for factory Z from corporate HQ

These writes need to land in the factory's authoritative copy. The cloud DB can't BE the authority — that re-introduces the cloud-coupled write path ADR-0001 was getting rid of.

### Why this needs an ADR (not just a ticket)

- Topology decision: which side of the cloud/factory split owns "the truth" for which write.
- Routing decision: who decides where a write goes, and on what input.
- UX contract: what does a remote user see for an action they initiated that won't apply for 10 minutes?
- Failure semantics: queued intents need idempotency, ordering, retries, DLQ — all the patterns the platform team has built and reused before, now applied here.

---

## Decision

Adopt a **mixed write topology** in which the criticality of the endpoint determines whether the write is cloud-authoritative (Option A) or factory-authoritative (Option B). The cloud edge-api becomes the single API surface for all clients; routing is internal to it.

### The two paths

```
═══════════════════════════════════════════════════════════════════
NORMAL writes  (Option A — cloud-authoritative)
═══════════════════════════════════════════════════════════════════
   Client → Cloud edge-api → Cloud TSDB
                              │
                              └─ replicates down to factories (read-side)

   Examples: CS Admin onboarding (enterprise/site/area/equipment CRUD),
             shift catalog, downtime category management, user/role
             management, report generation.

═══════════════════════════════════════════════════════════════════
CRITICAL writes  (Option B — factory-authoritative, with two modes)
═══════════════════════════════════════════════════════════════════
   SYNCHRONOUS MODE  (client is at the factory + factory is reachable)
   Client → Cloud edge-api → proxy to factory edge-api → Factory TSDB → 201
                                          │
                                          └─ replicates up to cloud

   QUEUED MODE  (client is remote OR factory unreachable from cloud)
   Client → Cloud edge-api → enqueue intent on factory-X queue → 202 + intent_id
                                          │
                                          └─ Factory drainer pulls,
                                             applies locally, replicates
                                             result back, notifies client via SSE

   Examples: operator event justification, PO start/stop/pause/resume,
             box scans, manual downtime entry, event edit/split, sample
             tracking.
```

### How "critical" is determined

A `CRITICAL_PATHS` registry — a single source-of-truth file in edge-api, reviewed via PR like any code. Each route handler either is or isn't tagged critical. The classification rule for reviewers:

> *Critical if a 4-hour outage would cost the customer money (OEE attribution loss, missed production count, stuck floor operation).*

The default for a new endpoint is **NOT** critical; promotion to critical requires a PR review and an entry in the registry.

### How "in-factory vs remote" is determined

By the request's source IP, matched against a per-factory allowlist stored alongside the factory record. Each factory's local network range(s) are registered explicitly. Mobile operators on cellular while physically at the factory get an **explicit toggle** in the login flow, persisted in the JWT — trust-on-first-use, audit-logged.

### Idempotency contract

Every critical write **must** include an `Idempotency-Key` header (client-generated UUID). The factory drainer dedups by this key, holding successful responses for 24h. Reference: Stripe's [Idempotent Requests](https://stripe.com/docs/api/idempotent_requests).

### Single binary, two modes

Cloud edge-api and factory edge-api remain the same Docker image. A boot-time env var `EDGE_API_MODE` selects:

- `cloud_router`: loads RouterModule (intent producer, SSE notifier, OptionA handlers)
- `factory_local`: loads IntentDrainerModule (intent consumer, local DB writes)

Shared module: route handlers, DAOs, DTOs — the actual business logic is identical; only the I/O perimeter differs.

### Architectural shape

```
┌──────────────────────────────────────────────────────────────────────┐
│  Frontend SPA (front4, S3+CloudFront)                                │
│   - calls api.packiot.com for everything                             │
│   - handles 201 (sync OK) and 202 (queued, track via intent_id)      │
│   - service worker may swap base URL to factory-local if detected    │
└──────────────────────────────────────┬───────────────────────────────┘
                                       ▼ HTTPS
┌──────────────────────────────────────────────────────────────────────┐
│  Cloud edge-api (EDGE_API_MODE=cloud_router)                         │
│                                                                       │
│  Middleware pipeline:                                                 │
│   1. Auth + factory_id extraction (from JWT)                         │
│   2. ClassifyPath: CRITICAL or NORMAL                                 │
│   3. If NORMAL → handle locally, write cloud TSDB → 201              │
│   4. If CRITICAL:                                                     │
│      - ClientLocation: factory IP allowlist match                    │
│      - FactoryReachable: heartbeat / circuit breaker                 │
│      - If at-factory + reachable → reverse-proxy to factory_X        │
│        edge-api → 201 (synchronous mode)                              │
│      - Else → enqueue to RMQ `intents.factory_X` queue,              │
│        persist intent row (status=pending) → 202 + Location          │
│   5. SSE endpoint /api/intents/:id/stream for client tracking        │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │ RabbitMQ
                                       ▼ (queue-per-factory)
┌──────────────────────────────────────────────────────────────────────┐
│  Factory edge-api (EDGE_API_MODE=factory_local)                      │
│                                                                       │
│  IntentDrainer goroutine/consumer:                                    │
│   - consumes `intents.factory_X` (durable, prefetch=1)               │
│   - dispatches via CRITICAL_PATHS to internal handler                 │
│   - executes against local TSDB with Idempotency-Key dedup           │
│   - publishes result to `intent-results.factory_X`                    │
│   - acks message; on failure → exponential backoff → DLQ at 5x       │
│                                                                       │
│  Existing HTTP API (for in-factory operator SPA + cloud reverse-     │
│  proxy traffic) unchanged.                                           │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Consequences

### Positive

- **Operators keep working during cloud/internet outages.** The single biggest UX-and-business win.
- **Single frontend codebase** — the SPA doesn't know whether a write is sync or async; the API surface looks the same.
- **Reuses existing infra**: RabbitMQ (already at every factory), edge-api (already dual-deployed), DLQ + reanimator patterns (PR #84 on mirror-worker-go).
- **Pattern is recognizable**: this is the Kubernetes controller-API-server pattern in miniature. New engineers will pattern-match in minutes.
- **Per-factory blast radius**: a stuck factory queue affects only that factory's CRITICAL writes; everyone else continues working.
- **Composable with ADR-0001**: leverages the local TimescaleDB ADR-0001 introduces; nothing wasted.

### Negative / Trade-offs

- **Async write UX** for remote critical operations is hard to design well. A naive "pending..." spinner that hangs for 20 minutes during an outage frustrates users. **Mitigation**: explicit "queued — factory currently offline" status with cancel/retry, exposed in admin tools.
- **Idempotency-Key discipline** is now a SPA contract. Every critical write must generate + send a UUID; retries must reuse it. **Mitigation**: enforce in the SPA's API client wrapper; reject requests missing the header at the cloud edge-api.
- **Queue bloat under prolonged offline factories** — `intents.factory_X` accumulates while factory is down. **Mitigation**: RabbitMQ queue depth alarms; admin UI to cancel/redirect stuck intents; max-queue-length policy with overflow→DLQ.
- **Operational surface grows**: per-factory queue depth, per-factory intent age p99, factory-reachability circuit-breaker state — all new things to monitor. **Mitigation**: extend the existing Grafana per-factory dashboard pattern (one new row, ~half a day of dashboard work).
- **Conflicts when in-factory write races with a remote intent**: if local operator and remote manager both modify PO 42 within the replication-lag window, last-writer-wins is wrong. **Mitigation**: optimistic locking via `WHERE updated_at = expected_version` in critical handlers; conflict surfaced to remote user as 409 with "please refresh".
- **Schema drift across factory + cloud during deploys**: a critical-path handler that exists in cloud but not yet on factory edge-api breaks the proxy mode. **Mitigation**: deploy factory edge-api before cloud edge-api in any rollout that changes the CRITICAL_PATHS registry (operationally enforced; staging drill required).

---

## Phased rollout

**Phase 1 — Classification + spec (~3 days)**
- Audit edge-api routes, tag each via `@CriticalPath()` decorator
- Document the CRITICAL_PATHS list in `docs/critical-paths.md`
- Land this ADR in a PR; review and accept

**Phase 2 — Cloud router middleware (~5 days)**
- New NestJS middleware in cloud edge-api
- IP allowlist data model: add `factory_ip_ranges` table or extend `sites` schema
- RabbitMQ `intents.factory_<id>` queue declarations (one-time TF / boot-time)
- Idempotency-Key validation
- Persist intents in cloud DB (`intents` table with state machine)

**Phase 3 — Factory drainer (~3 days)**
- New consumer in factory edge-api
- Dispatch table mapping `intent.path` to internal route handler
- DLQ + reanimator (reuse PR #84 pattern from mirror-worker-go)
- Result publishing back to cloud via `intent-results.factory_<id>`

**Phase 4 — SPA pending-state UX (~5 days)**
- API client wrapper: handle 202 with intent tracking
- SSE subscription for pending intents
- Component library: "Syncing to factory…" / "Confirmed" / "Factory offline — retry/cancel"
- Optimistic UI for in-factory operators (assume success; revert on async failure)

**Phase 5 — Observability + ops (~3 days)**
- Grafana per-factory panels: intent_queue_depth, intent_age_p99, intent_failure_rate
- CloudWatch alarm: intent_age > 5min for any factory → paging
- Admin UI: "stuck intents" view with cancel/replay/escalate
- Quarterly drill: simulate factory outage, queue 10 intents from cloud, restore, verify drain

**Total: ~3–4 weeks of focused work.**

---

## Implementation rules (load-bearing — reviewers should enforce)

1. **Every critical handler MUST be idempotent under retry of the same `Idempotency-Key`.** Tested per-handler. No exceptions.
2. **CRITICAL_PATHS additions require a PR review by the platform team.** It's the most important file in the system.
3. **The cloud router middleware MUST NOT mutate the request payload.** It only routes. If it transforms, you have two code paths to debug.
4. **Factory edge-api MUST be deployed BEFORE cloud edge-api on any PR that adds a CRITICAL path.** Otherwise the new path 404s on the factory drainer.
5. **The SSE endpoint MUST tolerate disconnects with auto-resume from intent ID.** A user closing their laptop mid-pending shouldn't lose the intent's result.
6. **No critical write may be batched across factories.** Each intent targets exactly one factory's queue. Cross-factory writes belong to Option A (cloud-authoritative) by definition.

---

## Open questions for review

- **Q1 — What's the SSE keep-alive cost at scale?** If we have 1000 simultaneously-pending intents from regional managers, do we need to fall back to long-polling?
- **Q2 — Should the in-factory IP allowlist auto-update from EC2 metadata, or stay manually managed?** Auto is convenient but breaks under VPC peering changes. Manual is foolproof but stale-prone.
- **Q3 — Do we want to expose intent IDs to end users?** "Reference Q-Z3F2K to support" is useful for support tickets, but URL-encoded UUIDs feel internal. Decision before Phase 4.
- **Q4 — Replication-lag-aware reads after an intent confirms.** The cloud SSE notification fires when the factory acks the write, but the cloud's REPLICATED VIEW of that write may lag by a few seconds. Should the SSE event include the replicated row inline (avoid a separate read), or stay event-only?

---

## References

- ADR-0001: Edge persistence with local TimescaleDB
- ADR-0005: Per-factory self-hosted runner deploys
- [Stripe Idempotent Requests](https://stripe.com/docs/api/idempotent_requests) — the canonical API design for this
- [AWS IoT Jobs](https://docs.aws.amazon.com/iot/latest/developerguide/iot-jobs.html) — exact same pattern (queue intents bound for offline devices, drain on reconnect)
- [Kubernetes API Server / Kubelet architecture](https://kubernetes.io/docs/concepts/architecture/) — the structural reference
- [Erlang/OTP supervision trees](https://www.erlang.org/doc/system/sup_princ.html) — what to read when designing drainer failure-recovery

---

## Decision log

| Date | Decision | Decider |
|---|---|---|
| 2026-06-29 | ADR drafted | Emmanuel + Claude |
| TBD | Reviewed by platform team | |
| TBD | Accepted | |
