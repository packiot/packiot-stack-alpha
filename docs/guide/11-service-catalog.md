# 11 — Service Catalog

The chapters before this one told the story: how a machine signal becomes a
message, becomes OEE, lands in a database, and is read back by people. This chapter
is the **reference companion** to that story. It does not re-explain *how* anything
works — it lists, per service, two things:

- **Objective** — what the service is *for*, in one breath.
- **What it has** — the concrete inventory: a database's tables and schemas, an
  API's endpoints, a Go service's packages, a UI's screens.

When you want the narrative — *why* it is shaped this way, *how* the pieces move —
each entry links back to the chapter that tells it. Read this like a parts catalog,
not a novel.

> **A note on sources.** Every table, endpoint, package, and dataset below was
> verified against real source at the paths cited. Where a name in the narrative
> chapters is aspirational (the schema refactor is mid-flight), this catalog cites
> the name that is *actually in the code today* and flags the difference. Nothing
> here is inferred.

---

## PostgreSQL + TimescaleDB — the database

**Objective.** The single source of durable truth for the whole platform: it stores
raw machine telemetry, rolls it up through time buckets into OEE business windows,
keeps a live current-state cache for mission-control screens, and holds all the
reference data (the equipment hierarchy, shifts, PackML routing) that everything
else configures itself from. It is PostgreSQL with the **TimescaleDB** extension for
time-series compression and continuous aggregates. → [Ch.5](05-the-database.md) for
how the layers fit together, [Ch.4](04-the-engine.md) for what computes into them.

**What it has.**

Two schema snapshots matter, because the database is mid-refactor:

| Snapshot | Where | Shape | Size |
|----------|-------|-------|------|
| **Legacy prod** | `edge-api/schema.sql` (a custom column dump) | single `public` schema, `agg_*` aggregate names, OEE math in triggers/`pg_cron` | ~300 tables in the snapshot |
| **Refactored (staging target)** | [`adr/reference/0016-endstate-schema-map.md`](../adr/reference/0016-endstate-schema-map.md) | six deliberate layers + an "absent seventh", pooled tenancy, `customer_id` columns | ~248 tables (schema audit) |

### The core spine (5 tables)

The whole data model rests on these; everything else is a rollup, projection, or
cache of them. All verified present in `edge-api/schema.sql`.

| Table | Role |
|-------|------|
| `equipment_values` | Raw truth — one machine sample per instant, TimescaleDB **hypertable**, unique on `(ts_value, id_equipment)`. Counters, state, denormalized hierarchy context. |
| `agg_equipment_values_1min` | The one-minute tier — the firehose in 1-minute buckets (trigger-fed, `_t` in older SQL), with a continuous aggregate `ca_agg_equipment_values_1min` over it. **Naming:** grep `agg_*` — that is what the flows carry (naming ledger: "flows carry `agg_*` only"); ADR-0012's end-state canon is the `ca_agg_*` family, and the bare `ca_equipment_values_1min` in older ADR prose was never built. |
| `equipment_events` / `equipment_events_man` | The downtime ledger — one row per machine event (`ts_event`→`ts_end`) with classification (`cd_category`, `planned_downtime`, `change_over`). The `_man` suffix marks manually-classified events. |
| `production_orders` | The business work unit — PO lifecycle (`status` 1–4), plan vs. outcome, denormalized OEE + Q/A/P breakdown, the `recalc_needed` dirty flag. |
| `production_orders_runtime` | One PO, many runs — a row per contiguous run with a `runtime_timerange` and its own OEE; a GiST exclusion constraint forbids overlapping runs (source of the honest `409 Conflict`). |

### The rollup ladder (time-bucket aggregates)

