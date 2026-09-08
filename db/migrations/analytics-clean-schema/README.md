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

## P3 categorical companion — BUILT + REPOINTED + GATED on staging 2026-09-08 (files 11a/11b/11c/12)

Resolves blocker #3 (agg_*/ca_agg_* not droppable — silver lacks the categorical grain).

- **`silver.equipment_categorical_{1min,10min,1hour}`** (11a): a CLEAN telescoping cagg family that
  mirrors `ca_agg_equipment_values_*`'s EXACT grain (18 keys: equipment×time × state/mode/id_order/
  conversion_factor/number_cavities/signal_quality/id_shift/id_team/id_shift_hour/id_production_order/
  ts_value_production/ideal_production_speed), with **float8 partials** (== the silver numeric family,
  P3 pre-fix) so it is exactly RAW-equivalent, and the non-telescoping `avg(speed)` replaced by
  decomposable `sum_speed`/`cnt_speed`/`cnt_rows`. Key + `*_incr`/`*_val` column NAMES match ca_agg,
  so the repoint is a pure FROM-target swap. 1hour built on 1min (bit-exact to ca_agg's 1min→1hour).
- **The 5 categorical consumers** (`oee_score_by_team`, `single_period_by_team`,
  `single_period_by_team_v4`, `targets`, `overview_production_chart`) repointed
  `ca_agg_equipment_values_1hour` → `silver.equipment_categorical_1hour` (12, drift-proof
  CREATE OR REPLACE + post-condition assertion: 0 serving fns still read ca_agg). `mission_control_timeline`
  reads the NUMERIC `agg_equipment_values_1min` (not categorical) → repoints to `silver.equipment_metrics_1min`
  (P5 prep, NOT yet done).
- **WATERMARK LESSON (11b):** first backfill refreshed the higher tiers to a FUTURE date (2026-09-10),
  which materialized the current *incomplete* hour as a stale snapshot (fn-gate caught it: current-hour
  production 56 frozen vs 81 live). Fix: refresh 10min/1hour only to a COMPLETED boundary (12:00 == ca_agg
  watermark), leaving the current bucket to the real-time union. Policies (`end_offset` 1 tier-width)
  maintain the invariant. 1min tier tracks the last datapoint (fine).
- **GATE (all PASS):**
  - *Correctness* — companion 1min ≡ direct-from-RAW float8 categorical aggregation (busy day 08-05, T3):
    19193=19193 rows, **0 value mismatches, max abs = 0**. Companion is the exact RAW value.
  - *Presence* — vs `ca_agg_1hour` (T3 windows 08-01..15 & 09-01..08, T120): key sets IDENTICAL
    (8732=8732, 5759=5759; T120 0=0 isolation). Residual = value-only on ~2.6% of *historical large-totalizer*
    buckets = **legacy float4 sum-order rounding** (max rel 3.6e-7 ≈ 3 float4 ULP); companion (float8) is
    the correct side. Recent/small-value buckets are integer-exact in both → zero residual.
  - *fn-level symdiff-0* (old ca_agg-backed vs companion-backed, live window):
    `overview_production_chart` 5 lines × 12 buckets = 0/0 (max_rel_prod 0, max_abs_scrap 0);
    `oee_score_by_team` 20 rows 0/0; `single_period_by_team` 0/0; `single_period_by_team_v4` 0/0; `targets` 0/0.
  - Refresh policies 3/3 (jobs on all tiers), assertion PASS.
- **Unblocks:** `ca_agg_equipment_values_{1min,1hour}` become droppable in P5 once the 7 `h_piot_*`
  originals that still read them are dropped (they are non-contract legacy → dropped with the h_piot cull).

## P3 read-api repoint — MERGED + DEPLOYED + LIVE-VERIFIED on staging 2026-09-08 (PR #1132)

- Branch `feat/p3-readapi-serving-repoint` off origin/staging; 31 read-api datasets/routes repointed
  `h_piot_*` → `serving.*` (29 byte-identical twins + 2 Decision #2 redesigns: `oee-score-full` →
  `serving.oee_score` canonical A·P·Q, `machine-speed` → `serving.machine_speed` silver view).
  `contract.go` taught to parse schema-qualified names; golden regenerated + idempotent; all 13 PR
  checks green (live-prod-drift job is workflow_dispatch-only → skipped, non-blocking). Merged → staging
  (e63d7721) → deploy-staging rebuilt the read-api container.
- **LIVE PROOF (on-box, curl→read-api:9104 over stack_packiot-net):** `/healthz` healthy; `oee-score-full`
  returns CANONICAL A·P·Q — `{oee:0.311, oee_a:0.954, oee_p:0.690, oee_q:0.472}` (0.954·0.690·0.472≈0.311);
  `machine-speed` returns silver-backed rows. read-api container healthy on the new image.
- deploy-staging job went RED only on a **pre-existing** `adminer` port-8082 conflict (`up -d` exited 1
  AFTER read-api recreated+started healthy) — unrelated to this change; all critical services healthy.
- **Prod-flip follow-up (NOT staging):** `services/read-api/scripts/refdata-contract-drift-check.sh`
  matches `pg_proc WHERE nspname='public'` → must be made schema-aware, and prod must have `serving.*`/
  `silver.*`, before the manual live-prod-drift gate passes. edge-api production-targets DAO is P4-coupled
  (no `serving.set_*` twins exist; it's tied to the 3-target-table merge).

## P4 step2 (subordinate-object + proc renames) — APPLIED + PROVEN on staging 2026-09-08 (files 13, 14)

Renames the leftover runtime_/uns_ **names** on the already-renamed grain tables (the TABLES were
renamed in the earlier cutover; only their subordinate objects still carried old names).

- **13_p4_rename_runtime_uns_subordinate_objects.sql** — 29 constraints + 6 standalone indexes + 1
  sequence renamed (`runtime_`→`oee_`, `uns_`→`live_`), one transaction. Behavior-neutral: all
  OID-tracked (edge-api upserts via column-inference `ON CONFLICT (id_equipment, ts_value)`, not
  constraint name; FKs/indexes by OID). **Hardproof pre-check:** 0 fn bodies reference any of these
  names (0 `ON CONSTRAINT`, 0 name-string refs — checked every prokind f/p in public/serving/bi).
  `production_orders_runtime` deliberately NOT renamed (correctly named). **Post-proof:** only the 3
  `production_orders_runtime` old names remain; the renamed sequence's column DEFAULT auto-repointed to
  `nextval('equipment_oee_shift_id_seq')`; `equipment_oee_shift` constraints all `convalidated`.
- **14_p4_rename_provision_procs_oee.sql** — the 11 `piot_create_*_runtime` provisioning procs renamed
  to `piot_create_*_oee_*`. **EXPAND phase:** each old name kept as a thin `PERFORM new()` shim so the
  live external caller (stream-engine `internal/rollup/provision.go` `provisionFns`, hourly, fail-soft)
  is unaffected (procs are public-only, 11; no `ev_*` flow schemas; no trigger/fn/pg_cron caller — the
  Go list is the sole caller). Proven: 11 REAL procs (large bodies) + 11 SHIMs.
  **CONTRACT tail (NOT done — needs a stream-engine deploy):** update `provisionFns` to the new names +
  `edge-node-red/db/20-oee-engine-parity.sql` bootstrap defs, deploy stream-engine, verify
  runtime-provision runs on new names, then drop the 11 shims (a 15b migration).

## P5 h_piot cull — APPLIED + PROVEN on staging 2026-09-08 (files 15, 15.ROLLBACK)

**28** legacy `h_piot_*` originals dropped (read-api PR #1132 repointed to `serving.*` twins, deployed
+ live-proven). Exhaustive writer-audit (#186): none of the 28 is referenced as EXECUTED SQL by
read-api (golden = `serving.*` + `h_piot_machine_speed` + `h_piot_oee_score_full_3`), edge-api (only
`h_piot_set_production_target`/`h_piot_set_scrap_target`), stream-engine, any other stack service,
back4-api, primary-api, any view, any serving fn (only the 2 kept downtime helpers), any surviving
h_piot, Hasura (`hdb_catalog` absent on staging) or pg_cron (not installed).
- **KEEP 7** (excluded from the drop): `h_piot_machine_speed`, `h_piot_oee_score_full_3` (read-api,
  #218-owned), `h_piot_oee_score_with_teams` (called by oee_score_full_3), `h_piot_set_production_target`,
  `h_piot_set_scrap_target` (edge-api DAO — **writer-audit catch: NOT in the original task keep-list**),
  `h_piot_get_downtimes_per_category_equipment_level_new_4`, `h_piot_get_downtimes_sector_microstops`
  (bodies of `serving.downtime_by_category`). Note the task's `h_piot_production_orders_with_runtimes_table2`
  is a composite TYPE, not a function — never in the drop set.
- **Proof:** self-guarding (no CASCADE → transaction COMMITted ⇒ 0 dependents existed); 7 keepers present;
  all 411 serving+public fn defs still resolve (no broken deps); serving twins execute live post-drop
  (`downtime_events` 1842, `production_orders_with_runtimes` 143, `oee_progress` 20, `mission_control_area`
  5) + kept `oee_score_full_3`→`oee_score_with_teams` returns 20; read-api logs clean (0 errors). pg_stat
  delta was flat (staging idle) — not used as the gate; the no-CASCADE self-guard + live twin execution is
  the definitive proof. Reverse: `15_p5_drop_h_piot_originals.ROLLBACK.sql` (full live defs, 28).

## STILL Remaining (mapped, NOT executed — need live-writer coordination and/or a service deploy)
- **P4 §4 table/col renames (step 3):** `packml_register`→`topic_routing` (live SparkPlug-routing writer;
  no Hasura on staging, so a rename + auto-updatable view shim is viable but must verify oeecloud/CS-Admin
  write path); `production_orders.oee_quality/availability/performance`→`oee_q/a/p` (oeecloud WRITES these →
  needs add-col + dual-write trigger, NOT a plain rename; **intersects the sibling's Superset domain** —
  Superset YAMLs already expect `oee_a/p/q`); merge `equipment_events`+`_man`→`is_manual` (replicator
  writer); merge `production_targets`/`oee_targets`/`scrap_targets`→`targets(kind)` (coupled to the KEPT
  `h_piot_set_production_target`/`set_scrap_target` + edge-api DAO — a coordinated edge-api change).
- **P4 SAP fold (step 4):** create `customer_reports`, move the 3 SAP views, **repoint read-api
  external*.go + deploy**, verify neopac/incoplast/montebello golden endpoints.
- **P4 bi.\* COLUMN renames** (bi.* stays security-DEFINER, Decision #3) + §5 column prune (keep box tables
  + id_user_firebase).
- **P5 tail:** `ca_agg_equipment_values_*` now has no h_piot reader (the readers were in the 28 dropped) —
  but **HELD** per step-6 gate (#218); re-verify 0 readers then drop with agg_*. `agg_*` needs the 3 SAP
  views folded (step 4) + `get_report_shift_enterprsie_06c` (dead) first. `drop_backup_20260908` KEPT until
  sign-off. #186 writer-audit + 42883/42P01 watch + re-verify EACH before dropping.
- **P6 HOLD (step 6):** `agg_*`/`ca_agg_*` families + the 2+1 kept front4/#218 h_piot — do NOT drop.
