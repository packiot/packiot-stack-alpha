# mirror-worker-go — architecture

`mirror-worker-go` polls prod `user_logs` audit rows, translates the prod
entity IDs in each row's JSON payload to staging IDs, and replays the
action against staging `edge-api` via HTTP POST. Single goroutine, ~25
HTTP POSTs/min steady state.

Audience: anyone touching ID translation, the cursor loop, or adding a
new prod eventType. Pair this with `services/mirror-worker-go/internal/`
source — code is the spec, this doc is the map.

---

## Cursor-advance loop

```
┌────────── tick (every cfg.PollIntervalSec) ──────────┐
│                                                       │
│  read cursor   ── mirror_replay_cursor (staging)      │
│       │                                               │
│       ▼                                               │
│  update gauges (cursor_lag_seconds, id_map_cache_size)│
│       │                                               │
│       ▼                                               │
│  fetch new logs ── prod user_logs                     │
│       │           WHERE id_user_logs > cursor         │
│       │           ORDER BY id_user_logs ASC LIMIT N   │
│       ▼                                               │
│  for each row:                                        │
│       │                                               │
│       ├─ stagingDB.WithTx:                            │
│       │     IsAlreadyReplayed? → advance cursor       │
│       │                          (skipped metric)     │
│       │     dispatcher.Dispatch                       │
│       │       ├─ ok    → advance cursor               │
│       │       └─ failed → DLQ + advance cursor        │
│       │                                               │
│       └─ sleep cfg.PerPostDelayMs (rate-limit)        │
│                                                       │
└───────────────────────────────────────────────────────┘
```

**Key invariants:**

1. **Cursor never moves backward.** `AdvanceCursor` uses `WHERE last_log_id
   < $1`. An out-of-order call (shouldn't happen but defensive) is silently
   ignored.
2. **One row, one staging tx.** `processRow` wraps the dispatch + the
   cursor advance + the DLQ write (if any) in a single staging transaction.
   This is what the TS mirror-worker got wrong in `order-created.ts`: a
   handler that failed mid-flight could leak partial state because the tx
   boundary wasn't tight.
3. **Cursor advances even on failure.** A row that can't be replayed
   gets DLQ-d and the cursor still moves forward. The alternative —
   pause the cursor on first failure — wedges the entire replay on one
   bad row, which is worse than per-row visibility into failures.
4. **Idempotency via mirror_id_map.** Re-running the worker (or running
   it parallel with another instance) doesn't double-replay: every
   completed replay leaves a `mirror_id_map` row keyed by
   `(source, source_log_id)`. `IsAlreadyReplayed` short-circuits the
   dispatch when that key is found.

---

## ID translation flow

The whole point of the worker is that **prod IDs and staging IDs don't
match** — they're independently auto-incremented sequences. Every payload
field that names a prod entity has to be rewritten before the staging
edge-api will accept the POST.

| Entity         | Prod ID source             | Translation method                                         |
|----------------|----------------------------|------------------------------------------------------------|
| Enterprise     | row.id_enterprise          | **Hardcoded** in cfg.ProdEnterpriseID → cfg.StagingEnterpriseID |
| Site           | payload.idSite             | Business key `nm_site` (prod → SELECT → staging SELECT)    |
| Area           | payload.idArea             | Business key `nm_area`                                     |
| Equipment      | payload.idEquipment        | Business key `packml_topic` (with `C-PACK/` → `CPACK/` remap) |
| ProductionOrder | payload.idProductionOrder | `mirror_id_map` cache → fallback to business key `nu_production_order` |
| EquipmentEvent | payload.idEquipmentEvent   | `mirror_id_map` cache → fallback to **interval-overlap matcher** (A4b) |

### The interval-overlap matcher (Phase A4b)

The non-obvious one. Prod and staging produce **structurally different**
equipment_events from the same SparkPlug stream:

- **Prod** runs CPAC 5-min smoothing + writes operator metadata
  (`cd_machine`, `cd_category`) back into the row. Events are
  minute-aligned, fewer, and shorter.
- **Staging** has the raw PLC transitions. Precise-to-the-second, more
  events, longer durations.

So `ts_event` proximity (the obvious first attempt) doesn't match. The
fix: for a prod event `[t1, t2]` with status `S` on equipment `E`,
find the staging event with same `(E, S)` whose interval `[s1, s2]` has
the **largest overlap** with `[t1, t2]`, requiring at least
`cfg.EventMinOverlapSec` of overlap (default 30s) to count as a match.

After the first business-key resolution, the mapping is cached in
`mirror_id_map` so subsequent ops on the same prod event
(event-edited, event-splitted) skip the matcher SELECT.

When the matcher misses, the diagnostic logs the closest same-status
candidate by midpoint-distance — useful for triaging "no event at all in
the area" vs "events but with insufficient overlap" failure modes.

See `internal/translate/translate.go:EquipmentEvent` for the exact SQL.

---

## Dual-cursor history (cpack-prod vs cpack-prod-go)

The `mirror_replay_cursor` + `mirror_id_map` + `mirror_replay_dlq` tables
are keyed by a `source` label. The Go worker uses `cpack-prod-go`; the
**now-retired** TypeScript `services/mirror-worker` used `cpack-prod`.

Both rows persist:

```
mirror_replay_cursor
  source        | last_log_id  | last_run_at
  cpack-prod    | 2547123      | 2026-06-23 11:42:00  (TS — frozen)
  cpack-prod-go | 2548991      | 2026-06-24 14:08:00  (Go — active)
```

Why keep `cpack-prod` around? Three reasons:

1. **Replay-history forensics.** Old DLQ rows with `source='cpack-prod'`
   point at TS-era bugs. Deleting the source label loses that audit
   trail. Storage cost is negligible (a few hundred rows).
2. **mirror_id_map continuity.** Mappings created by the TS worker are
   stale (one-to-one match against the same source events), but a future
   one-shot to reconcile them with the Go worker's mappings is easier if
   they still exist.
3. **Disaster-recovery option.** If the Go worker has to be rolled back
   for any reason, the TS worker can be relaunched against its preserved
   cursor without losing the replay-state delta.

The next planned simplification: once the Go worker has been live without
incident for a few weeks, archive the `cpack-prod` rows (move to a
`mirror_replay_archive_*` table or drop them entirely) and rename
`cpack-prod-go` → `cpack-prod`. Tracked as a follow-up housekeeping task,
not blocking anything.

---

## The 11 eventTypes

Each replays a different prod operator action into staging. All live in
`internal/replay/<event_type>.go`.

| eventType (user_logs.category) | What it replays                                                 | Staging endpoint                            |
|--------------------------------|------------------------------------------------------------------|---------------------------------------------|
| `order-status-changed`         | PO transitions (available → running, etc.)                       | POST /api/production-orders/change-status   |
| `order-created`                | New PO row appears on prod                                       | POST /api/production-orders                 |
| `order-created-started`        | New PO row + immediately starts running                          | POST /api/production-orders + change-status |
| `order-started`                | Existing PO transitions to running                               | POST /api/production-orders/start           |
| `order-changed`                | Operator stopped current PO to swap to a new one                 | POST /api/production-orders/stop            |
| `order-stopped`                | Operator stopped current PO without replacement                  | POST /api/production-orders/stop            |
| `order-replaced`               | Edit-in-place: same PO row gets new quantity / id_order          | POST /api/production-orders/replace         |
| `event-justified`              | Operator justified a downtime with category + sub-category       | POST /api/downtimes/justify                 |
| `event-edited`                 | Operator edited a previously-justified downtime                  | POST /api/downtimes/edit                    |
| `event-splitted`               | Operator split a single downtime into N smaller intervals        | POST /api/downtimes/split                   |
| `downtime-event-created`       | Auto-upserted batch of equipment status events from edge devices (status=running/stopped). Payload is `{events: [{topic, status, timestamp, idEquipment}]}`. Each event's `idEquipment` is translated prod→staging; `topic` is `C-PACK/` → `CPACK/` remapped (cosmetic — staging's upsert ignores it but DB-side audit logs stay consistent). | POST /api/downtimes                         |

