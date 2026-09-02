# analytics-sync (formerly shadow-mirror)

**Control-plane replayer — temporary by design (retires at the flip,
R1).** Operator actions land in the main DB via edge-api; this service
replays them onto the shadow flow so the analytics plane sees the same POs, manual
events, and edits as F1 during the migration bake. ADR-0013 chose this
app-level poller over trigger+dblink and logical replication precisely
because the two schemas are allowed to diverge.

## How it works

- **Not a queue consumer.** Polls `packiot.public.user_logs` on a
  cursor (`mirror_replay_cursor`, source `shadow-mirror`), batch by
  batch (`POLL_INTERVAL_MS`, `BATCH_SIZE`).
- Dispatches on `user_logs.category` to ~11 handlers in
  `internal/replay/handlers/` (order-created/-started/-stopped/…,
  manual-event-created/-edited, event-splitted) — each re-applies the
  equivalent SQL to BOTH shadow paths: `shadow_go_port.*` (main pool)
  and `packiot_analytics.public.*` (second pool).
- **Idempotent by unique keys**: `production_orders`
  (id_enterprise,id_order) + one-running-PO partial index;
  `equipment_events_man` on ts_event. Re-polls are safe.
- Fail-open on missing tables (42P01) so a partially-provisioned
  shadow doesn't wedge the loop.

## Config

`PG_DB_NAME` (source, `packiot`) · `PG_SHADOW_DB_NAME`
(`packiot_analytics`; empty = degrade to shadow_go_port only) ·
`POLL_INTERVAL_MS` · `BATCH_SIZE` · `MAX_RETRIES` · `HEALTH_PORT`.
DB host is the staging DB EC2 directly (pgbouncer's static DB list
excludes the shadow DB). Creds via `.env` (SM fetch is a TODO).

## Invariants / gotchas

- Exactly **two** sinks, hard-wired; the cursor source is a const —
  a second instance against another DB needs a code change (this is
  deliberate: labs pull with fdw instead, see
  `docs/adr/reference/migrations/0012-sandbox-live-feed.sql` header).
- Cold start seeds the cursor at `MAX(id_user_logs)` — it replays the
  future, not history (history is the mirror-worker's job).
- After the flip, edge-api writes the consolidated DB directly and
  this service is removed from compose (R1). Don't build on it.

## Sibling: `cmd/legacy-replicator` (cross-instance twin replicator)

Same module, second entrypoint. Where analytics-sync mirrors control-plane
actions *within* one instance (F1 packiot → shadow/analytics), the
legacy-replicator mirrors them *across* instances: it replays CPACK operator
actions from the **legacy production DB** (`packiot40`, enterprise 1 "C-PACK",
SELECT-only) into the **staging** analytics plane (`packiot_analytics`,
enterprise 3), so staging is a faithful **twin** of what factory operators do
live. Needed because the SparkPlug tee carries only telemetry (and only some
lines since 2026-08-13) — operators' PO/downtime/justify actions never reached
the twin, so its state was stale.

Reuses the same philosophy (poll `user_logs` on a cursor, dispatch by
category, re-apply idempotently by NATURAL KEY) and adds the one new problem
the in-instance mirror never had — an **id-mapping layer at the boundary**
(`internal/replicate/resolver.go`):

- **enterprise**: fixed configured map (1 → 3).
- **equipment**: legacy `id_equipment` → packml BASE topic (enterprise-name
  prefix stripped) → staging `id_equipment`. `C-PACK/SC/LINHAS/L5/BREYER` and
  `CPACK/SC/LINHAS/L5/BREYER` both normalise to `SC/LINHAS/L5/BREYER`.
  Equipment NAMES are NOT unique in CPACK (BREYER/TEXA/PTH repeat across
  lines) — the topic path is the only stable key. `id_site`/`id_area` come
  from the resolved *staging* equipments row, never the legacy payload.
- **PO**: keyed by `(id_enterprise, id_order)`; the legacy surrogate
  `id_production_order` is resolved to its natural `id_order` from the legacy
  DB, never written into staging (bug-248 discipline, across instances).

Differences from the in-instance handlers: single-dest (no `shadow_go_port`);
`equipment_events_man` inserts OMIT `id_equipment_event` (staging IDENTITY
serial — copying the legacy serial would collide); `downtime-event-created`
IS replayed (into `equipment_events`, idempotent on `(id_equipment,ts_event)`)
because the tee doesn't carry every line; payloads use `flexInt64` since
legacy edge-api emits some numerics as quoted strings.

**Config** (env): `REPLICATE_ENABLED` (master toggle, default false) ·
`LEGACY_DB_*` (source) · `DEST_DB_*` (staging) · `SRC_ENTERPRISE`/
`DST_ENTERPRISE` · `BACKFILL_SINCE_DAYS` (cold-start history depth, default
60) or `BACKFILL_SINCE=YYYY-MM-DD` · `REPLICATE_BASE_EVENTS` ·
`CURSOR_SOURCE` (default `legacy-cpack` — distinct from analytics-sync's
`shadow-mirror`, stored in the DEST DB since the source is read-only).

The cursor cold-starts just below the first legacy row in the backfill window
(history first, then live) and is idempotent on re-run.

### legacy-replicator residual hardening (2026-08-27)

Three replay-fidelity residuals closed (`internal/replicate`):

1. **Event interval-overlap fallback** (`handlers.go`, `EventClassified` +
   `EventSplitted`). `event-justified` / `-edited` now try an EXACT
   `(id_equipment, ts_event)` classification UPDATE first, then fall back to the
   interval-overlap matcher ported from `mirror-worker-go`
   (`translate.EquipmentEvent`): the same-`(equipment,status)` twin event whose
   `[ts_event, ts_end]` window overlaps the legacy event's by
   `>= EVENT_MIN_OVERLAP_SEC` (default 30), staging `ts_event` no earlier than
   `legacy_start - EVENT_MAX_START_DRIFT_SEC` (default 600). Exact-first is
   deliberate and non-regressive — unlike mirror-worker-go, this replicator
   inserts its own twin base rows at the exact legacy ts (`DowntimeEventCreated`),
   so exact already matches ~96% live; overlap only recovers the tee-drifted
   remainder. (The bulk of the historical noop is base events legacy never logged
   to `user_logs` — a separate completeness gap the matcher cannot close.)

2. **Replay DLQ** (`dlq.go`). The loop still advances the cursor on every row,
   but a *failed* dispatch (e.g. the `production_orders_runtime` 23P01 window
   race) is now captured into `mirror_replay_dlq` before advancing, and a bounded
   exponential-backoff retrier (`DLQRetrier`, `DLQ_RETRY_*`) re-drives it through
   the same handler set — deleting on success, retiring at the cap. Source-keyed,
   additive, reversible. Metrics: `legacy_replicator_dlq_{retried_total,depth}`.

3. **event-splitted table-target fix** (`handlers.go`, `EventSplitted`). Split
   segments now land in `equipment_events` (auto, `forced_creation_system=true`)
   matching legacy `downtimes-dao.ts::split`, NOT `equipment_events_man` — the
   old handler polluted the twin's manual table (forced split rows vs a handful
   of genuine legacy manual events). Segment 0 shrinks the matched twin base
   event in place (located exact-then-overlap); segments 1..N-1 are inserted as
   new forced auto events. Historical mis-inserted `_man` rows are NOT deleted
   (a documented reversible cleanup is proposed separately).
