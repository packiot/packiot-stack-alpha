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
