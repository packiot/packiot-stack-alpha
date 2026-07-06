# ADR-0012 — Schema refactor: multi-tenancy pool pattern + naming unification

- **Status**: Accepted — in execution (Waves 0–2 done, Wave 3 partial, Wave 4 prepared; blessed 2026-07-06)
- **Deciders**: Emmanuel Podestá (Packiot backend)
- **Context repo**: `packiot-stack-alpha` (session 73)

## Context

Prod DB `packiot40` (aka legacy label "tsp12") on TimescaleDB has 203 tables + 134 views + 10 matviews in `public`. The schema is the accumulated sediment of ~5 years of feature development, per-customer onboarding, and iterated "let's do this right this time" refactors that never finished.

**Observed pathologies** (audit 2026-07-01, see [[project_staging_db_schema_map]]):

1. **Multi-tenancy anti-pattern — tenant ID embedded in the table name**:
   - `c35_dashboard_producao_24h`, `c33_dashboard_producao_24h`, `c35_v_stopped_time`, `c35_v_shifts_data`, `c35_v_dashboard_timeline`
   - `report_shift_enterprsie_06`, `report_speed_enterprsie_33` (also misspelled `enterprsie`)
   - `sap_report_data_sync_customer_13`, `equipment_boxes_cust_13`
   - Consequences: schema DDL on every customer onboarding, no cross-customer analytics, PowerBI reports diverge per customer

2. **Naming-scheme divergence — 3 parallel conventions for continuous aggregates**:
   - `agg_*` (9 legacy, uncompressed)
   - `ca_agg_*` (4 newer, some compressed)
   - `ca_*` (4 discrete/mv-style)
   - Same conceptual object, three names — new engineers must learn all three

3. **Version-suffix accumulation**:
   - `shift_agg_from_events` + `_v2` + `_v3` + `_v4` — each rev added, older ones never retired
   - `v_operator_po_details` + `_2` + `_3`
   - `v_events` + `v_events_2`
   - No documentation of which is canonical; developers pick by copy-paste from nearest code

4. **Opaque suffixes with lost meaning**:
   - `agg_equipment_values_1min_t` — `_t` means "TimescaleDB hypertable", but storage engine has no business in a table name
   - `mv_agg_equipment_values_1min_full_hot`, `_full_warm` — `full/hot/warm` naming from a superseded caching design
   - `dt5min_po_func_ret` — cryptic legacy

5. **pt-BR legacy names**:
   - `monitoramento_execucao_functions` — 2 GB / 28 M rows on prod, 0 index scans, insert-only log
   - Function-execution audit that predates English-only convention

6. **Unused indexes on the hottest table**:
   - 9 composite indexes on `equipment_values` with 0 `idx_scan` since last stats reset
   - Each replicates onto ~1400 chunks (hypertable) — real storage cost + INSERT maintenance cost

7. **Orphan materialized views**:
   - 10× `mv_agg_equipment_values_*_full_hot|_warm` — all 8 kB, 0 rows, never analyzed on prod
   - 3× `agg_equipment_values_*_archive` — 2 MB / 640 kB / etc., unused
   - `hasura_test` — literally a test artifact

## Decision

Adopt the **pool multi-tenancy pattern** with **façade views** to preserve every existing PowerBI-facing name during the transition. Consolidate CAgg naming to a single `ca_*` prefix. Rename opaque suffixes. Retire redundant siblings. Drop unused indexes and zero-row orphans.

### Multi-tenancy: pool + façade pattern

**Canonical target schema** (`customer_dashboards`, `customer_reports`):

```sql
CREATE SCHEMA customer_dashboards;

CREATE TABLE customer_dashboards.dashboard_producao_24h (
    customer_id integer NOT NULL,
    ts_value    timestamptz NOT NULL,
    ... existing columns from c35/c33 ...,
    PRIMARY KEY (customer_id, ts_value, ...)
);
CREATE INDEX ON customer_dashboards.dashboard_producao_24h (customer_id, ts_value DESC);

-- Similar canonical tables for the other 5 c35/c33 dashboard objects
-- and the sap_report_data_sync_customer_13 family
```

**Façade views preserving every historical PowerBI-facing name**:

```sql
-- PowerBI queries against public.c35_dashboard_producao_24h keep working
CREATE VIEW public.c35_dashboard_producao_24h AS
    SELECT ts_value, ...cols excluding customer_id...
    FROM customer_dashboards.dashboard_producao_24h
    WHERE customer_id = 35;

CREATE VIEW public.c33_dashboard_producao_24h AS
    SELECT ts_value, ...cols...
    FROM customer_dashboards.dashboard_producao_24h
    WHERE customer_id = 33;
```

**Guarantees**:
- **PowerBI reports unmodified**: exact same names, exact same columns, exact same row shape
- **Cross-customer analytics enabled**: `SELECT customer_id, SUM(rows) FROM customer_dashboards.dashboard_producao_24h GROUP BY 1`
- **New customer onboarding**: `INSERT` rows with new customer_id — no DDL required
- **One set of triggers / policies / retention** per canonical table instead of N

### CAgg naming: unified `ca_*` prefix

- `agg_equipment_values_1min_t` → `ca_equipment_values_1min` (canonical, keep façade)
- `agg_equipment_values_10min|1hour|1day|1week|1month` → `ca_equipment_values_*` (retire duplicates if `ca_agg_*` already exists)
- `agg_area_values_*`, `agg_site_values_*` → `ca_area_values_*`, `ca_site_values_*`
- `mv_agg_equipment_values_*_full_hot|warm` → **drop** (retired design, 0 rows on prod)
- Enable compression on all uncompressed CAggs

### Naming unification

