# CPACK Superset dashboard buildout (W3 full set) — enumeration + runbook

Status: BUILT (codified + isolation-gate-verified), LIVE APPLY GATED. 2026-08-11.
Owner: platform. Scope: build the **full set** of CPACK (ent 3) dashboards in the live
Superset (`bi.prod.packiot.app`) that matches what front4 shows (native Overview /
Operations views) + the CPACK-relevant PowerBI reports — **alongside** the existing
"OEE Overview" (which another agent owns + is error-fixing; untouched here).

Builds on: `docs/plans/superset-oee-dashboard-spec.md` (front4 tile → bi.* mapping),
`docs/plans/powerbi-to-superset-migration.md` + `docs/adr/reference/captures/0046-powerbi-workspace-inventory.md`
(75 PowerBI reports), and the existing `bi.*` views in `db/superset/01-superset-ro-role.sql`.

---

## 0. The data-readiness reality (LIVE-VERIFIED 2026-08-12)

new-prod is **single-tenant CPACK (ent 3)**. Row counts measured live as `superset_ro`
under the all-tenant sentinel (`SET app.tenant_id='-1'`) against the `packiot` analytics
DB — this SUPERSEDES the earlier stale note that claimed downtime/PO were empty:

| F3 source → bi.* view | Live rows (CPACK) | Dashboards it feeds | Data? |
|---|---|---|---|
| `equipment_runtime_shift` → `bi.oee_shift` | **122** | OEE, Total Production, Scrap, Shift Report | Y |
| `equipment_runtime_1hour` → `bi.oee_hourly` | **712** | Total Production, Scrap | Y |
| `equipment_values` → `bi.equipment_speed` | **280,329** | Machine Speed | Y |
| `equipment_values` → `bi.live_status` | **18** | Live Status | Y |
| `equipment_values` → `bi.production_by_team` | **280,340** | Total Production (team) | Y |
| `equipment_events` → `bi.downtimes` | **1,484,545** | Downtime Analysis | Y |
| `production_orders` → `bi.production_orders` | **19,788** | Production Orders | Y |
| `production_orders_runtime` → `bi.production_order_runtime` | **0** | Production Orders (runtime-OEE table only) | N |
| `production_targets` → `bi.production_targets` | **0** | target reference lines | N |
| `equipments` → `bi.equipments` | 62 | (join dimension) | Y |

So 7 of the 8 dashboards populate immediately. **Production Orders** is mostly populated
(PO table / count / OEE-by-order have 19.8k rows) EXCEPT its one runtime-OEE-table chart
(`production_orders_runtime`=0). Only `production_targets` (reference lines) is fully empty.
Isolation verified live: tenant 3 → its rows, tenant 1 → 0, GUC unset → 0 (fail-closed).

---

## 1. Target dashboards — front4 view / PowerBI report → Superset dashboard

### 1a. front4 native views → Superset

| front4 view (Overview/Operations) | Superset dashboard | bi.* dataset(s) | Data? |
|---|---|---|---|
| Overview (7 config variants — KPI wall) | **OEE Overview** (EXISTING — owned by error-fix agent, untouched) | oee_shift/oee_hourly/downtimes/po_runtime | **Y** |
| Operations · OEE | folded into OEE Overview + **Shift Report** | oee_shift | **Y** |
| Operations · Total Production | **Total Production** | oee_shift, oee_hourly, production_by_team | **Y** |
| Operations · Machine Speed | **Machine Speed** | equipment_speed | **Y** |
| Operations · Scrap Period | **Scrap Analysis** | oee_shift, oee_hourly | **Y** |
| machineStatusCard / plcStatusTile (live) | **Live Status** | live_status | **Y** |
| Operations · Downtimes | **Downtime Analysis** | downtimes | **N — empty until migration** |
| Operations · Production Orders | **Production Orders** | production_orders, production_order_runtime | **N — empty until migration** |

### 1b. CPACK-relevant PowerBI reports → Superset (from the 75-report inventory)

CPACK is enterprise-prefix `01_`. The `01_*` + the reusable shift/downtime/OEE report
*families* map onto the same Superset dashboards (one tenant-generic dashboard replaces
N per-tenant PowerBI reports):

