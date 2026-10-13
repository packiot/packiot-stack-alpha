---
title: A counter's journey
layer: 1
owner_area: platform
last_verified: 2026-10-13
---
# A counter's journey, from PLC to dashboard

> **Layer 1 · Architecture.** One production counter followed through every hop of the new
> stack on staging, with what happens at each hop, where it is stored, and how fresh it is.
> Up: [Architecture overview](overview.md)

We follow CPACK line **L5**'s output machine **L5-TEXA** as it packs units. Its PLC keeps a
running total (a *totalizer*) of processed units in a register.

```text
 PLC ─▶ factory ─HTTPS─▶ sparkplug-agent ─▶ mosquitto ─▶ sparkplug-decoder ─▶ RabbitMQ
(total)  reader   raw     -shared          (MQTT)       (total → increment,  exchange `oee`
                  tags    (Sparkplug B)                  outbox)               │
                                                                               ▼
 front4 ◀─ read-api ◀─ serving.* ◀─ gold grains ◀─ rollup jobs ◀─ silver ◀─ stream-engine
 (screen)  (HTTP)     (SQL fns)    (hour/shift/…)  (stream-engine) facts    writers (topic
                                                                            → equipment)
```

## Hop by hop

| # | Hop | What happens | Where it lives after | Freshness (staging, measured 2026-09-28) |
|---|---|---|---|---|
| 1 | **PLC → factory reader** | Something at the factory reads the totalizer, e.g. `ProdProcessedCount = 1,833,407`. For CPACK that is its factory Node-RED (the legacy edge, which also still feeds production); for Bispharma it is the generated thin reader on the edge box. | reader memory | poll interval |
| 2 | **reader → sparkplug-agent-shared** | The reader POSTs raw tags over HTTPS to the cloud's multi-tenant agent. CPACK posts to `https://cpack-ingest.staging.packiot.app:8447/v2/tags`, where nginx injects `X-Ingest-Group: CPACK` (`/v1/tags` on that port is blackholed); other boxes post to `https://ingest.staging.packiot.app:8449/v1/tags`. A thin reader spools to disk while the uplink is down. The agent maps the tag to a Sparkplug B metric named after its PackML path (`…/L5/TEXA/Admin/ProdProcessedCount/…`), keeps the birth/death session, writes an outbox and publishes to mosquitto. (Other shape: the agent runs on the box and publishes over mTLS MQTT; see [Edge](../subsystems/edge.md#how-it-works).) | agent outbox → MQTT | seconds |
| 3 | **mosquitto → sparkplug-decoder** | The decoder parses the Sparkplug payload and runs the counter state machine (Calc): it turns the totalizer into an **increment** since the last reading, seeding the first observation and re-seeding after a counter reset. The envelope and the updated counter baseline are written to the SQLite **outbox** in one transaction (`CALC_STATE_DURABLE`, default on since 2026-10-09), so a restart loses no delta. It then publishes to RabbitMQ exchange `oee` with routing key `sparkplug.data.<tenant>`. | decoder outbox | < 1 s |
| 4 | **RabbitMQ → stream-engine writers** | stream-engine consumes the tenant queue `stream-engine-q-cpack`, **resolves the topic to an equipment** (`internal/sparkplug/resolver.go`, via `packml_register`; unregistered topics are counted and skipped), rejects phantom increments (increment sanity check, recorded as a data-quality event), resolves the shift, and in one batch appends the raw envelope to `bronze.equipment_values_raw` and upserts the fact into `silver.equipment_values` (unique on `(ts_value, id_equipment)`). Counter *roles* per line (which machine is gross or net) are applied later, in the rollups. | analytics DB | 4–7 s behind the PLC |
| 5 | **silver → continuous aggregates** | TimescaleDB caggs roll silver into per-minute and per-hour buckets (`silver.equipment_categorical_1min`, `…_1hour`) with increments, speed and state. | caggs | 1-min < 10 s; 1-hour at bucket close |
| 6 | **caggs → gold (rollup jobs)** | stream-engine jobs compute the OEE grains every minute. For L5 the *line-lead* step takes gross from the infeed (BREYER), net from the outfeed (TEXA), running time from the lead machine's count activity, removes planned stops and no-data time, and writes `gold.equipment_oee_hourly` and `gold.equipment_oee_shift`; day/week/month cascade from there. | gold | hour row ~1 min; current shift ~2 min |
| 7 | **gold → serving → read-api** | `read-api` calls `serving.*` functions/views that shape gold (and silver for live status) per screen, with the caller's tenant fixed server-side. Long ranges read the historian. | HTTP JSON | per request |
| 8 | **read-api → front4 / operator** | Mission Control, dashboards and the operator app render it. | browser | the screen's polling interval |

## What can change the number after it lands

- **Late or corrected data.** A late message re-flags its hour and shift (`recalc_needed`).
  Every tick re-flags the recent band itself: hours of the last 65 minutes and shifts in
  `[now − 12 h, now + 18 h)`. Older flagged hours are drained by the hour backfill (up to
  10 days back); older shifts by the shift rollup (up to 30 days back).
- **Operator actions.** Justifying a stop, splitting a downtime or starting a production order
  goes through `edge-api` into the analytics DB, and the next tick uses it. **CPACK on staging
  is the exception:** enterprise 3 mirrors legacy, so edge-api refuses its PO, downtime and
  shift writes with `403 MIRROR_TENANT_WRITE_BLOCKED` (`OPERATOR_WRITE_BLOCKED_ENTERPRISES=3`,
  since 2026-10-09); CPACK's orders and operator actions arrive from legacy through the
  [legacy bridge](../subsystems/legacy-bridge.md).
- **Repairs.** A code fix is applied to history by re-flagging and recomputing; see
  [stream-engine rollup internals](../components/stream-engine-rollup-internals.md).

## Where each representation is kept

Retention is a catalog in the analytics DB (`ops.retention_policy`, migration
`t-retention-catalog`); these are its staging values.

| Representation | Table (analytics DB) | Kept |
|---|---|---|
| Raw envelope | `bronze.equipment_values_raw` | 90 days |
| Clean fact | `silver.equipment_values` | 90 days; a daily cold copy goes to the historian |
| Minute buckets | `silver.equipment_categorical_1min` | 90 days |
| Hour buckets | `silver.equipment_categorical_1hour` | 13 months |
| OEE grains | `gold.equipment_oee_hourly` 13 months; `_shift`, `_daily`, `_weekly`, `_monthly` | no limit (compact) |
| Downtime events | `silver.equipment_events` | 5 years |
| Long history | historian: live data (FDW to the analytics DB) ∪ cold S3 Parquet, 2021 → | indefinitely |

Details: [Analytics DB](../subsystems/analytics-db.md) · [Historian](../subsystems/historian.md) ·
[Timescale jobs & retention](../components/timescale-jobs-and-retention.md).
