# packiot-stack-alpha

> Local integration environment for the Packiot OEE platform.
> Spins up the full data pipeline — factory floor to dashboard — in a single
> `make up`, with no cloud accounts required.

---

## Table of contents

1. [What this is](#1-what-this-is)
2. [Architecture overview](#2-architecture-overview)
3. [Prerequisites](#3-prerequisites)
4. [Quick start](#4-quick-start)
5. [Service map](#5-service-map)
6. [Partial stacks](#6-partial-stacks)
7. [Environment variables](#7-environment-variables)
8. [Database seeding](#8-database-seeding)
9. [Grafana dashboards](#9-grafana-dashboards)
10. [Simulator](#10-simulator)
11. [Integration tests](#11-integration-tests)
12. [Makefile reference](#12-makefile-reference)
13. [Submodule management](#13-submodule-management)
14. [Common failure modes](#14-common-failure-modes)
15. [Architecture decisions](#15-architecture-decisions)

---

## 1. What this is

**Packiot** is an industrial IoT / OEE (Overall Equipment Effectiveness) platform
for manufacturing. It connects factory PLCs to a cloud analytics stack, answers
"how efficiently is this factory running?", and gives operators a real-time
interface to justify downtime events, manage production orders, and view shift KPIs.

**packiot-stack-alpha** is the local integration harness for that platform. It wires
together every service — factory Node-RED, cloud Node-RED, the NestJS API, the React
operator UI, TimescaleDB, Hasura, a GCP PubSub emulator, and Grafana — on a single
Docker Compose network, seeded with realistic fixture data, so a developer can:

- Run the complete message pipeline end-to-end without touching GCP or AWS
- Exercise the operator UI against a live API (not mocks)
- Write and run Layer-2 integration tests that assert real DB rows land
- Iterate on Grafana dashboards against live data

---

## 2. Architecture overview

```
┌──────────────────────────────────────────────────────────────────┐
│  packiot-stack-alpha (Docker Compose — packiot-net bridge)       │
│                                                                  │
│  ┌─────────────┐   SparkPlug B    ┌──────────────────────┐      │
│  │  simulator  │ ──────────────▶  │   edge-nodered       │      │
│  │  (Python)   │                  │   (Node-RED 4 LTS)   │      │
│  └─────────────┘                  │   port 1880          │      │
│                                   └──────────┬───────────┘      │
│                                              │ publishes        │
│                                              ▼                  │
│                                   ┌──────────────────────┐      │
│                                   │  pubsub-emulator     │      │
│                                   │  (GCP PubSub local)  │      │
│                                   │  port 8085           │      │
│                                   └──────────┬───────────┘      │
│                                              │ subscribes       │
│                                              ▼                  │
│                                   ┌──────────────────────┐      │
│  ┌─────────────┐  HTTP (REST)     │   oeecloud           │      │
│  │  edge-api   │ ◀───────────     │   (Node-RED 4 LTS)   │      │
│  │  (NestJS)   │                  │   port 1881          │      │
│  │  port 8080  │                  └──────────┬───────────┘      │
│  └──────┬──────┘                             │ writes           │
│         │ reads/writes                        ▼                  │
│         ▼                         ┌──────────────────────┐      │
│  ┌─────────────────────────────── │  TimescaleDB + pg    │      │
│  │  postgres (TimescaleDB 2.25)   │  port 5433           │      │
│  │  Schema: equipment hierarchy,  └──────────┬───────────┘      │
│  │  equipment_values, events,                │                  │
│  │  production_orders, user_logs  ┌──────────▼───────────┐      │
│  └────────────────────────────────│  Grafana             │      │
│                                   │  port 3000           │      │
│  ┌─────────────┐   HTTP calls     └──────────────────────┘      │
│  │  operator   │ ──────────────▶  edge-nodered :1880            │
│  │  (React SPA)│                                                 │
│  │  port 3002  │                                                 │
│  └─────────────┘                                                 │
│                                                                  │
│  Supporting:  hasura :8081 · adminer :8082 · loki :3100         │
└──────────────────────────────────────────────────────────────────┘
```

### Data flow — one message, end-to-end

1. **simulator** publishes a SparkPlug B JSON payload to edge-nodered `/plc-data`.
2. **edge-nodered** wraps it into a PubSub message and publishes it to the
   `oee-topic` topic on the local GCP PubSub emulator.
3. **oeecloud** (subscribed to `oeecloud-sub`) consumes the message, resolves the
   SparkPlug topic to `id_equipment` via `packml_register`, and upserts a row into
   `equipment_values` (TimescaleDB).
4. **TimescaleDB triggers + stored procs** aggregate `equipment_values` into 1-min /
   1-hour / 1-day continuous aggregates and compute OEE (Quality × Availability ×
   Performance). OEE is never computed in application code.
5. **Grafana** queries TimescaleDB and displays live OEE panels.
6. **operator** (React SPA) calls edge-nodered for production order status and
   calls **edge-api** to justify downtime events, start/stop orders, and log
   operator activity to `user_logs`.

### What each service owns

| Service | Reads | Writes |
|---------|-------|--------|
| edge-nodered | PLC data, PubSub inbound | PubSub outbound, equipment_events |
| oeecloud | PubSub messages | equipment_values, uns_metrics |
| edge-api | All tables | production_orders, user_logs, equipment config |
| simulator | equipment_events (downtime list) | SparkPlug metrics via edge-nodered |
| Grafana | equipment_values, user_logs, aggregates | — |
| operator | edge-nodered (events), edge-api (CRUD) | via API only |

---

## 3. Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Docker Engine | ≥ 24 | `docker info` to verify |
| Docker Compose | ≥ 2.20 (Plugin) | `docker compose version` |
| GNU Make | any | `make --version` |
| Git | ≥ 2.38 | For submodule operations |

No GCP account, no AWS account, no Node.js, no Python. Everything runs in containers.

---

## 4. Quick start

```bash
# Clone with submodules (edge-api, edge-nodered, oeecloud, operator)
git clone --recurse-submodules git@github.com:packiot/packiot-stack-alpha.git
cd packiot-stack-alpha

# Initialize env file (safe — won't overwrite if already exists)
make setup

# Start the full stack (builds images, seeds DB, applies Hasura metadata)
make up

# Verify everything is running
make status
```

After `make up`, services become available in this order (allow ~60–90 s for
edge-nodered and oeecloud to fully initialize):

| URL | Service |
|-----|---------|
| http://localhost:3000 | Grafana (admin / packiot) |
| http://localhost:1880 | edge-nodered UI |
| http://localhost:1881 | oeecloud UI |
| http://localhost:8080 | edge-api REST |
| http://localhost:8081 | Hasura console (admin secret: `dev-admin-secret`) |
| http://localhost:8082 | Adminer (server: `postgres`, user: `postgres`, pw: `packiot`) |
| http://localhost:3002 | Operator UI |
| http://localhost:3100 | Loki (log aggregation, queried by Grafana) |

### Verify the pipeline is live

```bash
# Check the last 5 rows written by oeecloud — should update every ~5 s
make db-equipment-values

# Or watch it refresh automatically
make watch-values
```

If `net_production_incr` is null after 90 s, check [§14 Common failure modes](#14-common-failure-modes).

---

## 5. Service map

```
Service           Internal host:port        Host port   Purpose
─────────────────────────────────────────────────────────────────────────────
pubsub-emulator   pubsub-emulator:8681      8085        GCP PubSub emulator
postgres          postgres:5432             5433        TimescaleDB (OEE DB)
hasura            hasura:8080               8081        Hasura GraphQL proxy
adminer           adminer:8080              8082        DB browser GUI
grafana           grafana:3000              3000        OEE dashboards
loki              loki:3100                 3100        Log aggregation
edge-api          edge-api:8080             8080        NestJS admin / CRUD API
edge-nodered      edge-nodered:1880         1880        Factory Node-RED
oeecloud          oeecloud:1880             1881        Cloud Node-RED
operator          operator:3000             3002        React operator SPA
simulator         —                         —           Python PLC simulator
```

> **Why 5433 for Postgres?** Port 5432 is the system Postgres default on most
> Linux installs. 5433 avoids conflict without requiring the developer to stop
> a local instance.

> **Why 3002 for operator?** 3000 is taken by Grafana.

---

## 6. Partial stacks

Running everything at once is useful for integration testing. For focused
development you generally only need a subset:

```bash
# Infrastructure only (PubSub + TimescaleDB + Hasura + Grafana)
make up-infra

# Test the SparkPlug pipeline without the operator UI
make up-edge        # infra + edge-nodered
make up-oeecloud    # infra + oeecloud (PubSub consumer)

# Test edge-api in isolation (only needs Postgres — no PubSub, no Node-RED)
make up-api

# Full operator flow: infra + edge-api + edge-nodered + operator SPA
make up-operator

# Add the PLC simulator to any of the above
make up-simulator
```

Partial stacks always include the infrastructure tier (Postgres, PubSub emulator,
Hasura, pubsub-init, hasura-init) because every service depends on it. The Compose
`depends_on` conditions enforce startup order via healthchecks, so services only
start after their dependencies are ready.

---

## 7. Environment variables

Copy `.env.example` to `.env.local` (`make setup` does this automatically):

```bash
cp .env.example .env.local
```

**All infrastructure connection strings are hard-coded in `compose.integration.yml`**
and require no configuration. `.env.local` is for secrets and identifiers that
differ per deployment.

| Variable | Default | Where used |
|----------|---------|-----------|
| `NODE_RED_CREDENTIAL_SECRET` | (required) | edge-nodered, oeecloud — encrypts stored credentials |
| `API_KEY` | `dev-api-key` | edge-nodered → edge-api auth (`?token=` query param) |
| `ID_ENTERPRISE` | `1` | edge-nodered, oeecloud — enterprise scope |
| `ID_PUBSUB_NODE` | (required) | edge-nodered — node ID of the pubsub-out node to enable |
| `ALERT_EMAIL_TO` | `dev@example.com` | oeecloud — silent in dev |
| `SENDGRID_API_KEY` | `SG.dev-placeholder` | oeecloud — leave as-is in dev |

The `compose.integration.yml` pre-fills safe defaults for all connection details
(DB host/port/credentials, PubSub emulator URL, Hasura URL) so the stack works
out of the box with an empty `.env.local`.

---

## 8. Database seeding

The database is seeded automatically on first `make up` via the Postgres init
mechanism (`/docker-entrypoint-initdb.d/`). Files run in alphabetical order:

| File | Purpose |
|------|---------|
| `edge-node-red/db/00-schema.sql` | Full schema DDL: tables, indexes, TimescaleDB hypertables, continuous aggregates, triggers |
| `edge-node-red/db/01-seed.sql` | Base data: 2 enterprises (Packiot Dev + Demo Factory), sites, areas, equipments, packml_register entries, 2 users |
| `edge-node-red/db/02-production-objects.sql` | Stored procedures and pg_cron jobs used by the OEE pipeline |

The seed creates two fully wired enterprises:
- **Enterprise 1 — Packiot Dev**: equipment 2, topic `Packiot/Site1/Area1/Line1`
- **Enterprise 2 — Demo Factory**: equipment 4, topic `Factory2/Site/Area/Line`

### Simulator Corp seed (optional)

For Grafana dashboard population and operator activity testing, run the
Simulator Corp enterprise seed. This creates a third enterprise with pre-seeded
historical downtime events, production orders, and user_logs entries:

```bash
make sim-seed
```

The live simulator (`make up-simulator`) then keeps this data fresh with new
SparkPlug ticks and operator justification events.

### Resetting the database

The Postgres init scripts only run once (when the volume is empty). To re-seed:

```bash
make clean     # removes containers AND volumes (data will be lost)
make up        # fresh start — seeds automatically
```

---

## 9. Grafana dashboards

Grafana starts at http://localhost:3000 (login: `admin` / `packiot`).
Anonymous viewer access is enabled — no login required to view dashboards.

Dashboards are provisioned from `grafana/dashboards/` and are read-only in the
UI (changes must be made to the JSON files and reloaded).

| Dashboard | Purpose |
|-----------|---------|
| `01-oee-pipeline.json` | OEE pipeline monitoring: Quality / Performance / Availability / OEE KPI panels + time-series. Default home dashboard. |
| `02-equipment-config.json` | Equipment configuration view for CS Admin (equipment hierarchy, packml_register entries) |
| `03-system-health.json` | System health: event counts, recent downtime events, open vs. justified breakdown |
| `04-logs.json` | Loki log viewer: filter by service label, severity |
| `05-operator.json` | Operator activity: justification rate, backlog, per-user action counts, action log |

### Key query patterns

**OEE KPI panels** use this pattern (PostgreSQL requires explicit `::numeric` cast
before `ROUND` when the source column is `REAL` or `DOUBLE PRECISION`):
```sql
SELECT ROUND((AVG(speed) / NULLIF(e.production_speed, 0) * 100)::numeric, 1) AS "Performance %"
FROM equipment_values ev
JOIN equipments e ON e.id_equipment = ev.id_equipment
WHERE $__timeFilter(ev.ts_value) AND ev.id_equipment = $equipment
```

**Multi-value variable filters** use `${var:csv}` + `ANY(string_to_array())` to
avoid the `IN ($var)` syntax error when Grafana substitutes "All":
```sql
WHERE ('${enterprise:csv}' = '.*'
       OR id_enterprise IN (
           SELECT id_enterprise FROM enterprises
           WHERE nm_enterprise = ANY(string_to_array('${enterprise:csv}', ','))
       ))
```

---

## 10. Simulator

The simulator replaces real factory PLCs for local development. It has two
layers that run concurrently:

### PLC layer (`MachineState`)

One thread per machine, fires every 5 seconds. Publishes SparkPlug B JSON
payloads to edge-nodered `/plc-data`:

```python
{
    "timestamp": <unix ms>,
    "gateway": "dummy",
    "metrics": [
        {"name": "Enterprise/Site/Area/Machine/Status/StateCurrent",    "value": 6},
        {"name": "Enterprise/Site/Area/Machine/Status/ProdProcessedCount",
         "value": 12, "counter": 1024, "curspeed": 118},
        {"name": "Enterprise/Site/Area/Machine/Status/ProdDefectiveCount",
         "value": 0, "counter": 40},
        {"name": "Enterprise/Site/Area/Machine/Status/CurMachSpeed",    "value": 118},
    ]
}
```

State transitions between running (`state=6`) and stopped (`state=10`) happen at
a configurable frequency. Enterprise 2 (Demo Factory) uses higher scrap rates
and more frequent transitions to produce visually interesting OEE variation.

> **Topic format matters:** Base topics must be exactly 4 segments
> (`Enterprise/Site/Area/Machine`). oeecloud has a bug where 5-segment topics
> unconditionally reset the `topic_type` to `StateCurrent`, causing
> `ProdProcessedCount` values to land in the `state` column instead. The
> simulator always uses 4-segment topics.

### Operator layer (`OperatorSimulator`)

Simulates what a human operator does on the factory floor. Runs at a lower
cadence (every few minutes):

1. Calls edge-api `GET /api/equipment-events` to fetch pending downtime events
2. Picks a random downtime reason from the seed data (machine code + category)
3. Calls `POST /api/equipment-events/justify` with the selected reason
4. This populates `equipment_events.cd_category` and writes a `user_logs` row
   (`category = 'event-justified'`) — exactly what the Grafana operator dashboard
   queries

### Running the simulator

```bash
# Start the simulator alongside the full stack
make up-simulator

# Check that it's writing data
make watch-values

# Inspect logs
make logs-simulator
```

---

## 11. Integration tests

Layer-2 integration tests assert end-to-end pipeline behaviour against a live
stack. They are intentionally NOT unit tests — they test real message flow:

```
publish SparkPlug → PubSub → oeecloud → TimescaleDB → assert row present
call edge-api → assert user_logs row present
```

Tests live in `tests/integration/` (Python + pytest):

| File | What it tests |
|------|---------------|
| `test_plc_pipeline.py` | SparkPlug publish → `equipment_values` row lands within timeout |
| `test_operator_pipeline.py` | edge-api justify call → `user_logs` row lands |
| `test_healthcheck.py` | oeecloud healthcheck accurately reflects pipeline state |

### Run integration tests

The stack must be running (`make up`) before running tests.

```bash
# Build the test image + run tests in a one-shot container
make test-integration

# Run from the host (requires Python + pip install -r tests/integration/requirements.txt)
pytest tests/integration/ -v
```

Tests poll with a configurable timeout (`INT_POLL_TIMEOUT`, default 30 s) and
interval (`INT_POLL_INTERVAL`, default 1 s). Adjust via `.env.local` if your
machine is slow.

### What makes these tests meaningful

A purely mocked test suite can pass even when the real pipeline is broken — as
happened during a 19-hour silent failure where SSL misconfiguration stopped all DB
writes while Node-RED remained "healthy". These tests would have caught it in the
first polling cycle by asserting a DB row actually landed.

---

## 12. Makefile reference

```
Setup
  make init              Clone/update submodules + copy env example
  make setup             Copy .env.example → .env.local (idempotent)
  make update            Pull latest commit for all submodules

Full stack
  make up                Start all services (builds images)
  make down              Stop and remove containers (keeps volumes)
  make restart           down + up
  make clean             down + delete volumes (destructive — resets DB)
  make status            Show running containers
  make build             Build all service images

Partial stacks
  make up-infra          PubSub + TimescaleDB + Hasura only
  make up-edge           Infra + edge-nodered
  make up-oeecloud       Infra + oeecloud
  make up-api            Postgres + edge-api (no PubSub)
  make up-operator       Infra + edge-api + edge-nodered + operator UI
  make up-simulator      Start PLC + operator simulator

Individual builds
  make build-edge        Build edge-nodered image
  make build-oeecloud    Build oeecloud image
  make build-api         Build edge-api image
  make build-operator    Build operator UI image
  make build-simulator   Build simulator image

Logs (follow mode — Ctrl+C to stop)
  make logs              Tail all services
  make logs-edge         Tail edge-nodered
  make logs-oeecloud     Tail oeecloud
  make logs-api          Tail edge-api
  make logs-postgres     Tail TimescaleDB
  make logs-pubsub       Tail PubSub emulator
  make logs-simulator    Tail simulator

Database queries (one-shot)
  make db-equipments     List all equipments
  make db-packml         List packml_register routing table
  make db-enterprises    List enterprises (with api_key)
  make db-equipment-values   Last 20 equipment_values rows
  make db-events         Last 20 equipment_events rows
  make db-count          Row counts for all key tables

Live monitoring (Ctrl+C to stop)
  make watch-values      Refresh equipment_values every 2 s
  make watch-plc         Refresh per-metric-type breakdown every 2 s
  make watch-pubsub      Stream oeecloud logs (shows PubSub activity)

Utilities
  make psql              Open psql shell in the postgres container
  make shell-edge        sh into edge-nodered container
  make shell-oeecloud    sh into oeecloud container
  make shell-api         sh into edge-api container
  make shell-operator    sh into operator container
  make publish-test      Publish a minimal test SparkPlug message
  make sim-seed          Load Simulator Corp historical data seed
  make stress-db         Stress test: 1000 inserts + expensive OEE aggregate
  make test-integration  Run Layer-2 integration tests
```

---

## 13. Submodule management

This repo uses Git submodules for the four main services:

| Submodule | Remote | Branch |
|-----------|--------|--------|
| `edge-api` | `github.com/packiot/edge-api` | `development` |
| `edge-node-red` | `github.com/packiot/edge-node-red` | default |
| `oeecloud-node-red` | `github.com/packiot/oeecloud-node-red` | default |
| `operator` | `github.com/packiot/operator4` | `refactor/decompose-components` |

### First-time clone

```bash
git clone --recurse-submodules git@github.com:packiot/packiot-stack-alpha.git
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
# or equivalently:
make init
```

### Updating submodules to latest

```bash
make update
# equivalent to: git submodule update --remote --merge
```

This pulls the latest commit from each submodule's tracked branch. After
updating, rebuild affected images:

```bash
make build-edge     # or build-api, build-operator, etc.
```

### Pinning a submodule to a specific commit

Submodules are pinned to a commit SHA in `packiot-stack-alpha`'s index. If you
need a specific version:

```bash
cd edge-api
git checkout <sha-or-tag>
cd ..
git add edge-api
git commit -m "chore: pin edge-api to <sha>"
```

### Updating Node-RED flows in a running container

edge-nodered uses `node-red-contrib-flow-manager` which splits `flows.json` into
per-tab files on first start and reads those files on subsequent starts. This
means updating `flows.json` alone does not update a running container's flows.

To push a new or updated tab to a running container:

```bash
# Replace an existing tab (use the exact tab filename):
docker cp edge-node-red/flows/PLCs.json \
    packiot-stack-alpha-edge-nodered-1:/data/flows/PLCs.json
docker compose -f compose.integration.yml restart edge-nodered
```

The `entrypoint.sh` in each Node-RED service wipes per-tab files on startup
(`rm -f /data/flows/*.json`) to prevent stale tab files from overriding the
fresh `flows.json` baked into the image.

---

## 14. Common failure modes

### `equipment_values` not updating after 90 s

Check oeecloud logs first:

```bash
make logs-oeecloud
```

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `ssl is not supported` or postgres connection refused | `PG_SSL="false"` is a JS string — `"false"` is truthy → SSL enabled | Already fixed in `entrypoint.sh` via sed rewrite |
| No messages consumed from PubSub | `PUBSUB_SUBSCRIPTION` placeholder was sent literally to GCP SDK | Already fixed in `entrypoint.sh` via sed substitution |
| `String expected` on queue node startup | Stale per-tab files on volume have old field name (`sqlite` instead of `queuePath`) | `entrypoint.sh` wipes per-tab files; `make clean && make up` to reset |
| oeecloud logs show activity but no DB rows | `packml_register.active = false` for those topics | `make db-packml` to verify; set `active = true` in the seed or via Adminer |

### Operator UI shows no data / API calls fail

```bash
make logs-edge    # check that edge-nodered is fully started
make logs-api     # check for NestJS startup errors
```

The operator SPA calls edge-nodered (`:1880`) and edge-api (`:8080`). Both must
be healthy before starting the operator. The Compose `depends_on` condition
(`service_healthy`) already enforces this, but Node-RED takes ~60 s to initialize.

### PubSub emulator not receiving messages

```bash
# Check that the topic and subscription exist
curl http://localhost:8085/v1/projects/packiot-dev/topics
curl http://localhost:8085/v1/projects/packiot-dev/subscriptions

# Publish a test message manually
make publish-test
```

If the topic or subscription is missing, `pubsub-init` failed on startup.
Check: `docker compose -f compose.integration.yml logs pubsub-init`.

### `make db-*` commands return empty results

The DB volume may be uninitialized. Verify:

```bash
make psql
# inside psql:
\dt
```

If no tables exist, the init scripts didn't run. `make clean && make up` will
re-run them on a fresh volume.

---

## 15. Architecture decisions

### Why submodules instead of a monorepo copy?

Each service (`edge-api`, `edge-node-red`, etc.) has its own repository and CI
pipeline. `packiot-stack-alpha` locks them at known-good commit SHAs and wires
them together, acting as the integration layer. Submodules let each service team
develop independently while giving the integration layer a reproducible snapshot.

### Why a GCP PubSub emulator instead of a real broker?

The production stack uses real GCP PubSub. The emulator (`thekevjames/gcloud-pubsub-emulator`)
exposes the same HTTP API surface, so `edge-nodered` and `oeecloud` can run
unmodified. No GCP credentials, billing, or network access required for development.

### Why TimescaleDB instead of vanilla PostgreSQL?

OEE is a time-series problem: millions of 5-second rows per machine per year.
TimescaleDB adds:
- **Hypertables**: automatic time-based partitioning (chunk per week)
- **Continuous aggregates**: materialized 1-min → 1-hour → 1-day rollups
  maintained incrementally — Grafana queries them instead of raw rows
- **`time_bucket`**: vectorized bucketing that's 10–100× faster than
  `date_trunc` on large ranges

The schema is identical to vanilla PostgreSQL DDL; the TimescaleDB extension
adds the compression and aggregation layer transparently.

### Why does oeecloud not compute OEE?

OEE computation (Quality × Availability × Performance) lives entirely in
PostgreSQL triggers and stored procedures. This means:
- OEE is always consistent regardless of which service writes raw data
- Adding a new data source (new oeecloud instance, a direct PLC writer) doesn't
  require re-implementing OEE logic
- The DB is the single source of truth — Grafana can query any aggregation level
  without joining across services

### Why does oeecloud use ON CONFLICT upsert?

Multiple SparkPlug metrics arrive in the same message burst with the same
millisecond timestamp. oeecloud rounds to the nearest second and upserts all
metrics into a single `equipment_values` row via `ON CONFLICT (ts_value, id_equipment)
DO UPDATE SET ...`. This means one DB row contains `state`, `mode`,
`net_production_incr`, and `speed` together — which is correct and expected.
Grafana queries must count columns independently (not use exclusive `CASE WHEN`)
to avoid undercounting co-occurring metrics.

### Why does edge-api use `?token=` instead of `Authorization: Bearer`?

The production edge-api is deployed on-site at factories. The operator SPA is
also on-site and calls edge-nodered (not directly edge-api for most operations).
The `?token=` pattern matches the existing Node-RED HTTP request node convention
in the Packiot codebase. It is not a security recommendation for new services.

### Healthcheck philosophy: liveness ≠ effectiveness

The oeecloud container healthcheck (`healthcheck.sh`) tests two things:
1. Node-RED HTTP responds on `:1880` (process alive)
2. `equipment_values` has a fresh row within the last 120 seconds (pipeline effective)

This two-tier approach caught a class of silent failures (SSL misconfiguration,
PubSub placeholder not resolved, flow-manager stale cache) that passed a simple
HTTP liveness check while the pipeline produced no data for ~19 hours. The rule:
**a healthcheck must measure the effect, not just the process.**
