# ADR-0012 — sandbox naming audit & map (h_* / v_* families)

- **Status**: Applied to `packiot_refactor` (sandbox) — 2026-07-06
- **Implements**: `0012-sandbox-naming-sweep-a.sql` (h_*), `-b.sql` (v_*)
- **Method**: column-signature grouping (information_schema dump of all
  108 sandbox tables) — identical signatures = duplicates, strict
  supersets = version chains, everything else = distinct concepts

## Naming rules

| Rule | Meaning |
|---|---|
| R1 | Drop noise tokens: `piot_`, `get_`, `_table`, `_data`, `_i_` — they carry no information inside a Packiot DB, and a relation doesn't need to say it's a table |
| R2 | Version suffixes (`2..5`, `_new`, `_v2`, `_test1`, `_tz_fix`, `_temp_fix`): promote the latest (superset) shape to the unsuffixed name, retire siblings, keep **every** old name as a compat view |
| R3 | pt-BR → English (`resumo` → `summary`), consistent with Phase 1's `monitoramento_execucao_functions` → `function_execution_log` |
| R4 | Column-identical duplicates collapse to one relation |
| R5 | Customer/tenant IDs never in relation names → pool pattern (owned by the Phase-4 waves, not this sweep) |

**Compat guarantee**: every legacy name still resolves, with its original
column list in its original order (subset projections off the canonical).

