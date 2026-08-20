# 2 — Architecture at a Glance

Before we walk through the pieces one at a time, here is the whole thing on one
page. Everything in the later chapters is a zoom-in on part of this picture.

## The data path, end to end

```
  FACTORY FLOOR                          CLOUD
  ┌───────────┐   SparkPlug B     ┌──────────────────┐   AMQP    ┌──────────────────┐
  │    PLC    │──── over MQTT ───▶│  edge-transformer │──────────▶│  RabbitMQ (bus)  │
  │ (machine) │                   │      (Go)         │           └────────┬─────────┘
  └───────────┘                   │ decode · normalize│                    │
        │                         │ calc · buffer     │                    ▼
        │                         └──────────────────┘           ┌──────────────────┐
        ▼                                  ▲                      │ oeecloud-worker  │
  ┌───────────┐                            │ consumes             │      (Go)        │
  │ edge      │────────────────────────────┘ for local            │ ingest writers + │
  │ Node-RED  │  operator screens + per-customer customization    │ ~13 engine jobs  │
  │ (minimal) │                                                   │ (the OEE math)   │
  └───────────┘                                                   └────────┬─────────┘
                                                                           │ writes
                                                                           ▼
  ┌─────────────────────────────────────────────────────────────────────────────────┐
  │  PostgreSQL + TimescaleDB   —   raw telemetry → time-bucket aggregates →          │
  │                                 business windows (OEE per PO, per shift) → caches │
  └─────────────────────────────────────────────────────────────────────────────────┘
        ▲                                   ▲                              ▲
        │ writes (PO control, downtimes)    │ reads                        │ reads
  ┌───────────┐                       ┌──────────────┐              ┌──────────────┐
  │  edge-api │                       │ refdata-api  │              │  the cloud   │
  │ (NestJS)  │                       │    (Go)      │              │  product UI  │
  └─────▲─────┘                       └──────▲───────┘              └──────────────┘
        │                                    │
        └────────── operator SPA (React) ────┘
            the factory-floor screen: writes actions, reads state
```

Read it as a loop, not a line. Machine data flows **up** the left side (floor to
database). People act on the system from the **bottom** (operators and product
users). The database in the middle is where the two meet: data lands, OEE is
computed, and everyone reads the result.

## The cast

Nine components do the work. Here is each in one sentence; each gets a full chapter
or section later.

| Component | Language | One-sentence job |
|-----------|----------|------------------|
| **PLC** | — | The machine's controller; emits raw signals (counts, speed, state). |
| **edge Node-RED** | Node-RED | The *minimal* on-site flow: connects to the PLC, and hosts space for per-customer customization. |
| **edge-transformer** | Go | Decodes the machine's SparkPlug protocol, normalizes and calculates, buffers durably, and publishes to the bus. |
| **RabbitMQ** | — | The message bus; the single contract between ingestion and processing. |
| **oeecloud-worker** | Go | The engine: consumes messages, writes raw data, and runs the ~13 scheduled jobs that compute OEE. |
| **PostgreSQL + TimescaleDB** | SQL | Durable storage, time-series compression, and the OEE aggregates. |
| **edge-api** | NestJS | The control plane: operator and admin *actions* (start a PO, justify a downtime). |
| **refdata-api** | Go | The read plane: serves the data the UIs display (replacing a GraphQL layer). |
| **operator SPA** | React | The factory-floor screen an operator uses during a shift. |

## Two ideas that explain everything else

Two design decisions run through the whole stack. If you hold these two in your
head, the rest of the documentation will feel inevitable rather than arbitrary.

### Idea 1 — The read/write/compute split

Notice in the diagram that **writes and reads go to different services**. Operator
and admin *actions* (which change the world) go through **edge-api**. Screen *reads*
(which just display the world) come from **refdata-api**. And *computation* (turning
raw data into OEE) happens in **oeecloud-worker**, never in the database and never
in the API layer.

This is the rebuild's core principle from [Chapter 1](01-what-packiot-is.md) made
concrete: each concern lives in the layer good at it. It is why there are several
small services instead of one big one, and it is what makes the system testable,
scalable, and legible.

### Idea 2 — The three flows

The rebuild is a migration, and migrations are dangerous: you are replacing a
system real factories depend on. So the new stack does not "switch over" — it runs
**in parallel with itself**, three times, and proves it matches before anything is
retired.

Every message the transformer emits is stamped with a **`source_type`**, and the
worker fans each message to three destinations:

| Flow | `source_type` | Destination | What it proves |
|------|---------------|-------------|----------------|
| **F1** | `""` (empty) | `packiot.public` — the legacy schema | the baseline; what production does today |
| **F2** | `"go"` | `packiot.shadow_go_port` — a shadow schema | the Go pipeline produces the same raw writes as F1 |
| **F3** | `"refactored"` | `packiot_analytics` — a separate database | the *refactored* schema (pooled tenancy, clean names) still produces the same results |

A comparator continuously diffs the three. F1-vs-F2 proves the *code* port is
faithful; F2-vs-F3 proves the *schema* refactor is faithful. The migration
finishes not with a switch but with a **collapse**: once the three have agreed for
long enough (a "bake"), F3 is promoted to be *the* flow and F1/F2 retire. That
promotion is "the flip," and it is days away as of this writing.

This is why you will see the phrase "same behavior" everywhere, and why so much of
the engineering is measurement. The whole rebuild is built to be *provably*
identical to the system it replaces — and [Chapter 4](04-the-engine.md) shows the
receipts.

---

Next: [The Edge](03-the-edge.md) — how a machine becomes a message.
