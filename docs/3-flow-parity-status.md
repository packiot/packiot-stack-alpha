# 3-Flow parity status + remaining work (ADR-0012)

- **Status**: Interim (2026-07-02)
- **Depends on**: ADR-0010 (Go decode), ADR-0012 (schema refactor + packiot_shadow), ADR-0013 (shadow-mirror), ADR-0014 (OEE math extraction)

## Goal

Flows 1, 2, and 3 receive **identical** data:

| Flow | Destination | Currently populated? |
|---|---|---|
| 1 | `packiot.public.*` | ✅ Fully — mirror-worker + edge-nodered simulator + oeecloud-worker default |
| 2 | `packiot.shadow_go_port.*` | ⚠️ Partial — equipment_values only |
| 3 | `packiot_shadow.public.*` | ⚠️ Partial — equipment_values only |

"Identical" means: same rows in same schemas, with same downstream
derivations (equipment_events, runtime aggregates, PO scoring).

## Where we stand today

### Data plane (equipment_values) — 3 flows PROVEN identical

- edge-transformer dual-emits `source_type=go` + `source_type=refactored`
  for every MQTT event
- oeecloud-worker's routing table lands each into the correct destination
- Byte-identical rows verified 2026-07-01 (Flow 2 = Flow 3 for the same
  synthetic inject)
- **Gap**: staging's real data source (edge-nodered simulator) doesn't
  route through edge-transformer, so Flow 2 + 3 only get injects, not
  simulator data. Flow 1 has real ongoing data from all sources.

### Control plane (operator actions) — shadow-mirror IDLE

- shadow-mirror shipped with 10 handlers covering ~90%+ of daily
  volume (PRs #175, #178, #179)
- `SHADOW_MIRROR_ENABLED=false` by default → no polling, no writes
- **Blocker**: target tables (`equipment_events_man`, `production_orders`)
  don't exist in `packiot.shadow_go_port` or `packiot_shadow.public`.
  Handler is fail-open on 42P01 so enabling would produce warn logs, not
  writes.

### Derived data (equipment_events, runtime aggregates) — trigger-derived

- 1 trigger on `packiot.public.equipment_values`
  (`piot_set_shift_before_insert`)
- ~20 PL/pgSQL functions under `piot_*` computing runtime rollups
- pg_cron schedules the rollup functions
- **Blocker**: `packiot.shadow_go_port` and `packiot_shadow` don't
  have these triggers / functions / cron jobs. ADR-0014 proposes
  moving the compute out of PostgreSQL entirely.

## Concrete remaining work

### PR-scale (small, ship in current session or next)

1. **Migration: add missing tables to `packiot.shadow_go_port`**
   - `equipment_events_man` (55 cols matching `packiot.public.equipment_events_man`)
   - `production_orders` (matching public)
   - `downtimes` (if we implement `downtime-event-created` later)
   - Migration file: `edge-api/migrations/YYYYMMDD_shadow_go_port_operator_tables.ts`

2. **SQL: add missing tables to `packiot_shadow.public`**
   - Extend `docs/adr/reference/0012-phase3-writer-tables.sql`
   - Same shape as public.equipment_events_man + public.production_orders
   - Auto-applied by `scripts/reprovision-refactor-sandbox.sh --db-name packiot_shadow`

3. **Enable shadow-mirror**
   - Flip `SHADOW_MIRROR_ENABLED=true` in `compose.staging.yml`
   - Verify it starts polling + writing to both shadow paths
   - Grafana panel showing cursor advance + dispatched/skipped/failed counters

### ADR-scale (bigger, span multiple sessions)

4. **ADR-0014 Phase 2** — port `piot_set_shift_before_insert` to Go
   - oeecloud-worker resolver → id_shift/id_shift_hour/id_team lookups
   - Comparator-based bake window (168h zero-divergence gate)
   - Retire trigger on packiot.public after bake

5. **ADR-0014 Phase 3+** — port remaining PL/pgSQL to Go / TimescaleDB CAggs
   - piot_create_equipment_runtime_* → CAggs
   - piot_create_area_runtime_* → Go emissions
   - piot4_13_* customer-specific → per-customer Go handlers

6. **ADR-0012 Phase 4** — real-staging migration
   - Knex migrations transitioning production_orders / c33_* / c35_*
     into `customer_dashboards` pool schema + façade views
   - PowerBI compatibility test plan (docs/powerbi-compatibility-test-plan.md)
     as promotion gate
   - Roll out to real staging DB
   - After bake, roll out to prod

### Data-source parity (post-ADR-0014)

7. **Make simulator + mirror-worker route through edge-transformer's
   dual-emit** — or extend those services to fan out equipment_values
   INSERTs to all 3 destinations
   - Simplest: extend `services/mirror-worker-go/internal/db/staging.go`
     `InsertEquipmentValueDelta` to loop over `["public", "shadow_go_port"]`
     schemas on main pool + optional `packiot_shadow.public` on shadow pool
   - Once ADR-0014 lands, this becomes trivial (same routing table)

## Acceptance criteria for "100% parity"

- [ ] All 3 destinations have identical `equipment_values` rows within a
      60-second window (measured by comparator like ADR-0008)
- [ ] All 3 destinations have identical `equipment_events` (once
      derivation moves to Go per ADR-0014)
- [ ] All 3 destinations have identical `production_orders` after shadow-mirror
      is enabled + tables provisioned
- [ ] Grafana dashboard `/d/3-flow-parity` shows continuous
      0-divergence for 7 days

## Session tally (this arc, 2026-07-01 → 2026-07-02)

- 12 PRs merged
- 4 new ADRs (0012, 0013, 0014 + PowerBI test plan)
- 3 new services / features (oeecloud-worker shadow pool, edge-transformer
  dual-emit, shadow-mirror with 10 handlers)
- 3 DBs live on staging (packiot, packiot_refactor, packiot_shadow)
- $0 additional AWS cost
- 3-flow POC verified end-to-end
- Foundation laid for full parity — remaining work is well-scoped
