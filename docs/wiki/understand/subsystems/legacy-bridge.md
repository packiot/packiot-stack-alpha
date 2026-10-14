---
title: Legacy bridge
layer: 2
owner_area: legacy-bridge
last_verified: 2026-10-13
---
# Legacy bridge

> **Layer 2 · Subsystems** — how state that still originates in the legacy platform
> (`packiot40`) reaches the new analytics DB on staging, what is copied and what is not. For
> engineers debugging "why does staging not match legacy?" and for anyone planning the cutover.
> Up: [Architecture overview](../architecture/overview.md)

## Purpose

Production clients still run on the legacy platform (legacy DB `packiot40`, "tsp12", Hasura,
Node-RED oeecloud). CPACK's operators start and stop production orders (POs) and justify
downtimes in the **legacy** apps, and since 2026-10-07 CPACK's PLC downtime events also reach
legacy through Google Pub/Sub without an audit row. The new stack receives CPACK's *telemetry*
through the factory tee, but not those actions and events. The legacy bridge copies them into
the analytics DB (`packiot_analytics`) so staging enterprise 3 is a faithful, live **twin** of
CPACK, and the sandbox 2000003 a second twin. It is migration scaffolding that exists on
**staging only**: `compose.production.yml` has no replicator. When a client cuts over, its
operators write to edge-api directly and its bridge is switched off.

## Boundaries

**Owns**

- Replaying legacy operator actions (`user_logs` rows) for one legacy enterprise into one
  analytics enterprise: PO lifecycle, PO runtime windows, downtime classifications, splits.
- Reconciling legacy tables against the twin by reading them directly: production orders
  (missing, stuck, drifted headers and windows), product/client enrichment, PLC base events,
  manual downtimes.
- The bookkeeping tables `ops.mirror_replay_cursor`, `ops.mirror_replay_dlq` and
  `ops.legacy_manual_event_link`.

**Does not own**

- **Telemetry.** Counters and machine state arrive through edge / ingestion (tee → broker →
  decoder → stream-engine); see [Ingestion](ingestion.md). The sandbox's telemetry is a
  re-tenanted copy made by `oeecloud-fanout`.
- **OEE math.** The bridge writes raw facts and sets `recalc_needed = true`; the
  [compute](compute.md) jobs derive every number.
- **Configuration** (sites, areas, equipment, shifts, routing). The CPACK twin's configuration
  was cloned once; the sandbox is re-cloned by its self-heal (see
  [Simulators & twins](../components/simulators-and-twins.md)).
- **History before the replay window.** It came from one-off backfills and the historian
  archive (see [Historian](historian.md)).
- **Writes back to legacy.** The legacy DB is read with the SELECT-only `awslambda` login
  (Secrets Manager `databaseCredentials`, copied into the app host `.env`) and never written.

## Components

| Component | What it does | Runtime | Status (staging) | Layer 3 |
|---|---|---|---|---|
| `legacy-replicator` | legacy ent 1 → analytics ent 3: `user_logs` replay, PO reconciler (+ convergence, enrich), base-event and manual-event reconcilers, DLQ retrier | Go, `services/analytics-sync/cmd/legacy-replicator` (`Dockerfile.replicator`) | **Running** (`REPLICATE_ENABLED=true`) | [analytics-sync](../components/analytics-sync.md) |
| `legacy-replicator-sbx` | same binary: legacy ent 1 → sandbox ent 2000003, with the sandbox hold gate | same image | default off; on through `.env` `REPLICATE_SBX_ENABLED=true` | [analytics-sync](../components/analytics-sync.md) |
| `analytics-sync` (shadow-mirror) | in-instance replay of the frozen staging F1 `packiot` `user_logs` | Go, `services/analytics-sync/cmd/shadow-mirror` | **Idle** (`SHADOW_MIRROR_ENABLED=false`); its source froze around 2026-08-18 | [analytics-sync](../components/analytics-sync.md) |
| `mirror-worker-go` | earlier legacy → staging mirror through edge-api HTTP, plus a comparator | Go, `services/mirror-worker-go` | **Retired 2026-08-13**; only under compose profile `legacy-comparator` | [mirror-worker](../components/mirror-worker.md) |

None of these serve HTTP APIs beyond `/healthz` and `/metrics`; they have rows in the
[Service catalog](../../reference/service-catalog.md) but no API reference page.

