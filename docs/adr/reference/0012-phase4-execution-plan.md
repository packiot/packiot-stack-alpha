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
2. **Writer inventory — DONE 2026-07-02** (SELECT-only on prod tsp12 +
   staging + repo grep). Results below. Headline: the inventory
   COLLAPSES the wave scope — on prod only **6 of the 29 named objects
   are tables**; 23 are plain views needing no writer cutover at all,
   and 3 of the 6 tables are dead.

## Writer inventory (ground truth: prod tsp12, 2026-07-02)

### Real tables with live writers → Wave 2 scope (3 objects)

| Object | Writers | Prod activity |
|---|---|---|
| `report_shift_enterprsie_06` | PL/pgSQL: `update_report_shift_enterprsie_06`, `_06b`, `get_data_sync_enterprsie_06`, `_06b`, `update_equipment_validation_shift` | HOT — 11.1M ins + 11.1M del (delete-and-reload refresh), analyzed today |
| `report_speed_enterprsie_33` | PL/pgSQL: `c33_speed_per_job_insert_into_report`, `piot_cust_speed_product_client_33` | warm — 1.8k ins, 36k seq reads |
| `sap_report_data_sync_customer_13` | PL/pgSQL `upsert_sap_report_data_sync_customer_13` **+ EXTERNAL: back4-api `data-sync.controller.js` (neopac integration)** | VERY HOT — 18.4M upd, 12.9M idx reads |

The sap_report cutover requires back4-api coordination — it is the only
object with a non-PL/pgSQL writer.

### Dead tables → contract-wave DROP candidates (3 objects)

`c35_dashboard_paradas_24h`, `c35_dashboard_producao_24h`,
`c35_dashboard_timeline_24h`: **zero writes since stats reset, one
lifetime seq_scan, zero idx_scans** on prod — but 0.1–5.4M stale rows
each. No writer exists in pg_proc (prod or staging) nor in any repo.
Retired dashboards. Get c35 PowerBI owner sign-off, then drop in the
contract wave — do NOT build pool tables for them.

### Views (23 objects) → Wave 3 only

All remaining c33_*/c35_v_*/v_13_*/v13_* objects are plain views on
prod. They need no writer cutover and no backfill — only re-pointing at
pool/canonical base tables when those move, then the compat gate's
column-shape + planner dimensions.

### ⚠ Staging drift discovered — new Wave 0

**21 of the 23 prod views exist as TABLES on staging** — the staging
bootstrap (`edge-node-red/db/00-schema.sql`) materialized them.
Consequence: staging cannot rehearse the view-flip waves until these
are recreated as views with prod definitions (fetch via
`pg_get_viewdef` on prod, SELECT-only). This is Wave 0.

### Not resolvable with current access

Prod `cron.job` is permission-denied for the `awslambda` role, so the
refresh CADENCE of the 3 live tables is inferred from stats, not read
from the schedule. Reading it needs the elevated-access path already
flagged for Phase 5.

## Wave plan (expand → cutover → façade → contract)

Scope after inventory: Wave 0 fixes staging's view-vs-table drift;
Waves 1–2 cover only the 3 live tables; Wave 3 handles the 23 views;
the 3 dead c35 dashboards skip straight to the contract wave.

### Wave 0 — staging parity repair — ✅ DONE 2026-07-02
- (Count correction vs the first inventory pass: **15** staging tables
  were prod-views, not 21 — the earlier figure double-counted the 6
  real tables.)
- All 23 prod view definitions captured via `pg_get_viewdef`
  (SELECT-only) → `0012-wave0-prod-view-defs.sql` (repo ground truth)
- All 15 drifted tables flipped to views with per-object transactions;
  the `v13_mobile_power_bi_direct_query` dependency trio flipped in one
  atomic group. **Every prod definition compiled against staging base
  tables — zero failures.** Flip targets were all empty (0 rows) with
  no readers on staging.
- Gate PASSED: 29/29 relkind parity with prod + SELECT probes green on
  all 16 recreated views + Hasura healthy (it tracks these names)

### Wave 1 — expand: pool tables + backfill — ✅ DONE 2026-07-02
- `customer_reports` pool schema created with canonical tables for the
  3 live objects: `shift` (cust 6, +(customer_id, day) index), `speed`
  (cust 33, +(customer_id, job_start)), `sap_data_sync` (cust 13,
  UNIQUE (customer_id, linie, tag, shicht, auftrag_key) extending
  prod's pk_sap_sync upsert key — back4-api must target this at
  Wave 2 cutover)
- SQL: `0012-wave1-customer-reports-pool.sql`, idempotent, applied to
  packiot_shadow (rehearsal) FIRST, then staging packiot
- Rehearsal caught a real defect: packiot_shadow's Hasura-parity STUB
  tables share names with prod report tables but not shapes — backfill
  is now per-table fail-soft (NOTICE + skip on shape mismatch)
- Gate PASSED both DBs: column counts = source+1 exactly (24/10/21)
- Backfill no-op'd on staging — the per-customer sources are EMPTY
  there (their writers were never scheduled on staging; staging cron
  has only 4 jobs). Pool rows arrive via Wave 2 dual-write; prod
  backfill happens at Phase 5 with real data
- Wave 2 prep: all 9 writer function bodies captured to
  `0012-wave2-prod-writer-funcs.sql` (8 names — get_data_sync_
  enterprsie_06 has 2 overloads)

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
