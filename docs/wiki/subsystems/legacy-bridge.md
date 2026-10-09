---
title: Legacy bridge
layer: 2
owner_area: legacy-bridge
last_verified: 2026-09-28
---
# Legacy bridge

> **Layer 2 · Subsystems** — how state that still originates in the legacy platform
> (`packiot40`) reaches the new analytics DB, what is copied and what is not. For engineers
> debugging "why does staging not match legacy?" and for anyone planning the cutover.
> Up: [Architecture overview](../architecture/overview.md)

## Purpose

Production customers still run on the legacy platform (legacy DB `packiot40`, "tsp12",
Hasura, Node-RED oeecloud). Factory operators start and stop production orders (POs) and
justify downtimes in the **legacy** operator app, so those actions are recorded only in the
legacy DB. The new stack receives the same factory *telemetry* through the Sparkplug co-tee,
but not the operator *actions*. The legacy bridge replays those actions into the analytics
DB (`packiot_analytics`) so staging is a faithful, live **twin** of what a real factory is
doing. It is migration scaffolding: when a client cuts over, its operators write to edge-api
directly and the bridge for that client is switched off.

## Boundaries

**Owns**

- Replaying legacy operator actions (`user_logs` rows) for one legacy enterprise into one
  analytics enterprise: PO lifecycle, PO runtime windows, base downtime events, downtime
  classifications, manual downtimes, downtime splits.
- Reconciling legacy `production_orders` against the twin (missing POs, zombie running POs).
- Filling `id_product` / `id_client` on twin POs from legacy (the *enrich* pass).
- The replay bookkeeping tables `ops.mirror_replay_cursor` and `ops.mirror_replay_dlq`.

**Does not own**

- **Telemetry.** Counters and machine state arrive through the edge / ingestion path
  (co-tee → broker → decoder → stream-engine), not through this bridge. See
  [Ingestion](ingestion.md).
- **OEE math.** The bridge only writes raw facts and sets `recalc_needed = true`; the
  [compute](compute.md) jobs derive every number.
- **Configuration** (sites, areas, equipment, shifts, `packml_register`). The CPACK twin's
  configuration was cloned once; the sandbox is re-cloned by its self-heal script (see
  [Simulators & twins](../components/simulators-and-twins.md)).
- **Legacy history before the replay window.** Old history came from one-off backfills and
  the historian archive, not from the live replay (see [Historian](historian.md)).
- **Writes back to legacy.** The legacy DB is read with a SELECT-only role and is never
  written.

## Components

| Component | What it does | Runtime | Status (staging) | Layer 3 |
|---|---|---|---|---|
| `legacy-replicator` | Replays CPACK (legacy ent 1) actions into analytics ent 3; PO reconciler, enrich pass, DLQ retrier | Go, `services/analytics-sync/cmd/legacy-replicator` | **Running** (`REPLICATE_ENABLED=true`) | [analytics-sync](../components/analytics-sync.md) |
| `legacy-replicator-sbx` | Second instance of the same binary: legacy ent 1 → sandbox ent 2000003 | same image | Compose default off; turned on through `.env` (`REPLICATE_SBX_ENABLED`) | [analytics-sync](../components/analytics-sync.md) |
| `analytics-sync` (shadow-mirror) | In-instance replay of the staging F1 `packiot` `user_logs` into `packiot_analytics` | Go, `services/analytics-sync/cmd/shadow-mirror` | **Idle** (`SHADOW_MIRROR_ENABLED=false`); its source froze around 2026-08-18 | [analytics-sync](../components/analytics-sync.md) |
| `mirror-worker-go` | Earlier legacy → staging mirror that replayed through edge-api HTTP, plus value/event sync and a comparator | Go, `services/mirror-worker-go` | **Retired 2026-08-13**, profile-gated off (`legacy-comparator`) | [mirror-worker](../components/mirror-worker.md) |

## How it works

