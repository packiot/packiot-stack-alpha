# ADR 0001 — Edge persistence for soft-real-time PLC data under intermittent connectivity

**Status:** Proposed
**Date:** 2026-06-29
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team

---

## Context

### The constraint

Industrial production runs continuously. PLCs emit data at sub-second cadence (SparkPlug B over MQTT). The platform must:

- **Capture every PLC event durably.** Sub-second loss during a process restart is acceptable; *minutes* of loss are not — OEE numbers become wrong.
- **Serve a soft-real-time operator UI.** ~1-minute freshness on the operator screens is the bar; the operator decides when to justify a downtime in near real time.
- **Keep working when the factory loses internet.** Factory uplinks are not reliable; outages of minutes to hours are routine.
- **Sync everything to cloud once the link returns.** Cross-site analytics, customer dashboards, and ML pipelines all run on cloud-aggregated data.

Crucially, these are independent failure domains. Customers don't accept "production tracking went dark because the office had an internet outage."

### The gap today

Current edge architecture:

```
PLC ─[SparkPlug B / MQTT]─▶ edge-node-red (factory PC)
                                  │
                                  ├──▶ Google Cloud PubSub      ← FAILS during uplink loss
                                  ├──▶ edge-api (HTTPS, cloud)  ← FAILS during uplink loss
                                  └──▶ Node-RED flow context    ← LOCAL, kind of persists
```

There is **no purpose-built local persistent store for raw PLC data**. Offline tolerance is implicit and partial:

- Node-RED MQTT input node buffers in memory (small, configurable, lost on process restart)
- PubSub output node has built-in retry but no on-disk queue by default
- Node-RED flow context can persist to disk *if you opt in* (file-based context store)
- Operator UI reads from flow context — sees only what's there, not full PLC history

During an outage, the failure modes are:

| Outcome | Status today |
|---|---|
| Operator can see last-known state | ✅ (from Node-RED context) |
| Raw PLC metrics durably persisted | ⚠️ partial; lost on Node-RED restart |
| Operator actions queued for replay | ⚠️ partial; lives in flow context |
| OEE recomputable locally | ❌ (all OEE math lives in cloud TimescaleDB triggers + caggs) |
| Clean catch-up on reconnect | ⚠️ implicit (Node-RED retries) |

### Why this matters now

Two pressures forcing the question:

1. The **real client data initiative** is bringing more sites online with varying connectivity quality.
2. The recent **mirror-worker / staging-parity** work has surfaced how much business logic implicitly lives in Node-RED context rather than in a queryable store. As staging gets more accurate to prod, the gaps in offline behavior become more visible.

---

## Decision

Adopt the **local-TimescaleDB-on-edge** pattern: each factory PC runs a TimescaleDB container as the canonical persistent store for raw metrics + computed local state. `edge-node-red` writes there first. Cloud sync is a separate, retry-able process via PostgreSQL **logical replication**.

### Target architecture

```
PLC ─[SparkPlug B / MQTT]─▶ Local MQTT broker
                                    │
                                    ▼
                            edge-node-red (factory PC)
                                    │
                                    ├──▶ Local TimescaleDB ──[logical replication]──▶ Cloud TimescaleDB
                                    │           │                                            │
                                    │           ▼                                            ▼
                                    │   Local operator UI                        Cloud Hasura / oeecloud
                                    │     (queries local DB)                       (analytics, cross-site)
                                    │
                                    └──▶ edge-api (cloud) ── only when online (control plane, mutations)
```

### Key properties

- **Two independent failure domains.** PLC ingestion (edge) and cloud sync (network) fail separately. An internet outage stops sync but not ingestion.
- **Schema parity end-to-end.** Same TimescaleDB engine + same DDL + same triggers + same continuous aggregates on edge and cloud. Zero translation layer.
- **Replication is a solved problem.** PostgreSQL logical replication handles queueing-during-disconnect and apply-on-reconnect natively. We don't write the catch-up logic.
- **Reversible per-site.** Sites with reliable uplinks can skip the local DB; sites with bad connectivity get it. Same codebase, runtime toggle on the factory PC's compose file.
- **Operator queries become real SQL.** No more "POST `/production` into a Node-RED flow that does a SELECT internally" — the operator UI hits a thin read API (or direct read replica) against the local DB.

---

## Consequences

### Positive