| PowerBI report(s) | Pages | Superset dashboard | Data? |
|---|---|---|---|
| `01_INCOPLAST_PACKIOT`, `01_SC_StopsReports`, `37_DowntimeAnalysis`, `13_Neopac_DT_*`, `06_HWK` DT pages, `36-ALBEA` Stops | Downtime / Stops / Microstops / Categorias | **Downtime Analysis** | N (empty) |
| `13_OBD_MOBILE_direct_query` (RealTimeData) | live KPI cards | **Live Status** | Y |
| `37_Suzano_OEE_main_report2`, `10_GULF_CANS_OEE`, `36-ALBEA_OEE`, `06_Montebello/HWK Shift_Report` | OEE / Shift Report / Current Shift | **Shift Report** + OEE Overview | Y |
| `37_Suzano_SPEED_REWINDING`, `report_speed_enterprsie_33`, `10_GULF Speed` | Speed_L1/L2 / Speed | **Machine Speed** | Y |
| `04_Production_Control`, `v_13_pos_*`, GULF Work Orders | POs / Caixas / Work Orders | **Production Orders** | N (empty) |
| `13_Production_per_Team` (Prod_Teams) | Prod. per Team | **Total Production** (team bar) | Y (sparse until teams set) |
| `06_SETUP_ANALYSIS`, `01_Data_Setup_Incoplast` | Setup Analysis | **NOT BUILDABLE** — F3 has no `setups` table | — |
| `04_*` Caixas / Shift_Labels (scanned_boxes) | box scans | **NOT BUILDABLE** — F3 has no `scanned_boxes` table | — |
| `*Sensors_Report`, `07_SAP_*`, `*Usage Metrics*`, `*_CQ_*`, `teste_*` | sensor-debug / SAP export / admin | **OUT OF SCOPE** (§3.6 of migration plan) | — |

---

## 2. Dashboards built this pass (→ data? y/n)

All 8 are LIVE on bi.prod (imported 2026-08-12, ids 1-8) and every chart returns HTTP
200 on the chart-data endpoint (embed guard clean — no 403/500):

| # | Superset dashboard (slug, id) | bi.* dataset(s) | Populated for CPACK? |
|---|---|---|---|
| 1 | OEE Overview (`oee-overview`, id 1) — EXISTING, untouched | oee_shift, oee_hourly, downtimes, po_runtime | **Y** |
| 2 | Machine Speed (`machine-speed`, id 6) | equipment_speed (280k) | **Y** |
| 3 | Total Production (`total-production`, id 2) | oee_shift, oee_hourly, production_by_team | **Y** |
| 4 | Scrap Analysis (`scrap-analysis`, id 4) | oee_shift, oee_hourly | **Y** |
| 5 | Live Status (`live-status`, id 7) | live_status (18) | **Y** |
| 6 | Shift Report (`shift-report`, id 3) | oee_shift (122) | **Y** |
| 7 | Downtime Analysis (`downtime-analysis-cpack`, id 8) | downtimes (1.48M) | **Y** |
| 8 | Production Orders (`production-orders-cpack`, id 5) | production_orders (19.8k) + production_order_runtime (0) | **Y** (3/4 charts; runtime-OEE table empty) |

All 8 render for dev@ (native Admin → all-tenant sentinel); the only empty surfaces are
the PO-runtime-OEE table (`production_orders_runtime`=0) and any target reference line
(`production_targets`=0). Isolation intact (guest per-tenant, admin all-tenant).

---

## 3. Gap `bi.*` views created (codified, isolation-gate green)

Added to `db/superset/01-superset-ro-role.sql` (+ RLS in `02-tenant-rls.sql`, +
isolation fixture in `tests/superset/conftest.py`). Each carries `id_enterprise`.

| New view | Source table(s) | RLS strategy | Data? |
|---|---|---|---|
| `bi.equipment_speed` | equipment_values ⋈ equipments | transitive (equipment_values is a compressed hypertable → conditional-skip; isolates via equipments join) | Y |
| `bi.live_status` | DISTINCT ON equipment_values ⋈ equipments (6h) | transitive | Y |
| `bi.production_by_team` | equipment_values ⋈ equipments | transitive | Y |
| `bi.production_orders` | production_orders ⋈ equipments | native id_enterprise (direct policy) | N (empty) |
| `bi.production_targets` | production_targets ⋈ equipments | native id_enterprise (direct policy) | N (empty) |

