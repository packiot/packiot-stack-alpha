# PowerBI compatibility gate report

- Generated: 2026-07-06 20:31Z by scripts/test-powerbi-compatibility.sh
- Source (truth): `packiot` · Target (façades): `packiot_refactor`
- Objects: 30 (see docs/guides/powerbi-gate-objects.txt)
- **Gate status: PROMOTABLE (pending row-parity seed + human sign-off)**

| object | kind (tgt/src) | T1 presence | T2 shape | T3 rows | T4 planner |
|---|---|---|---|---|---|
| `c33_downtime_events` | table/view | PASS | PASS | PASS | n/a |
| `c33_setup_time_adjusted` | table/view | PASS | PASS | PASS | n/a |
| `c35_dashboard_paradas_24h` | view/table | PASS | PASS | PASS | INLINED |
| `c35_dashboard_producao_24h` | view/table | PASS | PASS | PASS | INLINED |
| `c35_dashboard_timeline_24h` | view/table | PASS | PASS | PASS | INLINED |
| `c35_v_dashboard_timeline` | table/view | PASS | PASS | PASS | n/a |
| `c35_v_shifts_data` | table/view | PASS | PASS | PASS | n/a |
| `c35_v_stopped_time` | table/view | PASS | PASS | PASS | n/a |
| `production_data_sync_enterprise_06` | table/table | PASS | PASS | PASS | n/a |
| `report_shift_enterprsie_06` | view/view | PASS | PASS | PASS | INLINED |
| `report_speed_enterprsie_33` | view/view | PASS | PASS | PASS | INLINED |
| `sap_report_data_sync_customer_13` | table/table | PASS | PASS | PASS | n/a |
| `v_13_dt5min_piot4` | table/view | PASS | PASS | PASS | n/a |
| `v_13_labels_piot4` | table/view | PASS | PASS | PASS | n/a |
| `v_13_microstops_piot` | table/view | PASS | PASS | PASS | n/a |
| `v13_mobile_power_bi_direct_query` | table/view | PASS | PASS | PASS | n/a |
| `v_13_overview_partial_scrap_rate` | table/view | PASS | PASS | PASS | n/a |
| `v_13_overview_takt` | table/view | PASS | PASS | PASS | n/a |
| `v_13_pos_piot4` | table/view | PASS | PASS | PASS | n/a |
| `v_13_production2_piot4` | table/view | PASS | PASS | PASS | n/a |
| `v_13_site_deb_dt5min_piot4` | table/view | PASS | PASS | PASS | n/a |
| `v_13_site_deb_equipment_list` | table/view | PASS | PASS | PASS | n/a |
| `v_13_site_deb_labels_piot4v_13` | view/view | PASS | PASS | PASS | n/a |
| `v_13_site_deb_microstops_piot` | table/view | PASS | PASS | PASS | n/a |
| `v_13_site_deb_pos_labels` | table/view | PASS | PASS | PASS | n/a |
| `v_13_site_deb_pos_piot4` | table/view | PASS | PASS | PASS | n/a |
| `v_13_site_deb_prod_per_equipment` | table/view | PASS | PASS | PASS | n/a |
| `v_13_site_deb_sap_report` | table/view | PASS | PASS | PASS | n/a |
| `v_13_site_wil_dt5min_piot4` | table/view | PASS | PASS | PASS | n/a |
| `v_13_site_wil_microstops_piot4` | table/view | PASS | PASS | advisory | n/a |

## Notes

- T3 row parity is advisory until the prod-read report harness seeds the pools (test-plan §Preconditions).
- T5 byte-sample runs at sign-off time on the seeded objects.
- '37+1' headline vs 30 enumerated: reconciled in the harness header.
