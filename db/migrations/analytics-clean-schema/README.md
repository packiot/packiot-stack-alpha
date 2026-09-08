# analytics-clean-schema — Phases 0–2 (applied on STAGING 2026-09-08)

Executes `docs/plans/analytics-clean-schema-redesign.md` Phases 0–2 on staging
`packiot_analytics` (PG 15.17 / TimescaleDB, DB EC2 10.10.10.89, box
`i-06c9547a2c7091ab7`). Expand/contract, additive-first. Every step hardproofed
live. **Phases 3–5 are gated on the P2 equivalence proof and are NOT in this set.**

## Files (order = apply order)

| File | Phase | What |
|---|---|---|
| `../../superset/02-tenant-rls.sql` (edited) | P0a | Repointed RLS from `equipment_runtime_shift/_1hour` (gone after the runtime_→oee_ cutover) to `equipment_oee_shift/equipment_oee_hourly`. Fresh apply now succeeds (was 42P01). |
| `../../init-f3/MANIFEST.f3-target` (edited) | P0b | `equipment_runtime_*`→`equipment_oee_*` (hashes unchanged — pure rename) + added the live read surface `production_information` + customer SAP views. |
| `03_p0c_drop_dead_objects.sql` | P0c | Backs up data-bearing tables into schema `drop_backup_20260908`, then drops the hardproof-dead objects (9 fns, 11 views, 18 tables, `*_history` twins + writer trigger/fn, schema `cutover`). |
| `04_p1_silver_metrics_family.sql` | P1 | Creates `silver.equipment_metrics_{1min,10min,1hour,1day}` — one hierarchical cagg family (decomposable partials). |
| (refresh) | P1 | Oldest-first bottom-up catch-up: `CALL refresh_continuous_aggregate('silver.equipment_metrics_<tier>', '2026-07-01', '2026-09-09')` for 1min→10min→1hour→1day. |
| `05_p1_silver_refresh_policies.sql` | P1 | `add_continuous_aggregate_policy` on EVERY tier (the #196 lesson) + a 4/4 assertion. |
| `06_p2_bi_next_security_invoker_views.sql` | P2 | Parallel `bi_next.*` — all 10 contract views rebuilt `WITH (security_invoker=true)` for the equivalence gate. |
| `07_p2_serving_layer.sql` | P2 | `serving.machine_speed` (silver-backed) + `serving.oee_score_row` composite TYPE + `serving.oee_score` canonical-A·P·Q function (§4 pattern; two-definition bug not reproduced). |

## Reversibility

- **Drops**: DDL is recoverable from `db/init-f3/snapshot/00-packiot_analytics-schema.sql`
  and `edge-node-red/db/*.sql`. Data for the data-bearing drops is preserved in
  schema `drop_backup_20260908` (totalizer 19406, hist_production_orders 20627,
  hist_production_orders_runtime 20590, twin_backfill_po_log 140, equipments_history
  754, + areas/enterprises/sites_history). Drop that schema only after cutover sign-off.
- **`*_history` twins**: decision §8.2 = DROP. The `trg_scd2_history` trigger +
  `log_dimension_history()` writer were dropped first (writer-audit discipline).
  To restore, recreate from `docs/adr/reference/migrations/0039-dimension-scd2-history.sql`.
- **silver / bi_next / serving**: additive — `DROP SCHEMA … CASCADE` to reverse. The
  legacy `agg_*`/`ca_agg_*` families were left running in parallel (untouched).

## Objects HELD from the doc §3 drop list (writer-audit / consumer catches)

These were listed for drop in the plan but proven live and excluded:
`equipment_values_raw`, `equipment_events_raw` (live Bronze writer in
stream-engine `oeecloud-worker`); `equipment_oee_shift_weekly`,
`equipment_oee_shift_monthly` (active provisioning + `unmetered.go` writer +
`h_piot_get_targets` reader); `site_live_day` (front4 + uns refresher);
`v_13_overview_takt`, `v_13_overview_partial_scrap_rate`, `oee_targets` (read-api
datasets + front4); `shifts_exception_period` (join in `piot_create_equipment_runtime_shift`);
`equipment_events_low_speed`, `h_events_timeline_full`,
`h_piot_production_orders_with_runtimes_table2` (bodies of live CONTRACT functions);
`function_execution_log` (backs the manifest-kept view `monitoramento_execucao_functions`).
`scanned_boxes`/`sample_boxes`/`box_scans`/`po_box_counter` kept per decision §8.3.

## Files added (P2 cont. — serving function port, applied on STAGING 2026-09-08)

| File | What |
|---|---|
| `08_p2_serving_functions_port.sql` | Ports the other 29 contract `h_piot_*` SETOF functions to `serving.<intent>` + real composite `serving.<intent>_row` TYPEs. Generated from **live** `pg_get_functiondef` (drift-proof; picks up the runtime_→oee_ / uns_→live_ renames the stale snapshot misses) with a two-token swap (fn name + return type). Every body references its return type exactly once → copied byte-for-byte → equivalent by construction. |
| `08b_p2_serving_functions_drop.sql` | Reverse of 08 (drops the 29 serving fns + row types via `DROP TYPE … CASCADE`; leaves `serving.oee_score`/`serving.machine_speed`). |
| `09_p0c_fix_restore_v_events_2.sql` | **P0c remediation.** `03_p0c` dropped `public.v_events_2` as "orphan", but it backs the LIVE contract fn `h_piot_get_events_timeline_full_with_filter_3` — the endpoint was 500ing on staging. Restored (recovered from `db/cutover/f3-stop-threshold.sql`, with `equipment_runtime_shift`→`equipment_oee_shift`). Additive; reverse with `DROP VIEW`. |

## P2 equivalence gate (function layer) — 2026-09-08

- **Method.** Each `serving.<intent>` is a byte-identical body twin of its `h_piot_*` source, so
  equivalence is guaranteed by construction; the gate CONFIRMS it on live data + smoke-tests the
  transform. Executed as `postgres` (the real prod caller — read-api connects as postgres; all 35
  h_piot fns are SECURITY INVOKER, secdef=0; only 6 tables have RLS). The bi_owner+RLS caller-binding
  dimension is covered by the P2 **view** gate (`bi_next.*` / serving views, 06/07). Symmetric multiset
  diff via `EXCEPT ALL` both directions over the full projected column set (NULL-aware = `IS DISTINCT
  FROM`); `json`-returning fns compared via `to_jsonb(row)` (json has no equality operator).
- **Contexts.** busy tenant 3 (two frozen windows 2026-08-01..08-15 and 2026-09-01..09-08) + quiet
  tenant 120; `app.tenant_id` set per context.
- **Result: 29/29 ported functions PASS (symdiff 0, both directions, every context). 0 DIFF, 0 regressions.**
  Non-trivial row coverage e.g. downtime_events 3318, events_timeline_full 10030, oee_score_by_team 40,
  production_orders_with_runtimes 143, total_production_by_team 15.
- **Aggregate tier (HP-1 + perf).** silver `equipment_metrics_1min` vs direct RAW over ent3/W1:
  **row-complete (678604=678604) and bucket-complete (150585=150585)**; residual sum delta is pure
  float4 accumulation (silver partials inherit `real`; max rel err 4.8e-6). EXPLAIN of the silver
  1hour path hits `_materialized_hypertable_51` chunks — **no `Seq Scan on equipment_values`**. NOTE:
  the ported aggregate fns still read the legacy `agg_*` tables (faithful twins); repointing them to
  `silver.*` is P3 and should first make silver partials float8/numeric (see finding below).

## Findings for P3–P5
- **P0c over-drop (FIXED):** `v_events_2` was a live dependency, not an orphan → restored (09_*). Audit
  the rest of the `03_p0c` drop list the same way before P5.

## P3 pre-fix — APPLIED + PROVEN on staging 2026-09-08 (10_p3pre_silver_float8_partials.sql)
- silver partials `real`→`float8` (cast RAW ::float8 in tier-1). Drop/recreate the 4-tier family +
  serving.machine_speed (tier-1 dependent) + re-add policies (4/4) + rematerialize oldest-first
  (1min 65s / 10min 11s / 1hour 1.4s / 1day 0.3s).
- **HP-1 re-proof (frozen window 07-08..09-07, FULL dim grouping):** silver 1min ≡ direct-RAW float8 —
  1,388,365 rows, **0 presence / 0 count / 0 sum mismatch, max abs diff = 0.0**. Telescoping 1min→1hour
  0 count mismatch, max abs 7.3e-12 (float8 assoc noise). silver is now exactly RAW-equivalent.

## P3/P5 BLOCKERS found during live audit — resolve before executing the destructive phases

1. **bi.* → security_invoker swap is UNSAFE — Superset would break.** `superset_ro` deliberately has
   **NO base-table grants** (dark-schema posture; `configs/superset/.../packiot_analytics.yaml`,
   `superset_config.py`). bi.* work as **security-DEFINER (bi_owner, non-bypassrls, RLS-subject)** and
   Superset stamps `-c app.tenant_id=<id>` per request. HARDPROOF as `superset_ro`: `bi.oee_shift`
   (definer) tenant 3 → 2093 rows; `bi_next.oee_shift` (security_invoker) → **permission denied for
   table equipment_oee_shift**; direct base table → permission denied; isolation holds (tenant 120 → 0).
   → **DECISION: keep bi.* as security-definer. No Superset change in P3.** `bi_next` (0 external
   dependents) is equivalence-gate scaffolding → drop in P5. bi.* still need the §4 **column** renames
   in P4 (e.g. `oee_quality`→`oee_q` on production_orders) via expand/contract.

2. **read-api repoint: 29/31 datasets have clean serving twins; 2 do NOT.** `h_piot_oee_score_full_3`
   (10-arg fn) and `h_piot_machine_speed` (10-arg fn) map in the plan to `serving.oee_score` (3-arg
   canonical A·P·Q redesign) and `serving.machine_speed` (a silver-backed VIEW) — **intentional
   redesigns, not byte-identical twins** (different signature + semantics). Repointing them is a
   frontend-visible behaviour change, not a transparent P3 swap. → Either add byte-identical
   `serving.*` twins of those two fns (drift-proof method, like 08), or migrate the oee/speed read
   paths deliberately with frontend coordination. The other 29 datasets repoint 1:1
   (`h_piot_X`→`serving.<intent>`), then regen `contract.golden.json` + build + deploy + verify.

3. **agg_*/ca_agg_* are NOT droppable as planned — silver lacks the categorical grain.** 9 public
   `h_piot_*` fns + their 6 `serving.*` twins read `agg_*`. Several group by **shift/team/state/mode/
   id_production_order** (`oee_score_by_team`, `single_period_by_team[_v4]`, `targets`,
   `overview_production_chart`, `mission_control_timeline`) — dimensions silver **deliberately omits**
   ("categorical context is not a grouping key", plan §2.1). So those fns cannot repoint to `silver.*`;
   agg_* (or a new categorical tier / RAW read) must remain. Only the non-categorical
   equipment×time aggregations can move to silver. Reconcile before any agg_* drop.

- **P4/P5 remaining:** GOLD/dimension renames + column prune (expand/contract); fold 5 SAP views into
  `customer_reports`; then drop `bi_next`, `analytics_v2` PoC caggs (6 views, no external deps),
  the 13 non-contract h_piot variants (verify each absent from contract.golden.json), old h_piot_*
  originals (after read-api repoints), `drop_backup_20260908` (8 tables, post sign-off). #186
  writer-audit + 42P01 log-watch before EACH drop.
