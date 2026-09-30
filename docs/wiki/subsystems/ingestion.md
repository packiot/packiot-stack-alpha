---
title: Ingestion
layer: 2
owner_area: ingestion
last_verified: 2026-09-28
---
# Ingestion

> **Layer 2 · Subsystem** — how machine data gets from the cloud MQTT broker into the analytics
> DB's Bronze and Silver tables: brokers, the Sparkplug decoder, the HTTP shim, the sandbox fan-out
> and the stream-engine's ingest consumer. For anyone tracing a missing or wrong number back to its
> source. Up: [Architecture overview](../architecture/overview.md)

## Purpose

Ingestion receives production counters, machine state and PackML parameters from factory edges and
stores them, cleaned and keyed by equipment, in the analytics DB. It converts PLC totalizers into
per-sample **increments** (with guards against restarts, resets and impossible jumps), maps each
Sparkplug topic to an `id_equipment` through topic routing (`packml_register`), and writes one
immutable raw row (Bronze) and one merged row per equipment-second (Silver). It must never lose an
accepted message and never count a unit twice. Everything downstream (OEE, dashboards, historian)
reads what this subsystem writes.

This page describes the **new stack on staging**. Most production clients still run on the legacy
platform (edge Node-RED → Google Pub/Sub → oeecloud Node-RED → legacy DB); `compose.production.yml`
defines the same services for the new-stack production host.

## Boundaries

| Owns | Does not own |
|---|---|
| Cloud Mosquitto and RabbitMQ (topology, users, definitions) | Edge readers, sparkplug-agents, the edge box ([edge](edge.md)) |
| sparkplug-decoder: Sparkplug decode, counter math (Calc), outbox, publish | OEE rollups, events derivation, PO computation ([compute](compute.md)) |
| ingest-shim (HTTPS → AMQP) and oeecloud-fanout (CPACK → sandbox clone) | Continuous aggregates, retention, compression ([analytics DB](analytics-db.md)) |
| stream-engine's AMQP consumer and writers: Bronze append, Silver upsert, increment clamp, shift columns, per-sample event mint, PO lifecycle parameters | Legacy data replicated from packiot40 ([analytics-sync](../components/analytics-sync.md), [legacy bridge](legacy-bridge.md)) |
| Topic → equipment resolution at write time | Authoring `packml_register` (onboarding via csadmin / edge-api) |

## Components