```text
 legacy platform (production)                    new stack (staging)
 ──────────────────────────────                  ──────────────────────────────
 operator app / PLC ──▶ legacy edge-api ──▶ packiot40
                               │  user_logs (audit trail, per enterprise)
                               │  production_orders, products, clients,
                               │  equipment_events, packml_register
                               │
                               │ SELECT-only role (secret `databaseCredentials`)
                               ▼
    ┌──────── legacy-replicator (poll every 3 s) ─────────┐
    │ 1. read user_logs WHERE id_enterprise=1              │
    │    AND id_user_logs > cursor                         │
    │ 2. dispatch by category → handler                    │
    │ 3. map ids: ent 1→3, equipment by packml base topic, │
    │    PO by (id_enterprise, id_order)                   │   packiot_analytics
    │ 4. idempotent write (ON CONFLICT / guarded UPDATE)   │──▶ core.production_orders
    │ 5. failure → ops.mirror_replay_dlq; advance cursor   │    gold.production_orders_runtime
    ├── PO reconciler (every 300 s, 14-day window)         │    silver.equipment_events
    │   + enrich pass (120-day window)                     │    equipment_events_man
    └── DLQ retrier (every 120 s, backoff, 5 attempts) ────┘    ops.mirror_replay_*

 factory telemetry ──▶ co-tee ──▶ ingestion ──▶ stream-engine ──▶ same analytics DB
                                                (reads recalc_needed, runtime windows)
```

Three passes cooperate because no single one is complete:

1. **Event replay** of `user_logs`. It is *event-sourced*: it can only reproduce state that
   produced an audit row. Operator actions always do; some PO transitions do not.
2. **PO reconciler.** Diffs legacy `production_orders` against the twin by
   `(id_enterprise, id_order)`. It inserts POs the replay never saw (POs started through
   `order-changed` without `shouldCreatePo`, PLC-created POs) and finishes twin POs stuck
   at status 2 whose legacy row is finished or paused. On 2026-08-27 the twin held only 81
   of legacy's 123 distinct orders over 7 days, which is why this pass exists.
3. **Enrich pass.** Legacy attaches product and client outside the audit trail, so neither
   pass above carries them. Enrich copies them by natural key (product/client *name*), only
   into NULL columns (PR #1452, 2026-09-25: September coverage went from 0 to 793 of 1,285
   POs).

## Interfaces

| Direction | Protocol | Object | Producer → consumer |
|---|---|---|---|
| In | Postgres (SELECT only) | legacy `user_logs`, `production_orders`, `products`, `product_families`, `clients`, `equipment_events`, `equipment_events_man`, `packml_register` | `packiot40` → legacy-replicator |
| Out | Postgres | `core.production_orders`, `core.products`, `core.product_families`, `core.clients` | legacy-replicator → compute, read-api, Superset |
| Out | Postgres | `gold.production_orders_runtime` (runtime windows, `recalc_needed`) | legacy-replicator → stream-engine PO runtime compute |
| Out | Postgres | `silver.equipment_events` (base events, classifications, split segments), `public.equipment_events_man` | legacy-replicator → serving functions, operator app |
| Out | Postgres | `ops.mirror_replay_cursor`, `ops.mirror_replay_dlq` | legacy-replicator (own bookkeeping) |
| Out | HTTP `/metrics`, `/healthz` | `:9104` (sbx `:9114`) | legacy-replicator → Prometheus job `legacy-replicator`, docker healthcheck |

## What is and is not replicated

| Data | Replicated? | How |
|---|---|---|
| PO create / start / stop / pause / change / time change / replace / status change | Yes | `user_logs` handlers (8 of the 14 registered categories) |
| POs that never hit `user_logs` | Yes | PO reconciler (14-day window) |
| PO product and client | Yes (NULL-fill only) | Enrich pass (120-day window) |
| PO runtime windows | Yes, for replayed starts | `openRuntimeWindow` (overlap-guarded). Reconciler-inserted POs get **no** window (documented limitation) |
| Base PLC downtime events (`downtime-event-created`) | Yes | Inserted with `forced_creation_system=false` (PLC-born), `ON CONFLICT DO NOTHING` so a telemetry-derived row wins |
| Downtime justification / edit | Yes | Exact `(id_equipment, ts_event)` match, then interval-overlap fallback |
| Manual downtimes, splits | Yes | `equipment_events_man` inserts; split segments into `equipment_events` |
| Telemetry, counters, machine state | No | Edge/ingestion co-tee |
| Configuration (sites, areas, equipment, shifts, targets, reasons) | No | One-off clone; sandbox self-heal |
| Users, roles, api keys | No | Managed in the new stack (csadmin) |
| Scanned boxes, samples | No | New-stack apps only |
| Logins | No | edge-api deliberately does not log them |

## Data it owns

| Object | Lifecycle |
|---|---|
| `ops.mirror_replay_cursor` | One row per `source` (`legacy-cpack`, `legacy-sbxcpack`, `shadow-mirror`, historical `cpack-prod-go`). Created on demand; cold start seeds it just below the first legacy row in the backfill window (`BACKFILL_SINCE_DAYS`, default 60). Moves forward only. |
| `ops.mirror_replay_dlq` | One row per failed dispatch; deleted when a retry succeeds; kept (exhausted) after `DLQ_RETRY_MAX_ATTEMPTS`. Shared with mirror-worker-go's historical rows (keyed by `source`). |