- Raw PLC data is **durably persisted before any cloud sync attempt**. Outages don't cause data loss.
- Operator UI can **compute fresh OEE locally during outages** — the OEE math is in triggers + caggs that run wherever the DB runs.
- Cloud sync becomes a separate concern from ingestion, **with native postgres tooling for the queue-and-replay**. We inherit decades of operational maturity from logical replication.
- Operator-facing endpoints move toward **real SQL queries** instead of POST-shaped Node-RED flow endpoints — clears the architectural smell discovered during the 2026-06-29 Redis exploration.
- Sets up the **long-term modernization path** (operator → PWA with IndexedDB) as a layered addition, not a rewrite.

### Negative

- **Operational complexity per site.** Each factory PC runs a TimescaleDB container with its own backups, vacuum, monitoring, and security posture.
- **Hardware cost.** A few GB RAM per factory PC for the DB + WAL + work_mem. Most modern factory PCs have this; some legacy ones may not.
- **Onboarding cost per site.** Each new factory requires DB provisioning, replication setup, monitoring agent install. Today, onboarding is mostly "deploy a Node-RED container."
- **Conflict semantics.** If both edge and cloud accept mutations during/after an outage (e.g., a remote CS engineer edits a downtime on cloud while the factory operator edits the same one locally), conflict resolution must be **explicit**. This is the hardest part of the design and is flagged as an open question, not solved by this ADR.

### Mitigations

- **Codify edge-stack provisioning in IaC.** Extend the `packiot-stack` repo with an `edge/` subdirectory + compose file. Same shape as current cloud-stack provisioning; one-command site install.
- **Monitoring agent reuses the existing cloud observability stack.** Same Prometheus exporters; per-site scrape config in the cloud Prometheus.
- **Per-site rollout, not big-bang.** Pilot on one site, observe under simulated outage, iterate, then expand. Sites without the local DB continue working on the current architecture indefinitely.

---

## Alternatives considered

### A. Status quo — Node-RED context store + in-memory buffering

- ✅ Zero migration cost; works today for sites with stable uplinks
- ❌ Not durable; Node-RED restart during an outage = lost data
- ❌ No SQL queryability; operator features locked into Node-RED flow code
- ❌ Implicit conflict resolution; bugs only surface under outage conditions that are hard to reproduce in CI

**Why not chosen:** Doesn't meet the "soft-real-time data must persist" bar. The current architecture works *well enough* for good uplinks but is structurally fragile for the cases this ADR exists to address.

### B. Industrial historian on the edge (AVEVA PI, GE Proficy, Wonderware)

- ✅ Battle-tested in factory environments since the 1990s
- ✅ Operations teams in industry already know how to run them
- ❌ Proprietary, expensive (per-tag pricing), vendor lock-in
- ❌ Schema doesn't match cloud TimescaleDB; sync requires a custom translation layer
- ❌ Limits Packiot's product surface to what the historian exposes

**Why not chosen:** Wrong cost profile for Packiot's scale. Ties us to a vendor whose pricing model penalizes growth.

### C. Apache Kafka / Redpanda at the edge

- ✅ Best-in-class durability + replication; designed for exactly this pattern
- ✅ Mature replication to cloud Kafka via MirrorMaker
- ❌ Heavy: brokers + topic management; operationally complex per site (especially Kafka with ZooKeeper / KRaft)
- ❌ Not a queryable store — operator UI still needs a separate database
- ❌ Adds a layer without removing one; we'd run Kafka *and* TimescaleDB at the edge

**Why not chosen:** Adds infrastructure without addressing the operator UI's query needs. Streaming is the wrong abstraction for "show me current OEE."

### D. SQLite + WAL + filesystem rsync

- ✅ Smallest possible footprint; zero admin overhead
- ✅ Reliable for write-heavy workloads under WAL (well-known pattern)
- ❌ Not a time-series database; aggregation queries scale poorly past a few months
- ❌ Sync to cloud TimescaleDB requires a custom CDC pipeline (no native equivalent of logical replication)
- ❌ SQLite's WAL doesn't survive `docker cp`-style backups cleanly ([known trap](../../zettel/systems/sqlite-wal-docker-cp-corruption.md))

**Why not chosen:** Doesn't compose cleanly with the existing TimescaleDB-centric cloud stack. Sync correctness becomes our problem.

### E. AWS IoT Greengrass / Azure IoT Edge

- ✅ Managed offering with persistent local message store, lambda-style local compute, secure cloud sync
- ✅ Strong identity + secrets management for edge devices baked in
- ❌ Vendor lock-in (AWS or Azure)
- ❌ Steep onboarding cost; rearchitects how edge logic is written
- ❌ Most managed-edge offerings assume IoT-device scale (single-tenant per device), not factory-PC scale (multi-line, shared infrastructure)

