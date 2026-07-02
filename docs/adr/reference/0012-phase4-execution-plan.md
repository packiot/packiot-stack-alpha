# ADR-0012 Phase 4 — real-staging migration execution plan

- **Status**: Plan (2026-07-02) — expands ADR-0012 §Phase 4 into a
  concrete PR series
- **Gate**: `docs/powerbi-compatibility-test-plan.md` (37 objects ×
  5 dimensions) after EVERY wave
- **POC baseline**: 4 façades live in `packiot_shadow` +
  `packiot_refactor` (0012-poc-customer-dashboards.sql) — planner
  inlining of `WHERE customer_id = N` proven

## Scope

37 PowerBI-facing objects: 18 customer-dashboard objects (c33_*, c35_*
groups) + 19 customer-13 SAP/PowerBI views. POC covered 4; **33 remain**.
Target shape: `customer_dashboards.*` / `customer_reports.*` pool tables
(customer_id column) + per-customer façade views preserving every
existing public.* name.

## Sequencing constraint — do these FIRST

1. **Task #86 (Hasura decision) before any wave.** Every wave otherwise
   pays the metadata re-tracking tax on 165 tracked tables — the exact
   friction that provoked the Hasura review. If the pilot (edge-api
   REST) proceeds, Phase 4 loses a whole class of coordination steps.
   If Hasura stays, add a "re-track + verify 7 named queries" step to
   every wave below.
2. **Writer inventory (verification step, no code).** For each of the
   33 objects, capture from the staging DB: writing pg_cron function
   (piot4_13_* etc.), refresh cadence, and downstream view dependents
   (schema-map audit has the dependency counts; this needs the names).
   Store as a reference table in this file before Wave 1 lands.
   An object whose writer is unknown does NOT enter a wave.

## Wave plan (expand → cutover → façade → contract)

### Wave 1 — expand: pool tables + backfill (1 PR per object group)
- Create `customer_dashboards.<name>` pool tables (customer_id column,
  composite indexes `(customer_id, <hot filter>)` per POC pattern)
- Backfill from the per-customer tables (`INSERT … SELECT … , 33 AS
  customer_id`)
- Old tables stay live and written — zero consumer impact
- Gate: presence + column-shape dimensions only (rows arrive in Wave 2)

### Wave 2 — writer cutover (1 PR per pg_cron function)
- Each piot4_* writer gains pool-table writes (dual-write window), old
  table writes retained
- NOTE the ADR-0014 interaction: functions already scheduled for a Go
  port should be ported ONCE, directly to the pool shape — do not pay
  the PL/pgSQL edit twice. Check `docs/adr/0014-*.md` Phase 3/4 list
  before touching a function here.
- Bake ≥72h: row-count + byte-sample dimensions comparing old table vs
  pool slice
- Gate: all 5 dimensions green per object

### Wave 3 — façade flip (1 PR per customer group)
- `DROP TABLE public.c35_<name>` → `CREATE VIEW public.c35_<name> AS
  SELECT … FROM customer_dashboards.<name> WHERE customer_id = 35`
  (inside one transaction per object; POC-proven inline pattern)
- Writers stop writing the old per-customer tables (single-write to
  pool)
- Gate: planner push-down dimension is the critical one here (EXPLAIN
  must show the composite index scan, not a seq scan under the view)
- Rollback: views are cheap — `DROP VIEW` + restore table from pool
  slice (`CREATE TABLE AS SELECT`) in minutes

### Wave 4 — contract: retire duplicates (single PR, after 30-day soak)
- Version-suffixed siblings from the schema audit
  (`shift_agg_from_events{,_v2,_v3,_v4}`, `v_operator_po_details{,_2,_3}`,
  `v_events{,_2}`) — drop non-canonical versions after confirming zero
  idx_scans over the soak window (pg_stat_user_tables /
  pg_stat_user_indexes deltas — the deploy-CI audit queries already
  collect baselines)
- `monitoramento_execucao_functions` (67MB, 0 reads) drops here too

## Standing rules for every wave

- SELECT-only against prod, always — Phase 4 is STAGING; prod is
  Phase 5 (ADR-0012) with its own longer bakes
- Expand-contract discipline: a wave never drops what the previous
  wave created a replacement for until its gate passed + soak elapsed
- Every PR body carries the durability checklist + the PowerBI gate
  results table
- 3-flow POC keeps running throughout — `packiot_shadow` receives each
  wave FIRST (via reprovision script update) as the rehearsal, real
  staging second

## Phase 5 (prod) preconditions — recorded now so nobody improvises

- All 37 objects green on staging for a full month-boundary cycle
  (month rollover exercises the widest CAgg windows)
- PowerBI report owners sign off per customer group (c33, c35, c13)
- edge-api knex migration series mirrors the staging SQL exactly
- Elevated DB access path agreed (awslambda role cannot DDL — a
  migration role is a prerequisite, see tsp12 pg_dump findings)