**Prod caveat**: `h_*` relations are Hasura **function return types** on
prod — the real wave must alter the paired functions and re-track in
Hasura (gated on task #86). This sweep proves the target naming + shape
compatibility on the sandbox only.

## The map

### h_* — downtimes

| Old | New | Rule / evidence |
|---|---|---|
| `h_downtimes_table_2` | `h_downtimes` (canonical) | R1+R2; `_2` ⊃ v1 |
| `h_downtimes_table` | compat view | v1, subset of `_2` |
| `h_piot_downtimes_table` | compat view | R4: subset of `_2` |
| `h_downtimes_table_with_sector_3` | `h_downtimes_with_sector` | R2; `_3` = `_2` + `manual_event` |
| `h_downtimes_table_with_sector_2` | compat view | |
| `h_piot_get_downtimes_per_category_table` | `h_downtimes_per_category` | R1 |
| `h_piot_get_downtimes_per_category_equipment_level_new` | `h_downtimes_per_category_equipment_level` | R1+R2 |
| `h_piot_get_downtimes_resumo_table` | `h_downtimes_summary` | R1+R3 |
| `h_piot_split_downtime` | `h_split_downtime` | R1 |

### h_* — events timelines

| Old | New | Rule / evidence |
|---|---|---|
| `h_events_timeline5` | `h_events_timeline` (canonical) | R2; strict chain v1⊂v2⊂v3⊂v4⊂v5 |
| `h_events_timeline{,2,3,4}` | compat views | subset projections |
| `h_events_timeline_full2` | `h_events_timeline_full` | R2; full2 = full + nm_equipment/nm_area/nm_site |
| `h_events_equipment_timeline_2` | compat view over base | R4: column-identical to base |

### h_* — overview / home / settings

| Old | New | Rule / evidence |
|---|---|---|
| `h_overview_i_events_3` | `h_overview_events` | R1+R2; v3 fixed start/end text→timestamp; v1/v2 compat views cast back |
| `h_overview_i_job_info` | `h_overview_job_info` | R1 |
| `h_overview_i_production_chart` | `h_overview_production_chart` | R1 |
| `h_overview_i_shift_production` | `h_overview_shift_production` | R1 |
| `h_piot_home_table` | `h_home` | R1 |
| `h_piot_edge_settings` | `h_edge_settings` | R1 |
| `h_piot_edited_po` | `h_edited_po` | R1 |

### h_* — mission control

| Old | New | Rule / evidence |
|---|---|---|
| `h_piot_mission_control` | `h_mission_control` | R1 |
| `h_piot_mission_control_timeline` | `h_mission_control_timeline` | R1 |
| `h_piot_mission_control_uns_3` | `h_mission_control_uns` | R2; ⊃ `_uns` (+4 target cols) |
| `h_piot_mission_control_uns` | compat view | |
| `h_piot_mission_control_area` | `h_mission_control_area_by_shift` | NOT a version chain: shift-grain (`ts_range`, `cd_shift`) |
| `h_piot_mission_control_area_new` | `h_mission_control_area` | day-grain canonical |
| `h_piot_mission_control_area_uns_2` | `h_mission_control_area_uns` | R2; ⊃ `_area_uns` |

### h_* — OEE

| Old | New | Rule / evidence |
|---|---|---|
| `h_piot_oee_progress_chart_data` | `h_oee_progress_chart` | R1 |
| `h_piot_oee_progress_data1` | `h_oee_progress_by_shift` | R1+R2; shape is per cd_equipment × cd_shift |
| `h_piot_oee_progress_with_teams` | `h_oee_progress_with_teams` | R1 |
| `h_piot_oee_score_data` | `h_oee_score` | R1 |
| `h_piot_oee_score_data_test1` | `h_oee_score_shift_detail` | R2; distinct shape (nav+shift), test1 token retired |
| `h_piot_oee_score_full_table` | `h_oee_score_full` | R1 |
| `h_piot_oee_score_teams_table` | `h_oee_score_teams` | R1 |

### h_* — production orders

| Old | New | Rule / evidence |
|---|---|---|
| `h_piot_production_orders_merged_new` | `h_production_orders_merged` | R2; `_new_table` was column-identical (R4, dropped) |
| `h_piot_production_orders_merged` | compat view | v1 `cd_equipment` mapped from `nm_equipment` — **verify against prod defs before the real wave** |
| `h_piot_production_orders_table` | `h_production_orders` | R1; distinct shape (has `id_production_order_runtime`) |
| `h_piot_production_orders_with_runtimes_table_4` | `h_production_orders_with_runtimes` | R2; chain `table` ⊂ `table2` ⊂ `table_4` |
| `h_piot_production_flow_table` | `h_production_flow` | R1 |
| `h_piot_production_targets` | `h_production_targets` | R1 |

### h_* — charts

| Old | New | Rule / evidence |
|---|---|---|
| `h_equipment_chart_data` | `h_equipment_chart` | R1 |
| `h_equipment_chart_data_1day` | `h_equipment_chart_1day` | R1; legit grain variant |
| `h_single_period_equipment_chart_table_4` | `h_single_period_equipment_chart` | R1+R2; `_4` = `_3` + scrap_percentage/scrap_targets |
| `h_total_production_chart_data_tz_fix` | `h_total_production_chart` | R1+R2; tz_fix is the fix (ts→varchar); legacy name casts back |
| `h_total_production_chart_from_runtime` | unchanged | source variant, name already meaningful |

### v_* — operator / mission control

| Old | New | Rule / evidence |
|---|---|---|
| `v_operator_po_list_setup_3` | `v_operator_po_list` | R2; strict chain base ⊂ setup ⊂ setup_2 ⊂ setup_3; 4 names preserved |
| `v_mission_control_areas_shift_temp_fix` | `v_mission_control_areas_shift` | R2; fix promoted — **type change under stable name (timestamptz→date, float4→float8): consumer check before prod wave** |
| `v_mission_control_areas_sum_from_equipment` | compat view over `h_mission_control_area` | R4: column-identical cross-prefix duplicate |
| `v_13_site_deb_labels_piot4v_13` | `v_13_site_deb_labels_piot4` | typo (paste artifact); column-identical to `v_13_labels_piot4` — full v_13 pooling stays Wave 3 |

### CAgg family (implemented in `0012-sandbox-live-feed.sql`)

| Old | New | Rule / evidence |
|---|---|---|
| `agg_equipment_values_1min` (stub) | façade over `ca_equipment_values_1min` | ADR naming table; now a REAL CAgg over the live-fed hypertable |
| `agg_equipment_values_1min_t` | façade | `_t` storage-engine token retired |
| `equipment_values_1min` (Phase-1 demo) | façade | fixes Phase-1 drift vs ADR (canonical is `ca_*`) |

### Reviewed, no action (names already meaningful)

`equipment_events_low_speed`, `equipment_runtime_shift_1week`,
`insights_logs`, `h_pending_events`, `h_machine_speed`¹,
`dt5min_po_function_returns`, `function_execution_log`,
`report_shift_enterprise_06`, `report_speed_enterprise_33`,
`v_entities_per_user_role`, `v_menu_per_user_role`,
`v_operator_entities`, `v_pages`, `v_insights_main`,
`v_mission_control`, `v_mission_control_areas`,
`v_total_production_{month_grain_1day,month_grain_1week,today,yesterday}`,
`lab_equipment_values` (+ Phase-2 lab CAgg shims),
`customer_dashboards.*` (POC canonical).

¹ `h_machine_speed`: "machine" vs domain-standard "equipment" noted, but
`cd_machine` columns are pervasive — renaming the table alone would be
half-consistent. Deferred to a vocabulary pass, if ever.

### Deferred to existing waves (do not touch here)

| Family | Owner |
|---|---|
| `v_13_*` pooling (11 relations) | Phase-4 Wave 3 (views on prod; flip after Wave 2 bakes) |
| `c35_v_*` (3) | Phase-4 Wave 3 |
| `report_*` pooling | Waves 1 (done) / 2 (Go ports decided) |
| `shift_agg_from_events_v2` | Wave 4 contract (1 prod dependent) |
| `v_agg_equipment_values_1day_full` | staging CAgg consolidation (needs the real 1day CAgg base) |

## Outcome (sandbox, 2026-07-06)

- 108 base tables reviewed; 34 canonical renames, 18 duplicate/superseded
  tables retired, ~45 compat views — **zero legacy names lost**.
- Live shadow feed proves the canonical CAgg naming under real inserts
  (`refactor_sync` job, 1-min cadence).