| Component | What it does | Runtime | Layer-3 page |
|---|---|---|---|
| Mosquitto | MQTT broker for Sparkplug B inside the stack | `eclipse-mosquitto:2` | [Brokers](../components/brokers.md) |
| RabbitMQ | durable bus: exchange `oee`, per-tenant queues, retry/failed loop | `rabbitmq:3.13-management` | [Brokers](../components/brokers.md) |
| sparkplug-decoder | Sparkplug → increments → JSON envelope → `oee` | Go, container `sparkplug-decoder` | [sparkplug-decoder](../components/sparkplug-decoder.md) |
| ingest-shim | HTTPS JSON envelope → `oee` (Incoplast tee) | Go, container `ingest-shim` | [ingest-shim and fan-out](../components/ingest-shim-and-fanout.md) |
| oeecloud-fanout | clone CPACK envelopes as SBXCPACK (staging only) | Go, container `oeecloud-fanout` | [ingest-shim and fan-out](../components/ingest-shim-and-fanout.md) |
| stream-engine (ingest half) | consume, resolve, write Bronze/Silver | Go, container `stream-engine` | [stream-engine](../components/stream-engine.md#the-ingest-consumer) |

## How it works

```text
 edge publishers on staging                           cloud (staging app host)
 ┌───────────────────────────────┐
 │ sparkplug-agent-shared (HTTP  │  Sparkplug B
 │  front-door ← factory tees)   │  spBv1.0/<GROUP>/…     ┌───────────────────────────┐
 │ sparkplug-agent-cpack, plc-sim│ ─────────────────────▶ │ Mosquitto :1883           │
 │ bispharma-twin, s7-reader     │                        └────────────┬──────────────┘
 └───────────────────────────────┘                                     │ spBv1.0/#  QoS 0
                                                                       ▼
                                          ┌──────────────────────────────────────────────┐
                                          │ sparkplug-decoder                            │
                                          │ alias table ─▶ Calc (increments, guards)     │
                                          │ ─▶ SQLite outbox ─▶ publish (confirms)       │
                                          └────────────┬─────────────────────────────────┘
 Incoplast Node-RED tee ── HTTPS ─▶ ingest-shim ──┐     │ rk sparkplug.data.<tenant>
                                                  ▼     ▼
                                      ┌────────────────────────────┐   CPACK copy
                                      │ RabbitMQ exchange `oee`    │ ─────────────▶ oeecloud-fanout
                                      │ stream-engine-q-<tenant>   │ ◀── SBXCPACK ──┘
                                      └────────────┬───────────────┘
                                                   ▼
                     ┌──────────────────────────────────────┐
                     │ stream-engine consumer               │──▶ bronze.equipment_values_raw
                     │ resolve topic → id_equipment         │──▶ silver.equipment_values
                     │ (packml_register, cached)            │──▶ silver.equipment_events
                     │ clamp, shift columns, 1 batch / msg  │    (status_type 4 only)
                     └──────────────────────────────────────┘──▶ silver.equipment_live_metrics
```

1. **Publish.** An edge publisher sends Sparkplug B (NBIRTH once with aliases, then NDATA with values)
   under its group, for example `CPACK`. Real client data reaches the cloud through the sparkplug
   agents' HTTP front-door; `plc-sim` and the twins are staging simulators.
2. **Decode.** The decoder resolves aliases, and for every `Prod{Processed,Consumed,Defective}Count`
   runs Calc: first sample after a restart only seeds the baseline, resets reseed, 16-bit wraps count
   through, impossible jumps are clamped to a per-client margin, and a speed guard drops glitches.
   It emits `value` = increment and `counter` = absolute.
3. **Store and forward.** The envelope is written to a local SQLite outbox, then published to `oee`
   with routing key `sparkplug.data.<tenant>` and a broker confirm; the row is deleted on confirm.
4. **Route.** RabbitMQ delivers to `stream-engine-q-<tenant>`. The fan-out also copies CPACK to the
   sandbox tenant. Unroutable messages go to `oee-unroutable-q`.
5. **Write.** stream-engine resolves each metric's topic to an equipment, applies the increment sanity
   clamp, and in one batch appends Bronze and upserts Silver. Unregistered topics are skipped and
   counted. On a DB error the message is retried (30 s, up to 5 times) and then parked in a
   `-failed` queue.

After this, TimescaleDB continuous aggregates roll Silver into minute and hour buckets (analytics DB)
and the [compute](compute.md) jobs build OEE.

Typical latency on staging: 4–7 s from PLC to Silver (see
[A counter's journey](../architecture/data-journey.md)).

## Interfaces

| Direction | Protocol | Topic / queue / table / endpoint | Producer → consumer |
|---|---|---|---|
| in | MQTT 3.1.1, QoS 0 | `spBv1.0/<GROUP>/{N,D}{BIRTH,DATA,DEATH}/<node>[/<device>]` | agents, simulators → sparkplug-decoder |
| in | HTTPS | `POST /ingest/sparkplug` on ingest-shim `:8444` (`X-Ingest-Key`) | Incoplast tee → ingest-shim |
| internal | AMQP 0.9.1 | exchange `oee`, keys `sparkplug.data.<tenant>` / `sparkplug.data` | decoder, shim, fan-out → stream-engine |
| out | MQTT | `spBv1.0/<GROUP>/NCMD/<node>` Rebirth (off on staging) | decoder → edge node |
| out | SQL | `bronze.equipment_values_raw`, `bronze.equipment_events_raw` | stream-engine → analytics DB |
| out | SQL | `silver.equipment_values`, `silver.equipment_events`, `silver.equipment_live_metrics`, `silver.data_quality_event` | stream-engine → analytics DB |
| out | SQL | `core.production_orders`, `gold.production_orders_runtime`, `silver.equipment_live_job`, `identity.user_logs` (PO lifecycle parameters) | stream-engine → analytics DB |
| lookup | SQL | `packml_register` (view over `core.topic_routing`), `equipments`, `areas`, `sites`, `shift_hours`, `client_descriptors` | analytics DB → decoder / stream-engine |

## Data it owns

| Data | Where | Lifecycle |
|---|---|---|
| Retained Sparkplug births | Mosquitto volume `mosquitto-data` | until replaced; clients expire after 1 h offline |
| Per-counter baselines, alias tables | decoder memory | lost on restart; reseeded by the first sample / next birth |
| Undelivered envelopes | decoder SQLite outbox, volume `edge_transformer_outbox` | deleted on broker confirm; capped at 100 000 rows (oldest dropped) |
| In-flight messages | RabbitMQ queues (durable, persistent) | until acked; `-failed` and `oee-unroutable-q` until purged |
| Raw samples | `bronze.equipment_values_raw`, `bronze.equipment_events_raw` | append-only (no-mutate trigger); retention set in the analytics DB |
| Clean facts | `silver.equipment_values` (unique `(ts_value, id_equipment)`) | raw telemetry is cut after ~90 days; history moves to the [historian](historian.md) |

Retention and compression policies are owned by the analytics DB; see
[Timescale jobs & retention](../components/timescale-jobs-and-retention.md).

## Configuration that matters

| Knob | Service | Staging | Why it matters |
|---|---|---|---|
| `WORKER_TENANT_ALLOWLIST` | stream-engine | `cpack,sbxcpack,bispharmastaging` | a tenant not listed has no queue; its data goes to `oee-unroutable-q` |
| `packml_register` active rows | analytics DB | per tenant | a topic with no active row is skipped at write |
| `F3_PER_TENANT_ROUTING` | decoder | `true` | per-tenant routing keys (needs `LEGACY_INGEST_ENABLED=true` on stream-engine to consume them) |
| `CALC_CUTOVER_REFACTORED`, `USE_GO_PORT` | decoder | `true` | emit increments, not raw totalizers |
| `CALC_COUNTER_SPIKE_MARGIN`, `OEE_PROFILE_FROM_DB` | decoder | `10`, `true` | spike clamp; per-client override from the OEE profile |
| `CALC_NO_SPEED_GUARD_FALLBACK`, `COUNTERS_ONLY_*` | decoder | on | machines without a speed sensor still produce counts |
| `PHASE9_LINE_AGG_ENABLED` | decoder | `true` | line-level counts derived from members (only with no other line writer) |
| `INCREMENT_SANITY_CLAMP_*` | stream-engine | on, fraction 0.5 | last guard before Silver |
| `BRONZE_RAW_APPEND` | stream-engine | `true` | Bronze landing zone |
| `COMPOSE_PROFILES` | host `.env` | not in git | which edge publishers run (`plc-sim` vs `cpack-tee` must never both run) |

## Failure modes & signals

| What breaks | How you notice | Where to look |
|---|---|---|
| Publisher stops / network to the box down | `IngestSilent`, `ClientIngestStopped`; `edge_transformer_mqtt_received_total` flat | agent / edge ([edge](edge.md)), `MQTTDisconnected` |
| Decoder publishes nothing | `outbox_depth` rising, `TransformerOutboxStale`; 09-25 case: healthy but silent | decoder logs, RabbitMQ health |
| Topic not registered | `PackmlUnroutableTopic` (`packml_unresolved_topic_total{tenant}`) | `packml_register` rows for the tenant |
| Tenant not allowlisted | `OeeUnroutableMessages` | `WORKER_TENANT_ALLOWLIST` |
| DB write errors | `BatchWriteErrors`, messages in `stream-engine-q-<t>-failed` | stream-engine logs `handler error, nacked to retry` |
| Double source (two publishers, same group) | production ~2× or huge spikes; `INVARIANT_CLAMPED_INCREMENT` events | active compose profiles, Sparkplug edge node ids in decoder logs |
| Counter spikes after restarts / resets | `incr == val` rows; clamp events | decoder reset-heal / first-observation seed, stream-engine clamp |
| Sequence gaps | `SparkplugSeqGapStream` | network between agent and broker |

## History & decisions

| When | Decision / incident |
|---|---|
| ADR-0010 | Decode Sparkplug in Go (the decoder) instead of Node-RED ([ADR-0010](../adr/0010-sparkplug-decode-in-go-end-state.md)) |
| ADR-0011 | Durability boundary: persistent births, outbox, confirms, visible drops ([ADR-0011](../adr/0011-durability-boundary-and-store-and-forward.md)) |
| ADR-0012 / ADR-0032 | Refactored analytics DB; collapse the three shadow flows to one (F3) ([ADR-0012](../adr/0012-schema-refactor-and-multitenancy-pool.md), [ADR-0032](../adr/0032-collapse-to-single-flow-f3.md)) |
| ADR-0036 | Medallion layers: Bronze append-only, Silver invariants ([ADR-0036](../adr/0036-data-architecture-medallion.md)) |
| ADR-0037 / ADR-0049 | OEE correctness: increment clamp, reset heal, no-speed fallback ([ADR-0037](../adr/0037-oee-correctness-remediation.md), [ADR-0049](../adr/0049-oee-correctness.md)) |
| ADR-0051 | `packml_register` is generated; unroutable topics must alert ([ADR-0051](../adr/0051-packml-register-generated-only-and-unroutable-alerting.md)) |
| ADR-0053 / ADR-0058 | On-prem decode for outages; per-client customization (edge derive, OEE profile) ([ADR-0053](../adr/0053-on-prem-ingest-edge-for-outage-autonomy.md), [ADR-0058](../adr/0058-client-customization-capability.md)) |
| 2026-07-10 | Broker recreate lost the least-privilege users → `load_definitions` |
| 2026-07-14 | Two writers for line counts (#456) → Phase 9 suppressed unless explicitly enabled |
| 2026-08-11 | First-boot delta-from-zero spike → first-observation seed |
| 2026-08-19, 2026-09-14 | Queue sprawl → `WORKER_TENANT_ALLOWLIST` |
| 2026-09-25 | Definitions file lost on reboot; decoder silent after starting before RabbitMQ (#1447) |
| 2026-09-25/27 | Synthetic writers on real CPACK L5 topics (#1460); spike-guard window bug (#1462) |

## Go deeper

- [Brokers](../components/brokers.md) — Mosquitto and RabbitMQ topology, users, retry loop
- [sparkplug-decoder](../components/sparkplug-decoder.md) — Calc decision tree, outbox, env
- [ingest-shim and oeecloud-fanout](../components/ingest-shim-and-fanout.md)
- [stream-engine](../components/stream-engine.md) — consumer, writers, clamp
- [Analytics DB](analytics-db.md) and [analytics DB schemas](../components/analytics-db-schemas.md) — where Bronze and Silver live
- [Compute](compute.md) — what happens after Silver
