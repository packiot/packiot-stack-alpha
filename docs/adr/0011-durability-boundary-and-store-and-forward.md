# ADR 0011 — Durability boundary and store-and-forward pattern

**Status:** Proposed (DRAFT — awaiting team review)
**Date:** 2026-06-30
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team
**Supersedes:** none
**Extends:** [ADR-0010](./0010-sparkplug-decode-in-go-end-state.md) — this ADR formalizes the durability line at the OT/IT bridge ADR-0010 established.
**Complements:** [ADR-0009](./0009-edge-transformer-go-service-and-nodered-split.md) (the reuse-rule discipline this ADR piggybacks on for pattern consistency)

---

## Context

### The seam we didn't formalize

ADR-0010 established the OT/IT bridge: MQTT at the factory, RabbitMQ in the cloud, edge-transformer as the transformer. It said "protocol decode moves to Go." It did NOT say **where the responsibility for message delivery starts**.

That question surfaced during the ADR-0010 Phase 2 implementation session (2026-06-30), while walking through what happens when a PLC restarts:

- **Before PLC → Mosquitto**: no durability. QoS 0 for Sparkplug DATA. Messages during network flaps or PLC crashes are lost, unrecoverable.
- **After AMQP publish with confirms → RabbitMQ**: durable. Broker persists to disk before ack.
- **Between those two**: fuzzy. Depends on how we implement.

The team consensus (Emmanuel, 2026-06-30, verbatim):

> *"the durability has to go to the left. i want our stack to be robust, so after the data leaves plc and nodered is our responsability, before that probably is a factory issue"*

That single sentence is architecturally load-bearing. It defines who owns which reliability failure. Formalizing it here so every future PR reviewer has a checklist.

### What we have today

- MQTT publishing (PLC → Mosquitto): Sparkplug B QoS 0. Best-effort by design.
- Node-RED SparkPlug subflow (staging): consumes from Mosquitto, publishes to legacy `oee` exchange via `amqp-pub-oee-amqplib`. Publisher confirms status: **unknown** (Node-RED library defaults; needs audit).
- Phase 2.5b Node-RED publisher tab: publishes to `edge.plc-normalized` via HTTP-management-API. Publisher confirms status: **NO** (HTTP API is fire-and-forget).
- Phase 2.5b's `sp-to-publisher-adapter`: no local buffer. If the HTTP publish fails, the message is dropped silently.
- edge-transformer's `shadowpub.Publish` (PR #124): uses `DeliveryMode: 2 (persistent)` but does NOT enable publisher confirms. If RabbitMQ crashes mid-write, the publish returns nil and we lose the message silently.
- No component receiving from MQTT has a local disk buffer. In-flight messages are lost on crash.

### Why this matters *now*

Every one of the above is a silent-loss path. Some are unavoidable (PLC crash → data during downtime). Others are within our control (RabbitMQ mid-write drop). The value of formalizing the boundary now — before more code lands past it — is that every future publisher and consumer inherits the rules by default.

Waiting until a production incident forces the conversation costs 10× more (existing code needs retrofitting, ops has learned to distrust the system, customer trust erodes).

---

## Decision

**Draw the durability boundary at "the moment data enters Packiot-owned software."**

Concretely:
- **Left of boundary (factory-owned)**: PLC firmware, PLC-to-broker network, factory-side infrastructure. Data loss here is *the factory's contract*. Our responsibility is to make it OBSERVABLE (sequence gaps, NDEATH events) but we do NOT try to recover it.
- **Right of boundary (Packiot-owned)**: Mosquitto, Node-RED, edge-transformer, RabbitMQ, all consumers, historian. Data loss here is *our bug*. Silent loss is unacceptable; loss with an accompanying alert is acceptable while the fix is engineered.

The boundary passes through Mosquitto's "message received" API. As soon as Mosquitto has acknowledged a `PUBLISH` from a PLC, the message is Packiot's responsibility.

### The rules (load-bearing for reviewers)

Every PR that touches a Packiot-owned publisher, consumer, or receiver MUST satisfy these:

1. **Every publisher to RabbitMQ MUST use publisher confirms.** No exceptions. If confirms fail, the message goes to the local outbox (rule 3) or, in absence of outbox, retries with bounded exponential backoff before returning error to the caller. Failures are metric-visible.

2. **Every consumer MUST be idempotent under duplicate delivery.** RabbitMQ retries, our reanimator loops, and network glitches all mean the same message may be handled multiple times. Consumers use business-key deduplication (e.g., `mirror_id_map`, `equipment_events.id_source_log`, `(equipment_id, source_timestamp, parameter)`) to make repeated delivery safe.

