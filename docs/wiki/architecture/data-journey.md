---
title: A counter's journey
layer: 1
owner_area: platform
last_verified: 2026-09-28
---
# A counter's journey, from PLC to dashboard

> **Layer 1 · Architecture.** One production counter followed through every hop of the new
> stack, with what happens at each hop, where it is stored, and how fresh it is.
> Up: [Architecture overview](overview.md)

We follow CPACK line **L5**'s output machine **L5-TEXA** as it packs units. Its PLC keeps a
running total (a *totalizer*) of processed units in a register.

```text
 PLC ─▶ reader ─HTTPS─▶ sparkplug-agent ─▶ mosquitto ─▶ sparkplug-decoder ─▶ RabbitMQ
(total) (poll, /v1/tags  (Sparkplug DDATA)  (MQTT)     (value → increment,  (durable)
         box)            (cloud, shared)               spike guard)            │
                                                                               ▼
 front4 ◀─ read-api ◀─ serving.* ◀─ gold grains ◀─ rollup jobs ◀─ silver ◀─ stream-engine
 (dashboard) (HTTP)   (SQL fns)   (hour/shift/…)  (stream-engine)  facts     writers (topic →
                                                                             equipment)
```

## Hop by hop

| # | Hop | What happens | Where it lives after | Freshness (staging, measured 2026-09-28) |
|---|---|---|---|---|
| 1 | **PLC → reader** | A reader on the edge box (S7, Modbus or OPC-UA) polls the register and reads the totalizer value, e.g. `ProdProcessedCount = 1,833,407`. | reader memory | poll interval |
| 2 | **reader → sparkplug-agent** | The reader POSTs the raw tag to the cloud's shared, multi-tenant Sparkplug agent (`POST /v1/tags` via the `ingest.staging…:8449` / `cpack-ingest.staging…:8447` HTTPS front doors), spooling to disk while the uplink is down. The agent maps it to a Sparkplug B metric named after the PackML path (`…/L5/TEXA/Admin/ProdProcessedCount/65/Unit`), keeps the birth/death session and an outbox, and publishes to mosquitto. (Alternative shape: the agent runs on the box and publishes over mTLS MQTT; see [Edge](../subsystems/edge.md#how-it-works).) | agent outbox → MQTT | seconds |
| 3 | **mosquitto → sparkplug-decoder** | The decoder parses the Sparkplug payload and runs the counter state machine (`calc_production_counters`): it turns the totalizer into an **increment** since the last reading, with first-observation seeding, reset/rollover healing, TRIG suffix semantics and a per-counter spike guard. It writes the result to a durable **outbox**, then publishes to RabbitMQ per tenant. | decoder outbox | < 1 s |
| 4 | **RabbitMQ → stream-engine writers** | The stream-engine consumes the tenant queue, **resolves the topic to an equipment** (`internal/sparkplug/resolver.go`, via topic routing / `packml_register`; unregistered topics are counted and skipped), resolves the shift, and writes the raw envelope to **bronze** (`bronze.equipment_values_raw`) and the cleaned fact to **silver** (`silver.equipment_values`, unique on `(ts_value, id_equipment)`). Counter *roles* per line (which machine is gross or net) are applied later, in the rollups. | analytics DB | 4–7 s behind the PLC |
| 5 | **silver → continuous aggregates** | TimescaleDB caggs roll silver into per-minute and per-hour buckets (`silver.equipment_categorical_1min`, `…_1hour`) with increments, speed and state. | caggs | 1-min < 10 s; 1-hour at bucket close |
| 6 | **caggs → gold (rollup jobs)** | stream-engine jobs compute the OEE grains. For a line like L5 the *line-lead* step takes gross from the infeed (BREYER), net from the outfeed (TEXA), availability from count activity, subtracts planned stops, and writes `gold.equipment_oee_hourly` and `gold.equipment_oee_shift`; day/week/month cascade from there. | gold | hour row ~1 min; current shift ~2 min |
| 7 | **gold → serving → read-api** | `read-api` calls `serving.*` functions/views that shape gold (and silver for live status) for each screen, with the caller's tenant already fixed. Long ranges are served by the historian. | HTTP JSON | per request (cached where configured) |
| 8 | **read-api → front4 / operator** | Mission Control, dashboards and the operator app render it. | browser | polling interval of the screen |

## What can change the number after it lands

- **Late or corrected data.** A late message re-flags its hour and shift (`recalc_needed`) and
  the next tick recomputes them. Shift rows in the last 12 hours are recomputed every tick.
- **Operator actions.** Justifying a stop, splitting a downtime, or starting a production order
  goes through `edge-api` → the analytics DB; the next rollup tick uses it.
- **Legacy replication.** For CPACK, production orders and operator actions made in the legacy
  apps arrive through [analytics-sync](../components/analytics-sync.md).
- **Repairs.** A code fix is applied to history by re-flagging and recomputing; see
  [stream-engine rollup internals](../components/stream-engine-rollup-internals.md).

## Where each representation is kept

| Representation | Table (analytics DB) | Kept |
|---|---|---|
| Raw envelope | `bronze.equipment_values_raw` | 90 days, compressed after 7 |
| Clean fact | `silver.equipment_values` | ~90 days (raw telemetry is cut; history moves to the historian) |
| Minute / hour buckets | `silver.equipment_categorical_1min` / `_1hour` | same horizon as silver |
| OEE grains | `gold.equipment_oee_hourly`, `_shift`, `_daily`, `_weekly`, `_monthly` | kept (compact) |
| Long history | historian: `live.*` (FDW to analytics) ∪ `cold.*` (S3 Parquet, 2021 →) | indefinitely |

Details: [Analytics DB](../subsystems/analytics-db.md) · [Historian](../subsystems/historian.md) ·
[Timescale jobs & retention](../components/timescale-jobs-and-retention.md).