**NOT built (no F3 base table):** `bi.setup_events` (no `setups` table),
`bi.production_scans` (no `scanned_boxes` table). **`bi.downtime_events`** is already
served at raw event grain by the existing `bi.downtimes`.

Isolation gate (`tests/superset/`) re-run locally against ephemeral Postgres → **10/10
pass**: every bi.* view exposes `id_enterprise`; every base table has an RLS policy;
guest per-tenant sees only its rows; admin all-tenant sentinel (`app.tenant_id=-1`)
sees all; unset GUC = fail-closed; guest clause cannot reach the sentinel.

---

## 4. LIVE-APPLY RUNBOOK (gated — run on the Superset host via SSM)

The compose profile does NOT auto-apply views or import assets — both are manual host
steps (as for the original OEE Overview). Coordinate with the error-fix agent first.

**Step A — apply the new views + RLS to the analytics DB** (additive; superuser bypass
makes FORCE RLS on `equipment_values`/`production_orders`/`production_targets` safe, same
as the 5 tables already live — but it IS prod DDL, so it is user-gated):
```sh
# On the r7g DB host (or any box that reaches it as postgres). 01/02 are idempotent.
psql "$ANALYTICS_DSN" -f db/superset/01-superset-ro-role.sql
psql "$ANALYTICS_DSN" -f db/superset/02-tenant-rls.sql
# (superset_ro password already set from a prior apply; no re-grant needed.)
```

**Step B — import the new dashboards** (SSM into the Superset host, `i-0a5c5dadd9ea5e93e`).
Build a bundle of ONLY the new datasets/charts/dashboards + copies of the shared
datasets they reference, then import with **overwrite=false** so the error-fix agent's
OEE Overview + shared datasets are NEVER clobbered:
```sh
cd /opt/packiot/stack/configs/superset
# zip the assets tree; import inside the superset container
docker cp assets superset:/tmp/assets && docker exec superset sh -lc '
  cd /tmp && zip -qr b.zip assets &&
  superset import-dashboards -p /tmp/b.zip -u "$SUPERSET_GUESTTOKEN_ADMIN_USER"'
# NOTE: the CLI overwrites by UUID; to be safe against the shared OEE Overview objects,
# prefer the API import with overwrite=false (see configs/superset/assets/README.md),
# or import a bundle that EXCLUDES oee_overview.yaml + the 12 OEE charts.
```

**Step C — materialize query_context on the NEW charts only** (so embed never 403s):
```sh
docker exec -e SUPERSET_ADMIN_USER=... -e SUPERSET_ADMIN_PASSWORD=... superset \
  python3 /app/pythonpath/../scripts/materialize_query_context.py \
    --chart-uuids <comma-list-of-the-new-chart-uuids>
# --chart-uuids scopes it to the new charts; the OEE Overview charts are left alone.
```
(Script: `scripts/superset/materialize_query_context.py`. Default mode only touches
charts whose query_context is null / placeholder-id 0, so it is safe even without the
allowlist, but pass the allowlist to be explicit.)

**Step D — verify** for dev@ (admin, all-tenant):
- Each new dashboard loads without error; data-ready ones show CPACK numbers; empty
  ones show "No results".
- Re-run the isolation gate (`./tests/superset/run.sh`) — already green here; re-run
  after any further RLS view. Guest (per-tenant) sees only ent3; admin sees all.

---

## 5. What's DONE vs REMAINING

- **DONE (codified + verified):** 5 gap views + RLS + isolation gate (10/10), 5 new
  datasets, ~27 charts + 7 new dashboards (query_context materialized), finalizer
  script, this doc.
- **REMAINING (gated on user / coordination):** run Steps A–D live on bi.prod (prod
  DDL + shared-Superset import — held to avoid racing the error-fix agent); the
  downtime + PO dashboards stay empty until the downtime/PO data migration to new-prod.