The OEE cascade concretely — data flows *up* these grains, and the `recalc_needed`
dirty flag propagates up with it (→ [Ch.4](04-the-engine.md#the-dirty-flag-cascade-concretely)):

```
equipment_values → agg_equipment_values_1min → equipment_runtime_1hour → equipment_runtime_shift
                                                                       ↘ _1day / _1week / _1month
```

Verified present in `edge-api/schema.sql`:

- **Equipment grain:** `equipment_runtime_1hour`, `equipment_runtime_shift`,
  `equipment_runtime_1day`, `equipment_runtime_1week`, `equipment_runtime_1month`.
- **Area rollup:** `area_runtime_1hour` / `_shift` / `_1day` / `_1week` / `_1month`.
- **Site rollup:** `site_runtime_1hour` / `_1day` / `_1month` (and peers).
- **Box CAggs (`ca_` prefixed):** `ca_equipment_boxes_1s`, `ca_equipment_boxes_1hour`
  — the `ca_` prefix that *does* exist in the code today lives on these box/discrete
  aggregates, plus `ca_discrete_changes_1s` (per the end-state map).

### Current-state cache (UNS)

Not history — a live "what is every machine doing *right now*" snapshot that
mission-control screens poll instead of re-aggregating. One row per entity. Verified
in `edge-api/schema.sql`:

- **Equipment:** `uns_equipment_current_metrics`, `uns_equipment_current_job`,
  `uns_equipment_current_day` / `_hour` / `_shift` / `_month`.
- **Area:** `uns_area_current_day` / `_hour` / `_shift` / `_week` / `_month`.

### Reference & config (the `public` layer)

The onboarding-time data CS Admin writes and everything else reads. Verified in
`edge-api/schema.sql`:

- **Hierarchy:** `enterprises` → `sites` → `areas` → `equipments`.
- **Routing & schedule:** `packml_register` (SparkPlug topic → `id_equipment`),
  `shifts`, `shift_hours`.
- **Catalog & people:** `products`, `product_families`, `clients`, `language_packs`,
  `user_logs` (the audit + replay backbone — load-bearing, see edge-api below).

### Multitenancy pools (the refactor's headline)

The legacy schema encoded tenant identity in *table names*; the refactor turns each
into a `customer_id` **column** in a pool schema. Legacy names survive as façade
views until Wave 4. Verified — legacy names in `edge-api/schema.sql`, refactored
targets in [`adr/reference/naming-ledger.md`](../adr/reference/naming-ledger.md):

| Legacy name (frozen, in schema.sql) | Refactored pool table |
|-------------------------------------|-----------------------|
| `report_shift_enterprsie_06` *(sic — shipped typo)* | `customer_reports.shift` |
| `report_speed_enterprsie_33` | `customer_reports.speed` |
| `sap_report_data_sync_customer_13` | `customer_reports.sap_data_sync` |
| `data_sync_enterprise_06` | `customer_reports.production_sync` |
| `equipment_boxes_cust_13` | `customer_reports.boxes` (flipped ✅) |

There is also a `customer_dashboards.*` pool for per-customer dashboard config.

### History & shadow schemas

- **`hist_*`** — frozen history tables, so live tables stay lean and retention can
  differ by table class (raw 180d, grains ~2y, history frozen). Refactored direction
  (end-state map §3); *not present in the legacy `schema.sql` snapshot*.
- **`shadow_go_port`** (schema) and **`packiot_analytics`** (separate database) — the F2
  and F3 destinations of the three-flow migration. Referenced across the worker and
  mirror services (`services/oeecloud-worker/internal/flows/flows.go`,
  `services/shadow-mirror/internal/config/config.go`). → [Ch.2](02-architecture-at-a-glance.md#idea-2--the-three-flows).

### Extensions & access

- **TimescaleDB** — hypertables (`equipment_values`) and continuous aggregates (the
  `agg_*`/`ca_*` rollups) with per-grain compression + retention policies.
- **`pg_cron` retired to Go** — the OEE math and scheduling that used to run inside
  the database as `piot_*` stored procs + `pg_cron` rows now live in oeecloud-worker
  ([ADR-0014](../adr/0014-extract-oee-math-from-database-to-app.md)).
- **Hasura** — a GraphQL layer historically sat directly on the DB; it is being
  retired in favor of refdata-api ([ADR-0015](../adr/0015-customer-facing-query-api.md)).
  Direct `pg_dump` is blocked; inspection goes through `information_schema` and the
  `edge-api/schema.sql` snapshot.

---

## edge-transformer (Go)

**Objective.** The factory-side ingest workhorse: it subscribes directly to a
machine's MQTT/SparkPlug B stream, decodes the protobuf, resolves aliases to a
stable equipment identity, does the counter calculations, buffers everything durably
to a local outbox, and publishes confirmed messages to RabbitMQ — stamped for the
three migration flows. Its one obsession is *never lose a message*. It never touches
PostgreSQL; its only output is a bus message. → [Ch.3](03-the-edge.md).

**What it has.** Packages under `services/edge-transformer/internal/` (verified `ls`):

| Package | Responsibility |
|---------|----------------|
| `sparkplug` | Decode + session state. `decoder.go` (protobuf unmarshal), `aliastable.go` (per-publisher birth/alias/seq state machine, `ErrNoBirth`/`ErrUnknownAlias`), `sim.go`. |
| `transforms` | The counter calculation — `calc_production_counters` (raw counters → deltas/rates). |
| `mqtt` | The MQTT subscription (the 10.9 direct-ingest path). |
| `outbox` | The on-disk SQLite store-and-forward buffer — the durability boundary ([ADR-0011](../adr/0011-durability-boundary-and-store-and-forward.md)). |
| `analyticspub` | The RabbitMQ publisher in confirm-select mode (`ErrPublishNacked`, `ErrConfirmTimeout`). |
| `amqp` | AMQP connection/channel plumbing. |
| `command` | Downlink commands: translates a cloud command into a SparkPlug **DCMD** and publishes it (`dcmd.go`, `consumer.go`, `executor.go`, `dedup.go`, `mqttpub.go`) — fail-safe: an ambiguous command is rejected, never partially applied. |
| `erpconnector` | Driver-agnostic two-way ERP sync ([ADR-0019](../adr/0019-edge-customization-capabilities.md) C2): reads POs/scrap/users out of a customer DB, writes downtime/production back — replacing cleartext-credential Node-RED flows. Only active when `client.yaml` declares an integration. |
| `clientconfig` | Parses the per-tenant `client.yaml` (`loader.go`) → drives queues + Prometheus labels. |
| `handlers` | The decode→calc→outbox→publish message handlers. |
| `config`, `secrets`, `health`, `metrics`, `log` | Boot config, secret loading, health/`/metrics`, structured logging. |

Also ships companion `cmd/` binaries: `plc-sim` (see the simulator entry),
`capture-fixtures`, `inject-counter-fixture`.

---

## oeecloud-worker (Go)

**Objective.** The engine. It does two distinct things on one clock: (1) consumes
the RabbitMQ bus and writes raw data into the database in batched UPSERTs, and (2)
runs the ~14 scheduled jobs that *are* the ported `piot_*` stored procedures — the
OEE math extracted out of the database ([ADR-0014](../adr/0014-extract-oee-math-from-database-to-app.md)),
each proven byte-identical to prod via an equivalence argument and golden fixtures.
It fans every operation across the three flows by schema-swapping one code path. →
[Ch.4](04-the-engine.md).

**What it has — the ingest writers** (`internal/writers/`, verified `ls`):

- `equipment_values.go` — one metric → one batched idempotent UPSERT on `(ts_value, id_equipment)`.
- `po_parameter.go` — production-order parameter writes.
- `uns_current_metrics.go` — the live current-state snapshot writes.
- `query.go` — the `*Query` builder handlers enqueue into a `pgx.Batch`.

**What it has — the scheduled jobs** (each verified by its `Name:` registration and
defining file):

| Job | Defined in | What it computes |
|-----|-----------|------------------|
| `runtime-rollup` | `internal/rollup/grains.go` | The grain rollups (hour → shift → day/week/month), ported from `piot_get_equipment_runtime_*`. Math in `hour.go`, `shift.go`, `day.go`, `entity_grains.go`. |
| `runtime-provision` | `internal/rollup/provision.go` | Pre-creates empty bucket rows (verbatim PL/pgSQL execution, the low-risk porting style). |
| `po-runtime-recalc` | `internal/rollup/recalc.go` | Re-arms `recalc_needed` on running/finished POs (the dirty-flag cascade). |
| `po-runtime-refresh` | `internal/rollup/compute.go` | The PO-runtime compute pass (`po-runtime-compute`/`-finisher` lineage). |
| `uns-refresh` | `internal/uns/uns.go` | Refreshes the UNS current-state matrix. |
| `uns-current-metrics` | `internal/uns/current_metrics.go` | Refreshes `uns_equipment_current_metrics`. |
| `events-deriver` | `internal/events/deriver.go` | Derives `equipment_events` from raw state. |
| `speed33` | `internal/reports/speed33.go` | The speed report → `customer_reports.speed` (legacy `report_speed_enterprsie_33`). |
| `shift06` | `internal/reports/shift06.go` | The shift report → `customer_reports.shift` (legacy `report_shift_enterprsie_06`). |
| `sap13` | `internal/reports/sap13.go` | The SAP data sync → `customer_reports.sap_data_sync` (owner-gated; SQL in `sap13_body.sql`). |
| `sync06` | `internal/reports/sync06.go` | Production data sync → `customer_reports.production_sync` (SQL in `sync06_body.sql`). |
| `boxes` | `internal/reports/boxes_adapter.go` | Box-count label adapter → `customer_reports.boxes`. |
| `boxes-bridge` | `internal/reports/boxes_bridge.go` | Box→production bridge (`box_production_bridges` descriptors). |
| `bake-comparator` | `internal/bake/bake.go` | The differential-bake comparator: diffs the three flows and emits mismatch metrics. |

Supporting packages: `amqp` (consumer), `flows` (the three `Dest`s + `search_path`
swap), `jobs` (the ticker runner with per-tick timeout/panic isolation), `db`
(pooled `pgx`), `pocontrol`, `shiftresolver`, `sparkplug`, `tenants`, `handlers`,
`config`, `secrets`, `health`, `metrics`, `log`.

---

## edge-api (NestJS)

**Objective.** The control plane — the *only* service that changes the world.
Operator and admin actions (start a PO, justify a downtime, onboard a site) go here;
every mutation writes a `UserLogsDTO` audit row that two mirror services replay from,
so the audit trail is a live contract, not just logging. It never computes OEE. Built
as NestJS vertical slices (`controller` → `service` → DAO), authenticated by API key.
→ [Ch.6](06-apis-and-operator.md).

**What it has.** Usecase domains under `edge-api/src/usecases/` (verified `ls`), each a
vertical slice with `dto/`. Routes are `@Controller('/api/...')` (verified via
`@Controller` decorators). Mutations are POST (including deletes).

**Operator actions:**

| Domain | Endpoints (`/api/...`) |
|--------|------------------------|
| `production-orders` | `.../create`, `.../create-and-start`, `.../start`, `.../stop`, `.../setup`, `.../replace`, `.../change-status`, `.../change-time`, `.../current` |
| `downtimes` | `.../create-manual-event`, `.../edit-manual-event`, `.../delete-manual-event`, `.../justify`, `.../split`, `.../split-manual-downtime`; feature slices also cover `upsert`, `get-justified-downtimes`, `get-pending-downtimes` |

**CS Admin CRUD** (onboarding — each domain has `.../create`, `.../edit`,
`.../delete` plus a read root):

- Hierarchy: `enterprises`, `sites`, `areas`, `equipments`, `lines`
- Routing & config: `packml-register`, `packml-config`
- Scheduling: `shifts`, `shift-hours`
- People & misc: `users`, `user-roles`, `samples`, `labels`, `pages`

**Cross-cutting:** `middleware/auth.middleware.ts` (API-key auth via `?token=`),
`logger.middleware.ts` (writes the `user_logs` audit row), a global
`HttpExceptionFilter`, and DAOs under `src/data/DAO/` on a pg-promise
`PostgresAdapter`. Operator login (`/session`, bcrypt + JWT) is described in
[Ch.6](06-apis-and-operator.md#edge-api--the-control-plane-writes) and
[ADR-0018](../adr/0018-operator-frontend-integration-makeover.md); it was not present
in the edge-api submodule commit checked out here, so no route is asserted for it in
this catalog.

---

## refdata-api (Go)

**Objective.** The read plane — it serves the data the UIs *display*, replacing the
Hasura GraphQL layer that sat directly on the database ([ADR-0015](../adr/0015-customer-facing-query-api.md)).
It offers fixed operator endpoints plus a composable query API, and resolves tenancy
**server-side**: an `X-Api-Key` header maps to a `customer_id` bound to `$1` in every
query, so a browser can never ask for another tenant's data by editing a parameter.
→ [Ch.6](06-apis-and-operator.md#refdata-api--the-read-plane-reads).

**What it has.** Code under `services/refdata-api/cmd/refdata-api/`.

**Fixed routes** (the `endpoints` slice in `main.go`, verified) — thin wrappers over a
DB view or function:

- `/v1/events-timeline`, `/v1/pending-downtime`, `/v1/downtime-reasons`
- `/v1/shift-hours`, `/v1/shift-hours-by-enterprise`, `/v1/day-week-begin`
- `/v1/operator-po-list`, `/v1/operator-po-details`, `/v1/operator-entities`
- `/v1/entities-per-user-role`, `/v1/language-packs`

**The composable query API** (`query.go`, verified):
`GET /v1/catalog` (lists datasets), `POST /v1/query` (`{dataset, filters, window}`),
`GET/POST /v1/screen-config`. Plus `/metrics` and `/healthz`.

**Datasets** — **34** entries in `datasets.go` (verified count), grouped by `group:`:

| Group | Count | Examples |
|-------|-------|----------|
| `overview-detail` | 7 | `overview-job-info`, `overview-events`, `overview-production-chart`, `overview-production-health`, `overview-downtimes-by-category` |
| `targets` | 4 | `oee-targets`, `production-targets`, `scrap-targets`, `targets` |
| `downtimes-analytics` | 4 | `downtimes-summary`, `downtimes-per-category`, `downtimes-events` |
| `live-uns-equipment` | 5 | `live-equipment-metrics`, `live-equipment-job`, `live-equipment-day`, `live-equipment-shift`, `live-equipment-month` |
| `mission-control` | 3 | `mission-control`, `mission-control-area`, `mission-control-timeline` |
| `oee` | 3 | `oee-score-teams`, `oee-score-full`, `oee-progress` |
| `enterprise-config` | 3 | `enterprise-config`, `user-roles`, `users` |
| `single-period` | 2 | `single-period`, `single-period-legacy` |
| `machine-speed` | 1 | `machine-speed` |
| `production-flow` | 1 | `production-flow` |
| `total-production` | 1 | `total-production` |

Datasets read the *live view generation* (`_2`/`_3`/`_setup_4`, `h_*` Hasura-parity
functions) until each view/function completes its ADR-0014 port. Connection is pooled
`pgx` through pgbouncer (simple-protocol query mode).

---

## operator (React SPA)

**Objective.** The factory-floor screen an operator uses during a shift: see the
current order, start the next one, and justify why a machine stopped. Its behavior is
unchanged from the legacy client, but its backend was repointed to the standard stack
— **reads → refdata-api, writes → edge-api, login → edge-api `/session`** — with the
enterprise API key injected by nginx server-side so the browser never holds it
([ADR-0018](../adr/0018-operator-frontend-integration-makeover.md)). →
[Ch.6](06-apis-and-operator.md#the-operator-spa--same-behavior-cleaner-backend).

**What it has.** A Vite React app under `operator/src/` (verified `ls`):

- **Screens** (`Pages/`): `Login`, `Home`, `ChangeJob`, `NotFound`.
- **Structure:** `Components/`, `Context/`, `hooks/`, `Services/` (`api.js` — an axios
  instance whose `baseURL` comes from `VITE_API_URL`, so the browser sees one
  same-origin host in front of the three services), `routes.jsx`, `Global/`, `utils/`.

The read/write/login split is topology, not new UI: the same screens, now talking to
purpose-built services instead of a Node-RED backend-for-frontend.

---

## edge-node-red

**Objective.** The deliberately-minimal factory-side Node-RED instance. After the
"10.9 cutover" moved SparkPlug ingest into edge-transformer, Node-RED shrank to two
jobs: adapt *non-SparkPlug* PLC protocols, and host a governed surface for
per-customer customization. It also still serves a small set of operator HTTP
endpoints. It is not killed because real factories genuinely need a customization
surface ([ADR-0009](../adr/0009-edge-transformer-go-service-and-nodered-split.md),
[ADR-0010](../adr/0010-sparkplug-decode-in-go-end-state.md)). →
[Ch.3](03-the-edge.md#edge-node-red--deliberately-minimal),
[Ch.7](07-customizations-and-real-factories.md).

**What it has.** A Node-RED project (submodule `edge-node-red/`): `flows/`,
`subflows/`, `nodes/`, `db/`, `hasura/`, `scripts/`, `docs/`. The operator HTTP
routes it hosts (verified by grep of the flows) include: `/data`, `/change-po`,
`/create-start`, `/available-production-orders`, `/add-manual-event`,
`/edit-manual-event`, `/downtime-reasons`, `/language-pack`, `/logo`, `/health`,
and the legacy `/plc-data` ingest leg (retiring with the flip).

**No longer owns:** SparkPlug/MQTT ingest, decoding, normalization, durability — all
now in edge-transformer.

---

## mirror-worker-go (Go)

**Objective.** The **data mirror + validator**. Staging has no real factory, so this
service replays a real enterprise's production *data* (POs, events, value deltas) from
the production database into staging — **read-only on the production side, always**.
It also validates: a reconciler checks active POs/event streams line up, a comparator
measures OEE-divergence between staging and prod, and a DLQ reanimator handles failed
replays. **It stays at the flip** (repointed at the single promoted database), because
staging always needs real data to be a useful test bed. →
[Ch.6](06-apis-and-operator.md#the-mirrors--how-staging-gets-real-data).

**What it has.** Packages under `services/mirror-worker-go/internal/` (verified `ls`):

| Package | Responsibility |
|---------|----------------|
| `replay` | Replays prod data rows into staging. |
| `reconcile` | The reconciler — checks POs/events line up. |
| `comparator` | Continuous OEE-divergence measurement (staging vs. prod). |
| `translate` | Maps prod identities → staging identities. |
| `db`, `config`, `secrets`, `health`, `metrics`, `log` | Pools, config, DLQ plumbing, observability. |

---

## shadow-mirror (Go)

**Objective.** The **action mirror**. Where mirror-worker-go carries the data plane,
this carries the *control plane*: it replays operator *actions* — PO lifecycle events,
downtime justifications, edits — from the `user_logs` audit trail onto the shadow
flows, so the shadow schemas experience the same operator behavior the real system
did. This is why `user_logs` is a live contract. **It retires at the flip** — pure
migration scaffolding: once the three flows collapse to one, there are no shadow flows
to replay onto. → [Ch.6](06-apis-and-operator.md#the-mirrors--how-staging-gets-real-data).

**What it has.** Packages under `services/shadow-mirror/internal/` (verified `ls`):
`replay` (with `handlers/` for each replayed action — `production_orders.go`,
`order_changed.go`, `manual_event_created.go`, `event_splitted.go`, plus
`natural_key.go` for identity matching), `db`, `config`, `health`, `metrics`, `log`.
It targets the `shadow_go_port` schema / `packiot_analytics` database.

---

## The cloud product tier (front4 / primary-api / back4-api)

These live in **separate repositories**, not in this monorepo, so this catalog lists
only their objectives (from the platform repo map); there is no source-verified
inventory here.

| Service | Stack | Objective |
|---------|-------|-----------|
| `front4` | React SPA | The main product frontend — the dashboards a product user views in the office (distinct from the floor-facing operator SPA). |
| `primary-api` | Node.js | The main cloud product API. |
| `back4-api` | Node.js | An additional cloud API tier. |

In the new stack these read from the same database the engine writes; the read plane
they consume is being consolidated onto refdata-api as the Hasura layer retires.

---

## simulator / plc-sim

**Objective.** Two independent simulators that let staging behave like a live factory
without a real one attached. Documented authoritatively in `simulator/README.md`.

| | `simulator/` (Python) | `plc-sim` (Go) |
|---|---|---|
| **Objective** | Drive the *legacy HTTP ingest*: POST SparkPlug JSON to edge-node-red `/plc-data`, and rotate operator actions against edge-api to keep `user_logs` (and shadow-mirror) exercised. | Drive *the* ingest: publish SparkPlug B over MQTT to mosquitto (the 10.9 path). |
| **Source** | `simulator/simulator.py` (+ `devctl.py` manual CLI) | `services/edge-transformer/cmd/plc-sim/main.go` |
| **What it has** | A **PLC layer** (reads active `packml_register` topics from the DB, emits metrics every `SIM_INTERVAL`) and an **operator layer** (rotates 3 users calling edge-api every `OP_INTERVAL`: start/stop POs, justify downtimes). Env: `EDGE_NODERED_URL`, `EDGE_API_URL`, `DB_URL`, `SIM_INTERVAL`, `OP_INTERVAL`. | A DB-driven SparkPlug B source **and a DCMD listener** (verified in `main.go`), so it exercises the transformer's downlink command path too. |
| **Fate** | Retires with the Node-RED leg (flip R6/R7). | **Stays** — it exercises the real ingest. |

> Calibration note (from the README): staging *OEE > 1* artifacts trace to sim
> ideal-speed calibration, **not** engine math — check the simulator before suspecting
> the port.

---

*End of catalog. For how these services move together, return to
[Ch.2 — Architecture at a Glance](02-architecture-at-a-glance.md); for the migration's
endgame, [Ch.9](09-the-endgame.md).*
