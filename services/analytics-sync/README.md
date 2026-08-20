# analytics-sync (formerly shadow-mirror)

**Control-plane replayer — temporary by design (retires at the flip,
R1).** Operator actions land in the main DB via edge-api; this service
replays them onto the shadow flow so F3 sees the same POs, manual
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
  and `packiot_shadow.public.*` (second pool).
- **Idempotent by unique keys**: `production_orders`
  (id_enterprise,id_order) + one-running-PO partial index;
  `equipment_events_man` on ts_event. Re-polls are safe.
- Fail-open on missing tables (42P01) so a partially-provisioned
  shadow doesn't wedge the loop.

## Config

`PG_DB_NAME` (source, `packiot`) · `PG_SHADOW_DB_NAME`
(`packiot_shadow`; empty = degrade to shadow_go_port only) ·
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
