# Naming ledger — legacy dialect → refactored stack (2026-07-04)

USER DIRECTIVE: the legacy names are awful (typos shipped to prod,
'_test' meaning production, generation suffixes). Rules:

1. Prod names are FROZEN (SELECT-only; façades keep legacy names
   because consumers depend on them — typos included).
2. SQL strings in Go may reference legacy names ONLY when addressing
   real DB objects; a comment marks each as `-- legacy name (frozen)`.
3. Every NEW object (pool tables, Go identifiers, jobs, metrics, env
   vars) uses the CLEAN column. No typo, no tenant number, no
   generation suffix ever enters the refactored namespace.

## The ledger

| legacy (frozen) | sin | refactored name |
|---|---|---|
| report_shift_enterprsie_06 | typo + tenant | customer_reports.shift (pool) |
| report_speed_enterprsie_33 | typo + tenant | customer_reports.speed |
| sap_report_data_sync_customer_13 | tenant | customer_reports.sap_data_sync |
| production_data_sync_enterprise_06 | tenant | customer_reports.production_sync (config-ready swap) |
| equipment_boxes_cust_13 | tenant | customer_reports.boxes |
| upsert_equipment_boxes_cust_13 | tenant fn | boxes label-adapter (delivery archetype) |
| fn_update_packer_net_production_13_obd | tenant + cryptic 'obd' | boxes bridge (box_production_bridges descriptors) |
| get_report_shift_enterprsie_06c | typo + generation c | (deep-rewrite target) shift report compute |
| update_report_shift_enterprsie_06b → 06c | generation maze | reports job "shift06" → rename at pool swap: "shift-report" |
| get_data_sync_enterprsie_06b | typo + generation | sync06 embed (renders tenant) → "production-sync" |
| piot_create_or_adjust_po_runtmites | TYPO (runtmites) | **po-runtime-adjust** (P3b port) |
| piot_get_equipment_production_order_runtime_test | '_test' IS PROD | **po-runtime-compute** (live generation) |
| piot_get_equipment_production_order_runtime_final | 3rd generation | **po-runtime-finisher** |
| piot_proc_refresh_production_orders | — | **po-runtime-refresh** (job name) |
| piot_proc_refresh_runtime | — | **runtime-rollup** (job) |
| piot_create_{ent,area,site}_runtime_{grain} | matrix as 15 fns | **runtime-provision** (static matrix, UNS pattern) |
| piot_get_equipment_runtime_*_production(+_tp_eq3) | selector-as-fn-suffix | **runtime-rollup-{grain}** (tp collapsed to param) |
| piot_uns_* refresh family | matrix as 14 fns | uns package (provision + refresh matrix) |
| proc_create_jobs_enterprsie_10 | typo + tenant | (at port) jobs provisioning descriptor |
| ca_agg_equipment_values_1hour vs agg_* | two CAgg dialects | flows carry agg_* only |
| v_operator_entities_2 | version suffix (never promoted) | **v_operator_entities** (R2 promote; `_2` kept as compat view — see migrations/0012-r2-promote-v-operator-entities.sql, applied prod 2026-08-12) |

## Enforcement

- Guard tests already ban tenant literals in new SQL (boxes adapter,
  bridge, uns). Extend the habit: every new port's test asserts its
  clean job name and bans legacy tokens outside marked SQL strings.
- The P3b ports MUST ship under the bold names above — the ledger is
  assigned BEFORE the code exists, so the dialect dies at the border.