3. **Every component that receives from MQTT MUST buffer to disk before forwarding.** Once the outbox pattern lands (Phase 3 of this ADR's rollout), MQTT `onMessage` immediately persists the message to a local SQLite outbox before returning. A separate goroutine drains the outbox at line rate to RabbitMQ (with publisher confirms). Crash between `onMessage` and drain: message survives on disk.

4. **Every health endpoint MUST expose "degraded" states — never silent-degrade.** `/healthz` returning "healthy" while the publisher has 30 seconds of unconfirmed messages, the disk queue is above threshold, or the MQTT subscriber has received 0 messages in 60s is a lie. Return `503` with a structured reason.

5. **Message loss with an accompanying alert is acceptable; silent loss is not.** If we cannot deliver a message, we log at ERROR, increment a Prometheus counter, and (where applicable) route the message to a DLX / disk-quarantine location for later triage. The bar is *observable*, not *zero*. Silent-drop is a bug even if the message was going to be lost anyway.

6. **The reviewer checklist applies to EVERY PR.** Any PR that adds or modifies a publisher-to-broker call, a consumer callback, or a receive-from-MQTT path must include a paragraph in its body confirming which of the rules apply and how they're satisfied. If none apply, say so explicitly. "N/A" is acceptable; "silent" is not.

### Rule 0 (implied): asymmetric responsibility

The factory owns the PLC firmware, the PLC-to-Mosquitto wire, and the fieldbus. If a PLC crashes and loses 5 minutes of data, that's a PLC bug + operational recovery, NOT a Packiot bug. We help the factory diagnose it (via NDEATH events + seq-gap alerts) but we don't try to reconstruct the data.

This asymmetry is deliberate. Trying to close every leak on the OT side means owning firmware — infeasible across N customer sites with M PLC vendors. Trying to close every leak on the IT side means engineering — tractable, one codebase.

---

## Consequences

### Positive

- **Production incidents become debuggable.** Every failure mode has a metric, a log line, or a DLX entry. "The customer says we lost data" becomes "here's exactly where and why" within minutes.
- **Reviewer velocity goes UP, not down.** Reviewers apply a fixed checklist instead of re-deriving reliability arguments per PR.
- **New consumers ship faster.** Idempotency + DLX + retry topology are the defaults — new work inherits them.
- **Customer trust compounds.** "We have never silently lost your data" is a marketable claim once the pattern is in place.

### Negative / Trade-offs

- **Added complexity.** Publisher confirms, local disk buffering, retry loops, degraded health states are all new code. Each has its own failure modes (disk full, retry-storm, confirm-timeout).
- **Disk-full watchdog is a new operational concern.** The local outbox needs monitoring + rotation + capacity planning.
- **Some latency added.** Publisher confirms add ~1-2ms per publish. Local outbox adds an fsync per message (10-100μs on SSD). Not enough to matter for factory rates (~10 msg/s per PLC), meaningful only if we ever push to Kafka-scale rates.
- **~2 weeks of focused engineering** to implement the full pattern across all Packiot-owned components.

### Neutral

- **Matches enterprise IoT norms.** Cirrus Link MQTT Distributor, AWS IoT Greengrass Stream Manager, Ignition Edge Store-and-Forward, Azure IoT Edge — every serious industrial IoT platform ships this pattern. We are joining the standard, not inventing it.
- **Does NOT change the OT-side design.** PLC firmware, MQTT topology, Sparkplug conventions all stay per-spec. This ADR affects only what happens after Mosquitto acknowledges a publish.

---

## Alternatives considered

### A. "Best-effort throughout" — no durability boundary

Rejected. Works for real-time-only observation (Grafana dashboards). Fails for anything the customer bills against (production counts, quality gates, OEE reports). Once a customer disputes a monthly OEE number based on "your system lost data during our shift", we lose the argument. Best-effort throughout is uninsurable.

### B. "Push durability all the way to the PLC" — QoS 1/2, PLC-side buffering

Rejected. Requires touching PLC firmware. Infeasible at scale (N customers × M vendors × K firmware versions). Even for customers who WOULD let us touch their PLC firmware, the change would take 6-12 months per site to roll out. We can't wait.

Recommend: help customers who care to install Ignition Edge or Cirrus Link at their factory (which does have PLC-side buffering). Packiot integrates with those tools rather than reinventing them.

### C. "Durability starts at RabbitMQ" — current state

Rejected implicitly by this ADR. This is the pattern edge-transformer today has (Phase 2.5b publisher tab, shadowpub PR #124 without confirms). It leaves a silent-loss window between Mosquitto and RabbitMQ. That window is the exact scenario Emmanuel called out this session as unacceptable.

### D. "Durability starts at consumer processing" — messages persistent, consumer acks on success only

This is a subset of the chosen decision. Already true (RabbitMQ persistent queues + ack-on-success). But it's insufficient on its own — it protects the QUEUE-to-consumer link, not the PUBLISHER-to-queue link. This ADR strengthens the whole chain.

---

## Phased rollout

**Phase 0 — ADR + memory + reviewer checklist (THIS PR)**
- This document
- Update project memory
- Adopt the reviewer checklist for future PRs

**Phase 1 — P0 items (~1 week)**
- Publisher confirms on `shadowpub.Publisher.Publish` — no more silent RabbitMQ-side loss
- Mosquitto persistence config in `compose.dev.yml` + staging + prod — retained NBIRTHs survive broker restart
- Consumer idempotency documentation + code review checklist reference sheet
- Extended `/healthz` — degraded state on `publish rate = 0` for > 60s or `unconfirmed > 30s`

**Phase 2 — P1 items (~1 week)**
- Bounded ingestion queue in `internal/mqtt/subscriber.go` — bounded buffered channel between paho callback and Handler
- Drop-metric when queue is full — the "visible drop" pattern (never silent-drop)
- Prometheus per-failure-mode metrics + Grafana alerts

**Phase 3 — P2 outbox (~2 weeks — the meaty engineering)**
- New `internal/outbox/` package using SQLite (mirrors `mirror-worker-go`'s `mirror_replay_dlq` pattern)
- MQTT `onMessage` writes to outbox FIRST, then enqueues to drain goroutine
- Drain goroutine publishes to RabbitMQ with confirms + retry loop
- On successful confirm, deletes from outbox
- On failed confirm, retry with exponential backoff up to N attempts, then quarantine
- `/healthz` exposes outbox depth + oldest message age
- Ops playbook: how to inspect outbox, replay stuck messages, drain a full disk

**Phase 4 — P3 hardening (~few days)**
- Grafana alerts for every degraded state
- Runbook for each alert
- Chaos test: kill RabbitMQ, kill edge-transformer, kill Mosquitto — verify zero silent loss

**Total: ~4-5 weeks of focused engineering**, mostly parallelizable with the ADR-0010 Phase 2 rollout.

---

## Implementation rules (reviewer checklist)

Copy-paste into future PR templates:

```
## Durability review (ADR-0011)

- [ ] Does this PR add or modify a publish call to RabbitMQ?
      → confirm publisher confirms are enabled + used
- [ ] Does this PR add or modify a consumer callback?
      → confirm idempotency key + duplicate-safe behavior
- [ ] Does this PR add or modify an MQTT receive path?
      → confirm bounded ingestion queue + local outbox write (once Phase 3 lands)
- [ ] Does this PR add or modify a health endpoint?
      → confirm degraded states are surfaced, no silent-degrade
- [ ] Every failure mode → metric + alert path documented
- [ ] N/A: (explain if this PR truly doesn't touch these)
```

---

## Open questions for review

1. **SQLite vs BadgerDB vs BoltDB for the outbox?** Recommend SQLite (mirrors `mirror-worker-go`; ops familiarity; battle-tested crash consistency). Confirm with team before Phase 3.

2. **Bounded ingestion queue size?** Recommend 10,000 messages (~10 seconds of buffer at typical CPACK rates). Should scale with tenant count?

3. **Outbox max disk size?** Recommend 1 GB with FIFO drop-oldest policy on overflow. Should we surface this as a config?

4. **Publisher confirm timeout?** Recommend 5 seconds. Longer = risk of blocking the ingestion queue; shorter = false positives during broker slow-write.

5. **Health `/healthz` degraded thresholds?** Suggest: `publish_rate == 0 for > 60s`, `unconfirmed_messages > 30s old`, `outbox_depth > 500MB`. Should these be per-tenant?

6. **Retry policy on confirm-nack?** Recommend: 3 in-process retries (200ms, 1s, 5s), then quarantine to disk-only outbox tier. What's the retry budget?

7. **Does the outbox live in the same container as edge-transformer, or as a sidecar?** Same container is simpler (single deploy unit); sidecar decouples buffering from processing. Recommend same container for start; can extract later if bottleneck.

8. **Chaos-test what?** Suggest scripted tests: (a) kill RabbitMQ mid-publish, (b) kill Mosquitto with retained NBIRTHs pending, (c) fill outbox disk to 95%, (d) sever the WAN. Each scenario has an expected observable outcome per this ADR's rules.

9. **What's the customer-facing SLA implication?** If we commit "no silent data loss after ingest into Packiot," we probably need to add a section to our customer-facing docs. Legal + PM should weigh in before we make this promise externally.

---

## References

- [ADR-0009](./0009-edge-transformer-go-service-and-nodered-split.md) — the reuse-rule discipline this ADR extends
- [ADR-0010](./0010-sparkplug-decode-in-go-end-state.md) — the OT/IT bridge this ADR draws its boundary at
- The Sparkplug B specification — QoS 0 for DATA, our starting-line reality
- RabbitMQ [Publisher Confirms](https://www.rabbitmq.com/confirms.html) documentation
- SQLite [WAL mode + crash consistency](https://www.sqlite.org/wal.html) — the outbox's storage engine
- Industry patterns:
  - Cirrus Link [MQTT Distributor Store & Forward](https://docs.chariot.io/display/CLD79/MQTT+Distributor+Store+%26+Forward)
  - AWS IoT Greengrass [Stream Manager](https://docs.aws.amazon.com/greengrass/v2/developerguide/stream-manager.html)
  - Ignition [Edge Store-and-Forward](https://docs.inductiveautomation.com/display/DOC81/Store+and+Forward)
- Session 72 discussion (2026-06-30) where the durability-left boundary was established
- The `shadowpub` package (PR #124) — the specific publisher this ADR requires publisher-confirms on

---

## Decision log

- **2026-06-30** — Initial draft during session 72 continuation. Status: Proposed (DRAFT).
- Awaiting team review. After review, Status → Accepted and Phase 1 work begins.