## How it works

```text
 legacy platform (production)                       new stack (staging)
 ─────────────────────────────                      ─────────────────────────────
 operator apps ──▶ legacy edge-api ──▶ packiot40 ◀── legacy oeecloud ◀── Pub/Sub ◀── CPACK edge
                      (user_logs audit)   │  user_logs, production_orders(_runtime),
                                          │  products, clients, equipment_events(_man),
                                          │  packml_register
                                          │ SELECT-only (awslambda)
                                          ▼
   ┌──────── legacy-replicator ───────────────────────────────┐
   │ replay   every 3 s: user_logs WHERE id_enterprise=1      │
   │          AND id_user_logs > cursor → handler by category │
   │          ids: ent 1→3, equipment by packml base topic,   │   packiot_analytics
   │          PO by (id_enterprise, id_order); idempotent     │──▶ core.production_orders
   │          failure → ops.mirror_replay_dlq, cursor moves   │    core.products / clients
   │ PO reconciler   300 s, 14 d (+ converge, enrich 120 d)   │    gold.production_orders_runtime
   │ base events     120 s, 96 h lookback                     │    silver.equipment_events
   │ manual events   300 s, 35 d lookback                     │    silver.equipment_events_man
   │ DLQ retrier     120 s, backoff, 5 attempts               │    ops.mirror_replay_*
   └──────────────────────────────────────────────────────────┘
 CPACK factory tee ──▶ ingestion ──▶ stream-engine ──▶ same analytics DB
                                     (closer, PO compute read what the bridge wrote)
```

No single pass is complete, so several cooperate:

1. **Event replay** of `user_logs`. It is *event-sourced*: it can only reproduce state that
   produced an audit row. 14 categories are registered (8 PO categories, downtime create /
   justify / edit / split, and two manual-event categories that stand down when the manual
   reconciler is on).
2. **PO reconciler** (`reconcile.go`). Diffs legacy `production_orders` against the twin by
   `(id_enterprise, id_order)`: inserts POs the replay never saw (pre-existing POs started
   through `order-changed`, PLC-created POs), finishes twin POs stuck at status 2, and opens a
   runtime window for any PO with a start but no window (since 2026-10-02). Since 2026-10-09 it
   also **converges** on legacy (`reconcile_converge.go`): retimes finished headers, reverts
   POs legacy holds as available, and makes a settled PO's windows exactly legacy's
   `production_orders_runtime` rows (overlap-guarded).
3. **Enrich pass** (`enrich.go`). Legacy attaches product and client outside the audit trail;
   enrich copies them by natural key, only into NULL columns.
4. **Base-event reconciler** (`base_reconcile.go`, 2026-10-09). Reads legacy PLC events
   (`forced_creation_system = false`) directly and inserts the ones the twin lacks
   (`ON CONFLICT DO NOTHING`, ±1 s dedupe). Needed since the CPACK edge switched to Pub/Sub on
   2026-10-07 and stopped producing `downtime-event-created` audit rows; without it, stops
   stayed open forever.
5. **Manual-event reconciler** (`manual_reconcile.go`). Mirrors legacy `equipment_events_man`
   into `silver.equipment_events_man` with inserts, edits, moved start times and deletes of
   rows it owns (provenance in `ops.legacy_manual_event_link`); it is the sole writer of
   mirrored manual events. Both event reconcilers refresh `serving.downtime_events_resolved`
   for the days they touched.

On staging, edge-api blocks every PO write route for enterprise 3
(`OPERATOR_WRITE_BLOCKED_ENTERPRISES=3` → 403 `MIRROR_TENANT_WRITE_BLOCKED`), so the bridge is
the only writer of CPACK POs; test PO writes on the sandbox 2000003. On the sandbox, the hold
gate (`SANDBOX_HOLD_ENABLED`, `ops.sandbox_hold_mode`) pauses or skips replay while a person
holds the twin or a heal runs, and the reconcilers skip their passes.

## Interfaces

