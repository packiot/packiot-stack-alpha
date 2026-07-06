# Phase 5 (prod migration) — readiness pack

- **Status**: Prepared 2026-07-06. Everything below is either DONE,
  self-running (clock), or waiting on a named human — no unstarted
  engineering remains before Phase 5 planning can execute.
- **Companions**: `0016-flip-runbook.md` (staging flip),
  `0012-phase4-execution-plan.md` (wave history),
  `migrations/0012-wave4-contract.sql` (prepared contract),
  `docs/powerbi-compat-report.md` + `docs/powerbi-evidence-prod-read.md`
  (gate evidence, regenerated today).

## 1. Gate board (single source of truth)

| # | Gate | State | Owner / clock |
|---|---|---|---|
| G1 | Full-surface bake 7d green | ⏳ clock → ~2026-07-13 | 09-bake dashboard daily |
| G2 | Shift-resolver close-out | ⏳ clock → 2026-07-09 | runbook in repo docs |
| G3 | PowerBI 37+1 sign-off | 🟡 evidence READY (compat report PROMOTABLE + prod-read fidelity regenerated) | human |
| G4 | sap_13 port or deferral | 🟡 port BUILT + staged disabled; contract posted on #223 | back4-api owner |
| G5 | c35 drop sign-off | 🟡 evidence + prepared §C posted on #224 | c35 PowerBI owner |
| G6 | Prod Hasura creds + #225 recheck | 🔴 needs creds; window closes 2026-08-01 | user |
| G7 | 10.9 prod payload capture | 🔴 needs factory access | user |
| G8 | Elevated prod DB role | 🔴 prerequisite spec in §4 | user/infra |

When G1–G5 read green → execute the flip runbook (~30 min) → R1–R9
retirements → 30-day soak starts (Wave-4 baseline §A captured AT flip).

## 2. Prod migration sequence (mirrors staging exactly)

Execute via edge-api knex migrations (submodule; series materialized at
Phase-5 open). One migration per staging SQL artifact, same order:

| # | knex migration (proposed name) | Mirrors staging artifact | Notes |
|---|---|---|---|
| 1 | `phase5_01_customer_reports_pool` | `0012-wave1-customer-reports-pool.sql` | additive; backfill from live per-customer tables (prod HAS data — staging didn't) |
| 2 | `phase5_02_report_writer_cutover` | compose flags speed33/shift06/sap13 → prod worker | ≥72h dual-run bake per writer; prod cron writers stay until parity |
| 3 | `phase5_03_facade_flips` | `0012-wave3-flip2-as-executed.sql` pattern ×3 | one tx per object; PowerBI gate re-run after each |
| 4 | `phase5_04_cagg_adoption` | `staging-parity-cagg-adoption.sql` + hierarchical ca_agg chain | includes §3 invalidation fix FIRST |
| 5 | `phase5_05_wave4_contract` | `0012-wave4-contract.sql` | after prod's own 30-day soak; §B preflight mandatory |
| 6 | (deferred) h_*/v_* naming wave | `0012-sandbox-naming-sweep-a/b.sql` + `0012-naming-map.md` | GATED on task #86 (Hasura); on prod, h_* are function return types — ALTER FUNCTION + re-track in lockstep |

Standing rules: SELECT-only until the migration role exists (G8);
expand-contract discipline; every step gets the PowerBI gate re-run;
bake windows LONGER than staging (quarter-scale plan per ADR-0012).

## 3. The 75 GB invalidation-queue fix (prod, before CAgg adoption)

`agg_equipment_values_1min_t_invalidation` = 75 GB / 495M rows on prod —
refresh backlog growing faster than it drains. Recipe (diagnostics
pre-written in `0012-phase2-cagg-consolidation.sql` §DIAGNOSTIC):

1. Read the refresh job lag: `timescaledb_information.jobs` ⋈ `job_stats`
   for the `_materialized_hypertable_NNN` behind `agg_equipment_values_1min_t`.
2. Shorten `schedule_interval` (`alter_job`) so drain rate > arrival rate —
   staging-proven value: 30–60s (vs prod's current, unreadable to awslambda).
3. Monitor `_timescaledb_catalog.*invalidation*log` count until steady-state.
4. Only THEN adopt the hierarchical ca_* chain (mechanism swap): prod's
   hand-rolled 1min_t feeder subsystem is NOT ported — it's obsoleted
   (same as staging; see naming-ledger + session-77 engine map).
5. Expected reclaim: ~75 GB + the 9 unused equipment_values indexes
   (~10–15 GB across chunks) from the ADR-0012 dead-drops list.

Requires G8 (awslambda can't `alter_job`).

## 4. Elevated prod role — prerequisite spec (G8)

A `migration_role` with: DDL on `public`, `customer_reports`,
`customer_dashboards`; `alter_job`/TimescaleDB admin;
`cron.job` read (today permission-denied — cadence of legacy writers is
still inferred, not read); NO superuser. Time-boxed per migration
window, audit-logged. awslambda stays SELECT-only forever (the
BEGIN READ ONLY discipline survives Phase 5).

## 5. Month-boundary + calendar

- **2026-07-09**: G2 close-out (drop F1 shift trigger, widen fill gate).
- **~2026-07-13**: G1 bake window complete.
- **2026-08-01**: Hasura query-log window closes (task #86 decision
  input) + first month-boundary on the consolidated flow → run the
  widest-CAgg-window checks (#225) same day.
- **Flip + 30d**: Wave-4 §B preflight → contract. Old-DB freeze expiry
  → R4/R8 drops (EBS snapshot first).
- **Phase-5 sign-off precondition**: all 37+1 green across ONE FULL
  month-boundary cycle on staging (ADR-0012 §Phase 5).

## 6. Deliberately NOT ported (decision log)

- `piot_cust_speed_product_client_33` (PO-notes blurb writer) and
  `update_equipment_validation_shift` (validation-table maintainer):
  secondary writers, not PowerBI-gate objects; they keep running as
  prod PL/pgSQL and keep working post-flip via façades. Port-or-retire
  decision belongs to the prod migration window (candidate: retire
  with owner sign-off — both are consumer-side conveniences).
- c35 dashboard pool tables: never built (dead on prod) — gate parity
  maintained via same-shape façades until §C drops them.

## 7. Today's additions (2026-07-06, this readiness pass)

- sap13 Go port staged disabled (Wave-2 code COMPLETE) — #223 now a
  pure decision.
- PowerBI gate harness (`scripts/test-powerbi-compatibility.sh`) +
  30-object canonical list + first PROMOTABLE run.
- Prod-read fidelity evidence regenerated (98.6% shift06 exact —
  baseline-consistent; 96% speed33).
- Wave-4 contract SQL prepared with soak preflight.
- Gate comments posted: #223 (contract), #224 (evidence), #225 (dates).
