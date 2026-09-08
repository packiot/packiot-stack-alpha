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
