# Glossary

The guide introduces its vocabulary in context, in the order a newcomer meets it.
This page is the quick lookup for when a term has scrolled off the screen — one
crisp line each, grouped the way the story is. It is a companion to the guide, not
a replacement for it; the chapter link tells you where the term is *explained*.

For the deeper domain rules behind these terms (the ones learned via production
incidents), see [`BUSINESS-RULES.md`](../BUSINESS-RULES.md).

## The domain (why the stack exists)

| Term | One line |
|------|----------|
| **OEE** | Overall Equipment Effectiveness — the headline number. `Availability × Performance × Quality`. See [Ch. 1](01-what-packiot-is.md). |
| **Availability** | Was the machine producing when it was scheduled to? Lost to unplanned stops. |
| **Performance** | Was it running at its *ideal* speed? Lost to slow running. |
| **Quality** | Were the parts good, not scrap? `net / gross` production. |
| **PLC** | Programmable Logic Controller — the machine's on-board controller; emits raw counts, speed, and state codes. |
| **PackML** | Packaging Machine Language — the convention for PLC parameter IDs (e.g. `30701` = ideal speed) and machine states. |
| **Production Order (PO)** | A unit of work: "make N of product X on machine Y." Has a lifecycle (available → running → paused → finished). |
| **Downtime** | A period a machine was stopped, plus its classification (planned / changeover / unplanned) — the raw material of Availability. |
| **Shift** | The calendar of when a factory is *scheduled* to run. OEE is almost always reported per shift. |
| **Equipment hierarchy** | `enterprise → site → area → equipment`; equipment is a **machine** (`tp_equipment=1`), **sector** (`2`), or **line** (`3`). |
| **lead_machine** | The machine whose PLC generates the downtime events for a sector or line. |

## The edge (floor to bus)

| Term | One line |
|------|----------|
| **MQTT** | The lightweight pub/sub messaging protocol PLCs publish over. |
| **SparkPlug B** | An industrial standard on top of MQTT: Protocol-Buffer payloads plus a stateful session model. See [Ch. 3](03-the-edge.md#first-principles-the-sparkplug-session-model). |
| **Birth certificate (NBIRTH/DBIRTH)** | The message that establishes a publisher's metric definitions and alias table; every later reading references it. |
| **Alias** | A small integer standing in for a full metric name on the wire — set at birth, reused on every DATA message to save bandwidth. |
| **seq** | A per-publisher sequence number (mod 256); a gap means a lost message. |
| **edge Node-RED** | The minimal on-site flow: non-SparkPlug PLC adapters, a few operator endpoints, and the governed customization surface. See [Ch. 3](03-the-edge.md). |
| **edge-transformer** | The Go edge service: decode SparkPlug → normalize → calculate → publish durably. |
| **counter calc** | Turning raw machine counters into per-message deltas and rates — ported arithmetic, not OEE. |
| **outbox / store-and-forward** | The on-disk SQLite buffer the transformer writes to *before* publishing, so a broker/network outage loses nothing. |
| **publisher confirms** | RabbitMQ's per-message acknowledgment; the outbox row is deleted only once the broker confirms. |
| **client.yaml** | The per-tenant config file that onboards a factory — "onboarding is a config file, not code." |
| **tenant_id** | The key in `client.yaml` that names a factory's RabbitMQ queues and Prometheus labels — a contract enforced on both sides. |

## The data model (Ch. 5)

| Term | One line |
|------|----------|
| **hypertable** | A TimescaleDB table auto-partitioned by time — how `equipment_values` stays queryable at billions of rows. |
| **continuous aggregate (CAgg)** | A TimescaleDB materialized rollup that refreshes automatically — e.g. raw values into one-minute buckets. |
| **the cascade** | The rollup chain `equipment_values → ca_*_1min → equipment_runtime_1hour → _shift/_1day/…` that turns the firehose into per-window OEE. |
| **dirty flag (`recalc_needed`)** | A boolean that marks a row as needing recomputation; one phase sets it, exactly one clears it. See [Ch. 4](04-the-engine.md#the-dirty-flag-cascade-concretely). |
| **historian** | The industrial pattern this schema follows (cf. OSIsoft PI, Ignition): append-only telemetry, cascaded rollups, an event ledger, dirty-flags. |
| **pool schema / tenancy-by-row** | The refactor's answer to per-customer tables: one shared schema where the customer is a `customer_id` *column*, not a table-name suffix. |
| **expand-contract** | The migration style where legacy names survive as compatibility views while the new shape lands underneath. |

## The migration (Ch. 2, 4, 9)

| Term | One line |
|------|----------|
| **the three flows (F1/F2/F3)** | The same message written three ways in parallel: legacy schema, shadow-port schema, refactored database — to prove the new equals the old. |
| **`source_type`** | The stamp on each message that routes it to F1 (`""`), F2 (`"go"`), or F3 (`"refactored"`). |
| **the bake** | Running the three flows on identical traffic long enough to prove they agree (a *clock* gate — it cannot be rushed). |
| **the flip** | Promoting the refactored database (`packiot_shadow`) to be *the* database and retiring the parallel machinery. See [Ch. 9](09-the-endgame.md). |
| **comparator / differential** | The service that continuously diffs the flows and reports per-surface mismatch counts to the parity board. |
| **Equivalence Argument** | The header on every ported file arguing, phase by phase, that the Go SQL reproduces the original procedure. See [Ch. 4](04-the-engine.md#the-math-how-go-reproduces-a-stored-procedure-exactly). |
| **golden fixture** | A test that seeds a known scenario in an ephemeral PostgreSQL and asserts the ported code's exact output. |
| **pg_cron** | The in-database scheduler the legacy engine ran on — replaced by the Go job runner. |
| **search_path** | The Postgres session setting the worker swaps to run one rollup against three schemas without duplicating code. |

## The services (Ch. 2, 6)

| Term | One line |
|------|----------|
| **oeecloud-worker** | The engine: consumes the bus, writes raw data, and runs the ~13 scheduled jobs that compute OEE. |
| **edge-api** | The control plane (NestJS): operator/admin *actions* — start a PO, justify a downtime — each writing an audit entry. |
| **refdata-api** | The read plane (Go): serves the data the UIs display; resolves tenant identity server-side. |
| **operator SPA** | The React floor screen an operator uses during a shift. |
| **RabbitMQ** | The message bus — the single contract between ingestion and processing. |
| **mirror-worker-go** | Read-only replay of real production *data* into staging (and its validator); survives the flip, repointed. |
| **shadow-mirror** | Replay of operator *actions* (from the `user_logs` audit trail) onto the shadow flows; pure migration scaffolding, retires at the flip. |
| **`user_logs`** | The audit trail edge-api writes on every mutation — load-bearing, because the mirrors replay from it. |
| **ADR** | Architecture Decision Record — a dated record of one choice and why the alternatives lost. Indexed in [Ch. 10](10-decision-log.md). |

---

← Back to [the guide index](../README.md).
</content>