The replayed business rows themselves belong to the [Analytics DB](analytics-db.md).

## Configuration that matters

| Knob | Staging | Effect |
|---|---|---|
| `REPLICATE_ENABLED` | `true` (ent 3), `.env`-driven (sbx) | Master switch; `false` serves only `/healthz` + `/metrics` |
| `SRC_ENTERPRISE` / `DST_ENTERPRISE` | `1` → `3`; `1` → `2000003` | Which legacy tenant is replayed and where it lands |
| `RECONCILE_PO_ENABLED` | `true` | PO reconciler on/off |
| `RECONCILE_PO_ENRICH_ENABLED` / `_WINDOW_DAYS` | `true` / `120` | Product/client enrich |
| `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS` | `true` (ent 3), `false` (sbx) | Whether a missing dimension is created with legacy's id. Must be `false` for an id-offset tenant |
| `REPLICATE_BASE_EVENTS` | `true` | Insert base PLC events (the co-tee does not carry every CPACK line) |
| `HEALTHCHECK_MAX_AGE_SEC` | `600` | `/healthz` turns 503 if no successful poll for 10 min |

Full table: [analytics-sync configuration](../components/analytics-sync.md#configuration).

## Failure modes & signals

| Symptom | Likely cause | Where to look |
|---|---|---|
| POs present in legacy but missing in analytics | Equipment unresolved at replay (resolver built at startup), or the PO never produced a `user_logs` row | `legacy_replicator_reconcile_unresolved_total`; DLQ rows with `unresolved equipment`; restart the replicator after config changes |
| Operator justifications do not show up | No twin base event (exact and overlap both missed) | Log `event-classified: no twin base event`; alert `ReplicatorReplayGaps` (`shadow_mirror_update_noop_total{job="legacy-replicator"}`) |
| DLQ depth growing | A handler error class (e.g. 23P01 runtime-window overlap before #1335) | `legacy_replicator_dlq_depth`; `SELECT category, error, count(*) FROM ops.mirror_replay_dlq GROUP BY 1,2` |
| Container unhealthy | Legacy DB unreachable or loop wedged | `/healthz` 503; log `fetch batch failed` |
| Overview "Client / Product" blank | Enrich off or window too short | `legacy_replicator_reconcile_enriched_total` |
| Operator "PO downtime" reads 0 | Base events flagged `forced_creation_system=true` (fixed #1455, 2026-09-25) | `serving.v_operator_po_details_3` sums only `fcs=false` events |

## History & decisions

- **ADR-0013** ([shadow-mirror service](../adr/0013-shadow-mirror-service.md)): an app-level
  poller over `user_logs` instead of triggers + dblink or logical replication, because the
  two schemas are allowed to diverge. Both analytics-sync binaries follow it.
- **ADR-0025** ([three-flow PO reconciliation](../adr/0025-three-flow-po-state-reconciliation.md))
  and **ADR-0032** ([collapse to single flow F3](../adr/0032-collapse-to-single-flow-f3.md))
  explain why the old F1/F2/F3 "flows" and the shadow-mirror are retired scaffolding.
- **2026-08-13**: mirror-worker-go retired; CPACK lines on the co-tee died upstream the same
  day, which is why the replicator also inserts base events.
- **2026-08-27**: replicator hardening: interval-overlap fallback, DLQ + retrier, split
  segments moved to `equipment_events`, PO reconciler.
- **2026-09-20**: DLQ of 1,374 rows from runtime-window exclusion errors (23P01) under
  out-of-order replay; fixed with an equipment-scoped `&&` overlap guard (PR #1335) and
  drained. The first "fix" PRs (#1332/#1333) merged without the code change: verify merged
  code, not PR titles.
- **2026-09-23**: 58% of replayed CPACK POs had no runtime window because `order-started`
  only opened one when the payload's equipment resolved; now resolved from the PO row
  (PR #1389) and backfilled.
- **2026-09-25**: enrich pass (PR #1452, sandbox #1453); base events now written as
  PLC-born `forced_creation_system=false` (#1455) with 256,306 flags backfilled.

## Go deeper

- [analytics-sync (legacy-replicator + shadow-mirror)](../components/analytics-sync.md)
- [mirror-worker (retired)](../components/mirror-worker.md)
- [Analytics DB](analytics-db.md) · [Compute](compute.md) · [Serving & APIs](serving-apis.md)
- [Environments](../architecture/environments.md) (which tenant gets data from where)
