# ADR-0014 Phase 1 — piot_* OEE-math inventory

- **Status**: Delivered 2026-07-02 (the missing Phase 1 deliverable)
- **Source**: staging `packiot` pg_proc (151 functions match `piot%`),
  write targets parsed from prosrc (`INSERT INTO` / `UPDATE … SET`),
  call graph from `piot_proc_refresh_runtime`'s body
- **Cron reality (staging)**: 4 jobs total. Job 3 = `CALL
  piot_proc_refresh_runtime()` **every minute** — it invokes 44
  functions per tick (full list below). Everything OEE happens inside
  that one serially-executed procedure. Prod cron is unreadable with
  awslambda (assume same shape until the elevated-access check).

## The one-minute mega-proc

`piot_proc_refresh_runtime` (10.3KB) calls, per minute:
17 runtime writers (`piot_create_{equipment,area,site}_runtime_*`),
their `piot_get_*_production` compute helpers, the
`piot_feed_agg_equipmentvalues_1min_t{,_new}` aggregate feeders,
`piot_proc_refresh_production_orders{,_client6}`,
`piot_proc_uns_equipment_refresh_current_metrics`,
`piot_cust_speed_product_client_33`, `piot_review_equipment_events`,
`piot_proc_updates_different_clients`, `piot_refresh_uns`,
`piot_monitor_function`.

Consequence for ADR-0014: porting is separable — each callee can move
to Go/CAgg independently, with the proc's call to it removed in the
same PR (the "retire old writers in the SAME PR" rule, bug 241).

## Families + disposition

| Family | Count | Write targets | Disposition | ADR phase |
|---|---|---|---|---|
| Runtime rollup writers `piot_create_{eq,area,site}_runtime_{1hour,1day,1week,1month,shift}` (+shift_1week/1month) | 17 | `*_runtime_*` tables | **TimescaleDB CAggs** (overlaps ADR-0012 ca_* consolidation) | 0014-P3 |
| Rollup compute helpers `piot_get_*_production*` | ~20 | same tables (via caller) | Retired with their writers (logic folds into CAgg defs or Go) | 0014-P3 |
| 1-min aggregate feeders `piot_feed_agg_equipmentvalues_1min*` (4 variants!) + invalidation + recalc ×2 + search_recalc + update_agg | 9 | `agg_equipment_values_1min_t` | Consolidate first (version sprawl), then CAgg | 0014-P3 |
| equipment_events derivation: `piot_review_equipment_events{,_temp}`, `piot_state_lines_downtime_process_mirror_reason{,2,3}`, `piot_split_downtime`, `piot_insert_equipment_line_downtime_events`, `piot_delete_equipment_line_downtime_events` | 8 | `equipment_events` | **Go in oeecloud-worker** (the events-parity blocker for flows 2/3) | 0014-P3 |
| PO runtime: `piot_create_or_adjust_po_runtmites` (12KB), `piot_{proc_,}get_equipment_production_order_runtime{,_final,_test}` | 6 | `production_orders{,_runtime}`, `cq_logs` | Go; `_test` variant = retire | 0014-P3 |
| UNS refreshers `piot_uns_*` + `piot_proc_uns_*` (×2 versions) + `piot_refresh_uns*` | ~19 | `uns_*` | Go emissions or on-query views; version dedupe first | 0014-P3 |
| Customer-specific: `piot4_13_*` ×4 (one is 46KB!), client6 family ×5, client13 labels ×3, `piot_cust_speed_product_client_33` | ~13 | `production_orders*`, `report_*` | **Per-customer Go handlers — THIS is ADR-0012 Phase 4 Wave 2's writer set** (single-port rule) | 0014-P4 |
| Shift/time helpers `piot_get_shift_hour*` ×9, `piot_get_day_begin*` ×5, `piot_get_shift_hours_by_packml*` ×4 | ~18 | read-only | Core one ported (shiftresolver, 0014-P2 ✅); rest retire as their callers port | 0014-P2/P3 |
| Triggers `piot_trig_*` | 7 | various | Case-by-case with their tables; `piot_set_shift_on_equipment_values` ✅ in bake | 0014-P2+ |
| packml topic mgmt: `piot_packml_new_topic`, `piot_upsert_packml_topics` | 2 | `packml_register`, `equipments`… | KEEP in DB for now (CS Admin coupling) or move to edge-api | later |
| Utility/maintenance: monitor, delete_devices_health_checks, insights_log_feeder, update_super_users, insert_default_pages, mv/overview refreshers | ~15 | misc | Mostly retire (`piot_monitor_function` writes the dead 67MB pt-BR table) | contract |
| Chart/query helpers `piot_get_equipment_chart_data*`, `piot_get_edge_setting`, oee getter | ~5 | read-only | Consumers are APIs — move to API layer when touched | later |

Version-sprawl retirement candidates surfaced by the inventory (verify
zero-callers first): `piot_feed_agg_equipmentvalues_1min` (superseded by
`_t` + `_t_new` — THREE generations coexist),
`piot_state_lines_downtime_process_mirror_reason{,2}` (3rd generation
live?), `piot_get_equipment_production_order_runtime_test`,
`piot_review_equipment_events_temp`,
`piot_get_shift_hour_by_equipment_fixed` vs unfixed,
`piot_uns_equipment_refresh_current_metrics` vs `piot_proc_…` vs
`piot_proc_…_2`.

## Measurement gaps (honest limits of this pass)

- `track_functions` is not enabled → no per-function timing/call counts;
  the ADR's "rows read/written per invocation, avg execution time" needs
  either enabling it (staging, cheap) or pg_stat_statements
- Prod cron schedule unreadable (awslambda) — staging job list assumed
  representative for the core proc; customer report writers (Wave 2 set)
  demonstrably run on prod somehow (11.1M inserts) — scheduler unknown
- Prod-vs-staging function body diff not verified (only names/sizes)

## Immediate next uses

1. ADR-0014 Phase 3 sequencing: start with the 17 runtime writers →
   CAggs (mechanical, biggest cron relief), then events derivation → Go
   (unblocks flows 2/3 equipment_events parity)
2. ADR-0012 Phase 4 Wave 2 = the customer-specific family, ported once
   to Go against the `customer_reports` pool tables
3. Contract wave gets the version-sprawl + `piot_monitor_function`