| Direction | Protocol | Object | Producer → consumer |
|---|---|---|---|
| In | Postgres (SELECT only) | legacy `user_logs`, `production_orders`, `production_orders_runtime`, `products`, `product_families`, `clients`, `equipment_events`, `equipment_events_man`, `packml_register` | `packiot40` → replicator |
| Out | Postgres (direct to the DB host) | `core.production_orders`, `core.products`, `core.product_families`, `core.clients` | replicator → compute, read-api, Superset |
| Out | Postgres | `gold.production_orders_runtime` (windows, `recalc_needed`) | replicator → stream-engine PO compute |
| Out | Postgres | `silver.equipment_events` (base events, classifications, split segments), `silver.equipment_events_man`, `serving.downtime_events_resolved` refresh | replicator → serving functions, operator app |
| Out | Postgres | `ops.mirror_replay_cursor`, `ops.mirror_replay_dlq`, `ops.legacy_manual_event_link` | replicator (own bookkeeping) |
| Out | HTTP `/metrics`, `/healthz` | `:9104` (sbx `:9114`) | replicator → Prometheus, Docker healthcheck |

## What is and is not replicated

| Data | Replicated? | How |
|---|---|---|
| PO create / start / stop / change / time change / replace / status change | Yes | `user_logs` handlers |
| POs that never hit `user_logs`; header drift | Yes | PO reconciler + convergence (14-day window) |
| PO product and client | Yes (NULL-fill only) | enrich pass (120-day window) |
| PO runtime windows | Yes | replayed starts (overlap-guarded), reconciler backfill, convergence to legacy's runtime rows |
| Base PLC downtime events | Yes | replay of `downtime-event-created` (`forced_creation_system=false`) + base-event reconciler (96 h lookback); a telemetry-derived row wins on conflict |
| Downtime justification / edit | Yes | exact `(id_equipment, ts_event)` match, then interval-overlap fallback |
| Splits | Yes | split segments into `silver.equipment_events` |
| Manual downtimes | Yes | manual-event reconciler (35-day lookback, max 50 deletes per pass) |
| Telemetry, counters, machine state | No | edge / ingestion tee |
| Configuration (sites, areas, equipment, shifts, targets, reasons) | No | one-off clone; sandbox self-heal |
| Users, roles, api keys, logins | No | managed in the new stack |
| Scanned boxes, samples | No | new-stack apps only |

## Data it owns

| Object | Lifecycle |
|---|---|
| `ops.mirror_replay_cursor` | One row per `source` (`legacy-cpack`, `legacy-sbxcpack`, `shadow-mirror`, historical `cpack-prod-go`). Cold start seeds it at the start of the backfill window (`BACKFILL_SINCE_DAYS`, default 60). Moves forward only. |
| `ops.mirror_replay_dlq` | One row per failed dispatch; deleted when a retry succeeds; kept after `DLQ_RETRY_MAX_ATTEMPTS` (default 5). Also holds mirror-worker-go's historical rows (keyed by `source`). |
| `ops.legacy_manual_event_link` | Maps each mirrored manual event to its legacy id; makes the manual reconciler's deletes safe. |

The replayed business rows belong to the [Analytics DB](analytics-db.md).

## Configuration that matters

Code defaults ship inert (`REPLICATE_ENABLED` and every `RECONCILE_*_ENABLED` default `false`);
staging turns them on in `compose.staging.yml`.

| Knob | Staging | Effect |
|---|---|---|
| `REPLICATE_ENABLED` | `true` (ent 3); `${REPLICATE_SBX_ENABLED:-false}` (sbx) | master switch; `false` serves only `/healthz` + `/metrics` |
| `SRC_ENTERPRISE` / `DST_ENTERPRISE` | `1` → `3`; `1` → `2000003` | which legacy tenant is replayed and where it lands |
| `CURSOR_SOURCE` | `legacy-cpack`; `legacy-sbxcpack` | separate cursors per instance |
| `RECONCILE_PO_ENABLED` / `_INTERVAL_SEC` / `_WINDOW_DAYS` | `true` / 300 / 14 | PO reconciler and convergence |
| `RECONCILE_PO_ENRICH_ENABLED` / `_WINDOW_DAYS` | `true` / 120 | product/client enrich |
| `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS` | `true` (ent 3, default); `false` (sbx) | create a missing dimension with legacy's id; must be `false` for an id-offset tenant |
| `REPLICATE_BASE_EVENTS` | `true` | replay `downtime-event-created` |
| `RECONCILE_BASE_EVENTS_ENABLED` / `_LOOKBACK_HOURS` | `true` / 96 | base-event reconciler |
| `RECONCILE_MANUAL_EVENTS_ENABLED` / `_LOOKBACK_DAYS` / `_MAX_DELETES` | `true` / 35 / 50 | manual-event reconciler (and turns off the manual-event replay handlers) |
| `SANDBOX_HOLD_ENABLED` | sbx only, `true` | honour the sandbox hold modes |
| `HEALTHCHECK_MAX_AGE_SEC` | 600 | `/healthz` turns 503 if no successful poll for 10 min |

