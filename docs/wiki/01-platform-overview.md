# Platform Overview

## What Packiot is

Packiot is an **industrial IoT / OEE platform** for manufacturing. It connects factory
PLCs to a cloud analytics stack and answers one question: *"How efficiently is this
factory running?"* — tracking production orders, machine uptime/downtime, shift
schedules, and **OEE** (Overall Equipment Effectiveness = Quality × Availability ×
Performance).

## End-to-end data flow

```
PLC (factory floor)
  │  S7 / Modbus TCP / OPC-UA / native SparkPlug
  ▼
edge Node-RED / config-as-data reader   ── Tier 1: connectivity (per-client, messy)
  │  raw suffix tags (rawtag JSON) → POST ingest.<env>:8449/v1/tags   OR   native SparkPlug to MQTT
  ▼
sparkplug-agent (Go, SHARED multi-tenant)  ── Tier 2: transmission (uniform, protocol-rigid)
  │  one process, N tenants routed by SparkPlug group_id (one :8449 front-door for all)
  │  SparkPlug B over mTLS, ssl://…:8883   (alias/BIRTH/seq/outbox, per-tenant)
  ▼
cloud mosquitto ──▶ sparkplug-decoder (Go)   ── decode + normalize + Calc
  │  publishes normalized envelope to RabbitMQ (exchange `oee`, key `sparkplug.data`)
  ▼
stream-engine (Go)                          ── ingest half + OEE-compute half
  │  writes equipment_values, computes runtime rollups
  ▼
PostgreSQL + TimescaleDB (packiot_analytics)
  ▲                                            │
  │ HTTP writes (control)                      │ reads
edge-api (NestJS)                        refdata-api (Go)
  ▲                                            │
  │ CS-Admin / operator                        ▼
csadmin · operator                         front4 · operator
```

Two corrections that trip up newcomers (both verified in code):

1. **`sparkplug-decoder` does not write the database.** It decodes SparkPlug, resolves
   aliases, runs Calc, and **publishes to RabbitMQ**. The DB write is one hop
   downstream, in **`stream-engine`**.
2. **The OEE math is not in the database.** Post-ADR-0014 it was lifted out of the old
   `pg_cron` + PL/pgSQL engine into the Go worker (embedded SQL run on a job ticker).
   TimescaleDB now owns only *storage* (hypertables + continuous aggregates).

## Two axes to keep separate in your head

Packiot's backend has **two orthogonal splits**. Confusing them is the #1 source of
"where does this live?" confusion.

### Axis 1 — control plane vs data plane

| | Control plane | Data plane |
|---|---|---|
| **What** | tenant/hierarchy/config, PO lifecycle, shifts, `packml_register` | telemetry (`equipment_values`), events, OEE aggregates |
| **Who writes** | humans via edge-api (CS-Admin, operator) | `stream-engine` from the SparkPlug stream |
| **Storage** | ordinary Postgres tables + FKs | TimescaleDB hypertables + continuous aggregates |
| **Cadence** | small, mutable, hand-authored | high-volume, append + rollup |

### Axis 2 — the two database *planes* (`packiot` vs `packiot_analytics`)

The F1→F3 migration left the same logical schema in **two databases** on one cluster:

| Plane | DB | Role |
|---|---|---|
| **F1** (legacy) | `packiot` | The old oeecloud engine's DB. **No longer read/written by the live pipeline** since the 2026-08-16 cutover. |
| **F3** (live) | `packiot_analytics` (prod) / `packiot_shadow` (staging) | The refactored end-state: Go Calc, OEE math in the worker, TimescaleDB caggs. **This is where live telemetry + CS-Admin writes land today.** |

The flip was done at the **connection-string** level (`POSTGRES_DB` per service), not by
editing 100+ DAOs. `edge-api/src/providers/database/analytics-postgres-adapter.ts`
documents it. **Practical consequence:** when you inspect data, query the right plane —
csadmin/onboarding writes land in **`packiot_analytics`**, and the two planes have
drifted (columns added out-of-band on one). Never assume a column exists on both.

## The services at a glance

| Service | Lang | Role |
|---|---|---|
| **edge-api** | NestJS/TS | Control plane: hierarchy/PO/shift/downtime/register CRUD, onboarding descriptor, edge deploy dispatch, auth |
| **refdata-api** | Go | Read plane for front4 (the Hasura replacement); datasets + composable query |
| **sparkplug-decoder** | Go | Cloud SparkPlug decode + normalize + Calc → RabbitMQ |
| **sparkplug-agent** | Go | Factory-side Tier-2 transmission (raw tags → SparkPlug B/mTLS uplink) |
| **stream-engine** | Go | AMQP→Postgres ingest + the OEE compute engine |
| **csadmin** | React | Internal CS provisioning/onboarding tool |
| **front4** | React | Customer OEE product (Amplify) |
| **operator** | React | Factory-floor kiosk |

> **Service naming (a rename you will hit in the code — and where it deliberately *stops*).**
> The two Go data-plane services were renamed at the directory + compose-service level, but the
> old names were **intentionally preserved** at the observability/topology layer so live
> PromQL and queue bindings don't break. The result is a split you must hold in your head:
>
> | Layer | decode service | worker service | renamed? |
> |---|---|---|---|
> | **Directory** | `services/sparkplug-decoder/` | `services/stream-engine/` | ✅ new |
> | **Compose service** | `sparkplug-decoder` | `stream-engine` | ✅ new |
> | **Binary (`cmd/`)** | `cmd/edge-transformer/`, `cmd/sparkplug-agent/` | `cmd/oeecloud-worker/` | ❌ old (kept) |
> | **Prometheus job + host** | `edge-transformer:9102` | `oeecloud-worker:9101` | ❌ old (kept via compose alias) |
> | **RabbitMQ queue** | — | `oeecloud-worker-q` (`WORKER_QUEUE`) | ❌ old (kept) |
>
> The observability names are kept **on purpose**: `job="oeecloud-worker"` / `job="edge-transformer"`
> selectors are load-bearing in ~11 live Grafana dashboards, so compose keeps `oeecloud-worker:9101`
> and `edge-transformer:9102` as network aliases (see `monitoring/prometheus/prometheus.yml`, which
> documents the decision inline). On staging the *old directories* are gone (`services/oeecloud-worker/`
> = empty, `services/edge-transformer/` = one orphaned test). Rule of thumb: **new names for the
> service/dir, old names for the binary + metrics + queue.**

## Where to go next

- The hands-on flow for a new client → **[Onboarding a Client](02-onboarding.md)**
- The vocabulary (count_index, tp_equipment, OEE math) → **[Concepts](08-concepts.md)**
- Deep dives → **[Edge](04-edge-and-ingestion.md)** · **[Cloud/OEE](05-cloud-services-and-oee.md)** · **[Database](06-database.md)** · **[Infra/Auth](07-frontends-infra-auth.md)**