| Current | New |
|---|---|
| `agg_equipment_values_1min_t` | `ca_equipment_values_1min` |
| `monitoramento_execucao_functions` | `function_execution_log` |
| `dt5min_po_func_ret` | `dt5min_po_function_returns` |
| `report_shift_enterprsie_06` | `report_shift_enterprise_06` (also becomes a façade on new canonical `customer_reports.shift`) |
| `report_speed_enterprsie_33` | `report_speed_enterprise_33` |
| `equipment_boxes_cust_13` | `customer_reports.equipment_boxes` (with customer_id column) |

Version suffixes: for each `X + X_v2 + X_v3 + X_v4` family, identify canonical (typically the one with dependents), drop others. If none is clearly canonical, promote the latest one (`_v4`) and rename to unsuffixed name.

### Dead-code drops (verified 0-consumers)

- 9 unused composite indexes on `equipment_values`
- 3× `agg_equipment_values_*_archive` matviews
- 10× `mv_agg_equipment_values_*_full_hot|warm` matviews
- `hasura_test` table
- `data_sync_enterprise_06`, `data_sync_enterprise_06b`, `downtime_sync_enterprise_06` (all empty on prod)

## Consequences

### Positive

- **Interface preserved**: every PowerBI report keeps working; no customer coordination required for the refactor itself
- **Storage reduction**: ~10-15 GB from dropping unused indexes on `equipment_values` chunks alone; more from retiring the `_archive`/`_hot`/`_warm` matviews
- **Operational simplification**: single canonical table per concept, single retention policy, single CAgg refresh
- **Cross-customer analytics unlocked** (was previously N-way UNION)
- **New customer onboarding**: INSERT rows, no schema DDL, no migration per customer
- **Cognitive load reduction**: naming conventions unified; new engineers learn one CAgg pattern instead of three

### Negative

- **Migration complexity**: expand-contract with backward-compat views on real staging → prod
- **Write-path migration**: pg_cron jobs / triggers that today write to `c35_dashboard_producao_24h` need to migrate to writing `customer_dashboards.dashboard_producao_24h` with `customer_id=35`
- **PowerBI-side eventual cleanup**: façade views should be retired after PowerBI reports refactored to canonical names — but this is opt-in per customer report update cycle

### Risks

- **Query planner regressions**: the pool pattern with `WHERE customer_id = X` filter push-down needs to match the raw table performance. Prove out on sandbox with prod-scale data before real-staging migration.
- **Hasura re-tracking**: every renamed table needs to be re-tracked in Hasura Cloud (prod) + Hasura Docker (staging). This is admin panel work.
- **Backfill migration cost**: moving c35/c33 data into `customer_dashboards.dashboard_producao_24h` with the correct customer_id is a one-time large migration. Requires careful staging.

## Implementation phases

### Phase 0 — Sandbox setup (session 73)
- ✅ Provision `packiot_refactor` DB on staging host
- ✅ Load schema from `edge-node-red/db/17-hasura-metadata-parity.sql`

### Phase 1 — POC on sandbox (session 73)
- Implement `customer_dashboards` schema + all canonical tables
- Implement façade views (~15 names preserved)
- Load synthetic sample data (100 rows per customer, 5 customers)
- Verify query patterns: filter by customer_id, cross-customer aggregation, façade transparency

### Phase 2 — Renames + drops on sandbox (session 73)
- Rename opaque tables (drop `_t`, drop `_v2/_v3/_v4`, fix `enterprsie` typos)
- Drop unused indexes (9 composite indexes on equipment_values)
- Drop `_archive` matviews (3)
- Drop `mv_*_full_hot|warm` (10)
- Drop `hasura_test` and `data_sync_enterprise_06*` legacy

### Sandbox live feed + naming sweep (2026-07-06)
- ✅ Shadow insertions: `packiot_shadow` → `packiot_refactor` incremental
  pull (postgres_fdw loopback + TimescaleDB `add_job`, 1-min cadence;
  `0012-sandbox-live-feed.sql`) — zero changes to running services;
  `equipment_values` is now a real hypertable feeding a real
  `ca_equipment_values_1min` CAgg (fixes the Phase-1 naming drift vs
  this ADR's table: canonical is `ca_*`, old names are façades)
- ✅ h_*/v_* naming sweep on sandbox (`0012-sandbox-naming-sweep-a/b.sql`,
  map: `reference/0012-naming-map.md`) — 34 canonical renames, 18
  duplicates retired, every legacy name preserved as a compat view;
  Hasura-parity check green (101/101 tracked names resolve)

### Phase 3 — CAgg consolidation on sandbox (session 74+)
- Consolidate `agg_*` + `ca_agg_*` + `mv_agg_*` → `ca_*`
- Enable compression on 9 uncompressed CAggs
- Fix `agg_equipment_values_1min_t_invalidation` refresh policy (75 GB queue on prod)

### Phase 4 — Real-staging migration plan (session 74+)
- Draft expand-contract migration series for real staging DB
- One PR per logical group (multi-tenancy consolidation, naming, drops)
- Each PR: canonical DDL + backward-compat shims + Hasura re-tracking

### Phase 5 — Production migration (quarter-scale)
- Follow the same series against prod tsp12/packiot40 via edge-api knex migrations
- Longer bake windows between expand and contract
- Coordination checkpoints with PowerBI report owners for eventual façade retirement

## References

- [[project_staging_db_schema_map]] — full audit of current state
- [[reference_prod_tsp12_audit_query_bank]] — SELECT-only queries for prod verification
- ADR-0011 — durability boundary (this refactor honors: schema changes cross the boundary carefully)
- ADR-0008 — comparator-as-fidelity-watchdog (validation pattern reused for refactor migration)
- Industry precedent: Stripe multi-tenancy (account_id column + row-level filtering), Shopify shop_id pattern, PostgreSQL Row-Level Security docs