One eventType is **not** ported: `order-time-changed`. Prod has no UI
that emits it currently — defer until the feature lands on prod.

---

## Observability

Two layers, complementary:

### Prometheus metrics (live, from /metrics)

| Metric                                       | Type      | Labels                  | What it tells you                                     |
|----------------------------------------------|-----------|--------------------------|-------------------------------------------------------|
| `mirror_worker_user_logs_polled_total`       | Counter   | event_type               | rows attempted                                        |
| `mirror_worker_user_logs_replayed_total`     | Counter   | event_type, outcome      | ok / failed / skipped breakdown                       |
| `mirror_worker_replay_duration_seconds`      | Histogram | event_type               | p50/p95/p99 handler latency                           |
| `mirror_worker_cursor_lag_seconds`           | Gauge     | (none)                   | "is staging within N seconds of prod?"                |
| `mirror_worker_id_map_cache_size`            | Gauge     | (none)                   | mirror_id_map growth signal                           |

Plus the standard `go_*` + `process_*` collectors (goroutines, RSS, GC).

### Postgres-side tables (persistent state)

- `mirror_replay_cursor` — last replayed `user_logs.id` per source.
- `mirror_id_map` — every prod ID → staging ID translation ever made.
- `mirror_replay_dlq` — rows that failed replay; for triage.

### Dashboard

`grafana/dashboards/07-mirror-worker.json` mixes both layers: Prometheus
panels for live rates + latency + cursor lag; Postgres panels for DLQ
depth + mapping growth + recent failed-row drilldown. Same dashboard
serves both the Go worker (today) and the historical TS-source data
(filterable in the SQL panels).

---

## Where to look next

- Adding a new eventType: `internal/replay/<new_type>.go` + register it
  in `cmd/mirror-worker-go/main.go`. Use `order_status_changed.go` as a
  minimal template; `order_created.go` if you need to insert a
  `mirror_id_map` row (creating a new entity).
- Tuning the interval-overlap threshold:
  `cfg.EventMinOverlapSec` (env var `EVENT_MIN_OVERLAP_SEC`).
- Reading DLQ rows: `SELECT * FROM mirror_replay_dlq WHERE source =
  'cpack-prod-go' ORDER BY id DESC LIMIT 20;` — or the
  recent-failed-rows panel in the Grafana dashboard.
- Pausing replay (e.g. for staging maintenance): `docker stop
  mirror-worker-go`; cursor freezes; restart picks up where it left off.