Full table: [analytics-sync configuration](../components/analytics-sync.md#configuration).

## Failure modes & signals

| Symptom | Likely cause | Where to look |
|---|---|---|
| POs in legacy but missing in analytics | equipment unresolved (the resolver is built once at startup from both `packml_register`s) | `legacy_replicator_reconcile_unresolved_total`; DLQ rows `unresolved equipment`; restart the replicator after config changes |
| PO start/end or windows differ from legacy | drift the replay cannot express (re-starts, time changes, reverts) | convergence counters in the replicator log; it should converge within a pass or two |
| Stops never close on the twin | base events missing (e.g. the 2026-10-07 Pub/Sub switch) | `legacy_replicator_base_events_total`; latest `ts_event` per machine vs legacy |
| Operator justifications do not show up | no twin base event (exact and overlap both missed) | log `event-classified: no twin base event`; alert `ReplicatorReplayGaps` |
| Manual downtimes missing or stale | manual reconciler off or failing | `legacy_replicator_manual_events_total` |
| DLQ depth growing | a handler error class (e.g. 23P01 runtime-window overlap before #1335) | `legacy_replicator_dlq_depth`; `SELECT category, error, count(*) FROM ops.mirror_replay_dlq GROUP BY 1,2` |
| Container unhealthy | legacy DB unreachable or loop wedged | `/healthz` 503; log `fetch batch failed` |
| Overview "Client / Product" blank | enrich off or window too short | `legacy_replicator_reconcile_enriched_total` |
| CPACK POs changed by a staging test | someone wrote to ent 3 before the write block (2026-10-09) | write tests on 2000003 only |

## History & decisions

- **ADR-0013** ([shadow-mirror service](../../adr/0013-shadow-mirror-service.md)): an app-level
  poller over `user_logs` instead of triggers + dblink or logical replication, because the
  two schemas may diverge. Both analytics-sync binaries follow it.
- **ADR-0025** ([three-flow PO reconciliation](../../adr/0025-three-flow-po-state-reconciliation.md))
  and **ADR-0032** ([collapse to single flow F3](../../adr/0032-collapse-to-single-flow-f3.md))
  explain why the old F1/F2/F3 flows and the shadow-mirror are retired scaffolding.
- **2026-08-13** — mirror-worker-go retired; CPACK lines on the tee died upstream the same day,
  which is why the replicator also inserts base events.
- **2026-08-27** — hardening: interval-overlap fallback, DLQ + retrier, split segments moved to
  `equipment_events`, PO reconciler.
- **2026-09-20** — 1,374 DLQ rows from runtime-window exclusion errors (23P01); fixed with an
  equipment-scoped overlap guard (PR #1335). The first "fix" PRs merged without the code
  change: verify merged code, not PR titles.
- **2026-09-23 / 09-25** — runtime windows resolved from the PO row (PR #1389); enrich pass
  (PR #1452); base events written as PLC-born (#1455).
- **2026-10-02** — reconciler backfills missing runtime windows (#1555).
- **2026-09-29** — manual-event reconciler (the replay had silently dropped manual events
  since the 2026-09-13 shim drop).
- **2026-10-07 → 10-09** — CPACK edge moved to Pub/Sub → base-event reconciler (#1664); PO
  header/window convergence (#1674); PO writes to ent 3 blocked in edge-api on staging
  (edge-api #298).

## Go deeper

- [analytics-sync (legacy-replicator + shadow-mirror)](../components/analytics-sync.md)
- [mirror-worker (retired)](../components/mirror-worker.md)
- [Sandbox twin](../components/sandbox-twin.md) — sandbox twin, self-heal, hold modes
- [Simulators & twins](../components/simulators-and-twins.md) — simulators and synthetic twins
- [Analytics DB](analytics-db.md) · [Compute](compute.md) · [Serving & APIs](serving-apis.md)
- [Service catalog](../../reference/service-catalog.md)
- [Environments](../architecture/environments.md) — which tenant gets data from where
