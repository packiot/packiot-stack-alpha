# Architecture — the flows, old and new

> Audience: engineers (new team members start here after the
> [executive summary](00-executive-summary.md)). Everything on this
> page is verifiable against the running staging stack.
>
> Status date: 2026-07-06 (post 10.9 MQTT cutover, pre §6 flip).

## 1. The production system today (client side, unchanged)

What runs for real customers right now — the system we are replacing,
and the behavioral contract we must match:

```
PLC (factory floor)
  │ Sparkplug B over MQTT
  ▼
edge-node-red  (on-site Node-RED: wraps metrics, PO control calls)
  │
  ▼
Google Cloud PubSub
  ▼
oeecloud-node-red  (GCP: resolves topics → id_equipment, writes raw rows)
  ▼
PostgreSQL 12 + TimescaleDB (tsp12)
  │  ~150 piot_* PL/pgSQL functions, triggers and pg_cron jobs
  │  compute ALL OEE math inside the database
  ▼
Hasura Cloud ──► front4 (React)     PowerBI ◄── 38 gate objects
edge-api / primary-api / back4-api  (NestJS/Node services)
```

Key properties (and problems): all business math lives in unversioned
PL/pgSQL with copy-paste generations (`_test` IS production, `f2()`
supersedes `f()` silently); Node-RED flows are the ingestion and
automation layer; observability is minimal; nothing is unit-testable.

## 2. The new stack (staging, live today)

```
plc-sim  (Go Sparkplug B simulator — stands in for factory PLCs)
  │ MQTT (Mosquitto, persistent, ADR-0011 durability rules)
  ▼
edge-transformer  (Go)
  │  Sparkplug decode → alias resolution (StateStore) →
  │  Calc port (counters math, ADR-0010) → SQLite outbox →
  │  TRIPLE-EMIT envelopes: source_type "" / "go" / "refactored"
  ▼ RabbitMQ (publisher confirms)
oeecloud-worker  (Go — THE engine)
  │  writers: equipment_values (+ shift labels via the Go resolver,
  │           + event mint on shadow routes), uns metrics, PO params
  │  jobs (see §4): po-runtime-refresh, runtime-rollup,
  │           runtime-provision, uns refreshers, bake comparator
  ▼
 ┌──────────────┬───────────────────┬────────────────────┐
 │ F1 packiot   │ F2 shadow_go_port │ F3 packiot_shadow  │
 │ .public      │ (schema, same DB) │ (refactored DB)    │
 │ "alpha"      │ ADR-0010 proving  │ ADR-0012 target    │
 └──────────────┴───────────────────┴────────────────────┘
        ▲                                    ▲
mirror-worker (Go): mirrors PROD data in     │
(POs, events, value deltas w/ attributed     │
ledger) — fan-out to all three flows         │
shadow-mirror (Go): replays operator actions │
from user_logs → POs + RUNTIME WINDOWS ──────┘
edge-api (NestJS) · query-api · operator SPA · Grafana/Prom/Loki
```

**One source feeds all three flows identically** (verified 25=25=25
rows in identical windows). After the §6 flip, F3 (`packiot_shadow`)
becomes THE flow and F1/F2 plus the mirror machinery retire.

## 3. The database, as layers

```
 REFERENCE (public, shared): enterprises→sites→areas→equipments,
   shifts+shift_hours, packml_register, production_targets,
   DESCRIPTORS: label_formats, box_production_bridges
        ▼
 INGEST (raw truth): equipment_values (hypertable),
   equipment_events(+_man), user_logs
        ▼──────────────┬────────────────────┬──────────────
 TIME BUCKETS          │ BUSINESS WINDOWS   │ CUSTOMER POOLS
 (CAggs, native):      │ (the runtime       │ customer_reports.*
 agg_* family +        │  engine, §4):      │ (shift/speed/boxes/
 ca_agg_* family       │ production_orders  │  sync pools; legacy
 (state-dimensioned,   │ + _runtime windows │  names live on as
 hierarchical — the    │ equipment/area/    │  façade VIEWS until
 mechanism swap)       │ site_runtime_x     │  Wave 4)
        ▼──────────────┴────────────────────┴──────────────
 CURRENT STATE (UNS): uns_{equipment,area,site}_current_{hour,day,
   shift,week,month,job,metrics} — what dashboards read "right now"
```

The coordination protocol is a **dirty-flag cascade**: every writer
marks the buckets that depend on it `recalc_needed`; every writer
processes only flagged buckets; tails re-flag the current edge each
pass. No queue, no orchestrator — the dependency graph lives in "who
flags whom". (Deep dive: the cascade zettel in the team vault;
mechanics in `services/oeecloud-worker/internal/rollup/`.)

## 4. The engine's jobs (oeecloud-worker)

| Job (ledger name) | Cadence | What it does | Ported from |
|---|---|---|---|
| `po-runtime-refresh` | 1 min | compute → recalc → UNS jobs, in prod's dispatcher order, fail-soft per step | `piot_proc_refresh_production_orders` (`_test` → `_final` → jobs) |
| `runtime-rollup` | 1 min | equipment hour → day → shift → week/month, then area ×5, site ×5 (upward re-flag cascade) | the 9 `_production` bodies + 10 area/site bodies (dispatcher-verified generations) |
| `runtime-provision` | 1 h | 30 days of future bucket rows, targets, tz day-anchors | 17 `piot_create_*` fns (transitional verbatim via search_path) |
| `uns` refreshers | 5 min | current hour/week/month (equipment), full area/site set, `last_24_hours` trails | `piot_refresh_uns` + `_areas` (live generations only — day/shift are commented out on prod and were NOT ported) |
| `bake-comparator` | 10 min | F1-vs-F2 fidelity (10 surfaces) + F2-vs-F3 identity (3 fingerprints) | n/a — the ADR-0016 gate |

Cross-cutting: per-dest **advisory locks** serialize provision vs
rollups; all jobs fire once at boot with a deterministic stagger
(deploy-starvation + thundering-herd lessons); every return path logs.

## 5. Where things are

| Concern | Location |
|---|---|
| Engine code | `services/oeecloud-worker/internal/{rollup,uns,pocontrol,events,reports,bake,writers}` |
| Ingest | `services/edge-transformer/` (+ `cmd/plc-sim`) |
| Prod mirroring | `services/mirror-worker-go/`, `services/shadow-mirror/` |
| Legacy captures (ground truth) | `docs/adr/reference/0014-*.sql`, `0012-*.sql` |
| Parity harness | `services/oeecloud-worker/cmd/port-parity/` |
| Dashboards | `grafana/dashboards/` (esp. `09-bake-flow-parity`) |
| The flip | [`docs/adr/reference/0016-flip-runbook.md`](../adr/reference/0016-flip-runbook.md) |