**Why not chosen:** Trades open-source flexibility for managed convenience. Not aligned with Packiot's current "open Postgres + Node-RED" philosophy. Worth revisiting if the team ever decides to fully embrace a cloud provider's IoT stack.

### F. Full operator-side PWA + IndexedDB + Background Sync

- ✅ Best modern web standard for offline-first UX
- ✅ No edge-side data store needed for the operator UI
- ❌ Operator running in a browser cannot ingest PLC SparkPlug data — still need *something* on the factory PC to handle MQTT
- ❌ Massive operator-app rewrite; new offline-aware UI states throughout
- ❌ IndexedDB is per-browser-per-machine; doesn't help if a different operator logs in on a different terminal

**Why not chosen as the primary fix:** Addresses operator UI offline UX but does NOT address the PLC durability problem (the harder + more important constraint). Worth pursuing as a **layered addition** on top of this ADR — once the edge DB is in place, a PWA-style operator can read from it locally with IndexedDB as an additional resilience layer.

---

## Implementation phases

Phased rollout, each phase shippable independently. Earlier phases prove value + de-risk later phases.

| Phase | Scope | Est. effort | Risk |
|---|---|---|---|
| **0 — Design + ADR** | This document; team review; alignment on direction | Done (~1 day) | N/A |
| **1 — Pilot site, ingestion-only** | Deploy local TimescaleDB on one factory PC; edge-node-red writes there; cloud sync via logical replication; cloud TimescaleDB remains source of truth for ALL operator reads | 2–3 weeks | Low (parallel to current path; no cutover) |
| **2 — Operator reads from local DB** | Switch operator UI to query local DB during normal ops; fall back to cloud only for data older than local retention window | 4–6 weeks | Medium (operator UI changes, requires testing under simulated outage) |
| **3 — Operator actions persist locally** | Operator-driven mutations (event-justify, PO-start, etc.) write to local DB first, replicate to cloud. Define explicit conflict resolution for the rare case of bidirectional edits | 6–8 weeks | **High** (semantic correctness of conflict resolution; needs careful design + testing) |
| **4 — Full migration of remaining sites** | Roll out per-site based on uplink quality + customer agreement | Ongoing | Low (proven by phases 1–3) |

---

## Open questions

These need answers before phase 3, and *may* alter the design. Some are out of scope for this ADR and should get their own ADRs.

1. **Conflict resolution semantics.** When both edge and cloud accept mutations during/after an outage, who wins? Likely "last-write-wins with operator alert," but the alert UX needs design.
2. **Retention policy on edge.** How much history does the local DB keep before pruning? Probably tied to per-site outage tolerance + disk capacity. Cloud is the long-term archive.
3. **Operator UI fallback signaling.** How does the operator know "you're looking at cached data, last sync was X minutes ago"? Affects every operator screen.
4. **Edge monitoring.** Extend cloud Grafana + Prometheus to scrape every edge site? Or per-site local dashboards? Trade-off: operational visibility vs network dependency.
5. **Bootstrap of a new site.** Initial snapshot of cloud → edge for site-specific config (equipment list, packml_register, shifts). Doable via `pg_dump | psql` on first install.
6. **Security at the edge.** Local TimescaleDB exposed only on factory LAN, but credentials + IAM rotation story needs to match the cloud's. Defer to a security ADR.
7. **Migration path for already-deployed Node-RED-only sites.** Phase 1 + 2 deploy in parallel, but eventually the Node-RED context store has to be decommissioned per site. Migration semantics need definition.

---

## References

External:
- [Martin Kleppmann — Local-first software](https://www.inkandswitch.com/local-first/) — the canonical essay on offline-first design philosophy
- [PostgreSQL Logical Replication docs](https://www.postgresql.org/docs/current/logical-replication.html) — the sync mechanism this ADR depends on
- [TimescaleDB hypertable replication patterns](https://docs.timescale.com/) — TimescaleDB-specific guidance
- [AWS IoT Greengrass v2 architecture overview](https://docs.aws.amazon.com/greengrass/v2/developerguide/what-is-iot-greengrass.html) — comparison reference

Internal:
- `~/notes/systems/timescaledb-continuous-aggregates.md` — current cloud OEE pipeline; what we replicate edge → cloud
- `~/notes/systems/audit-log-replay-vs-shadow-mirror.md` — related pattern from the mirror-worker work
- `CLAUDE.md` (repo root) — current data flow + repo map; the architecture this ADR proposes to evolve
- `services/mirror-worker-go/docs/reconciler.md` — the multi-pass reconciliation pattern; potentially reusable shape for edge → cloud catch-up logic
