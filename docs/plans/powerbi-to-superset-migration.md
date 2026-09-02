# PowerBI → Superset Migration Plan (ADR "W3")

Status: DRAFT (2026-08-10). Owner: platform. Type: **extraction + plan**. The report
definitions have now been **extracted live** from the Power BI Service (read-only, via the
back4 service principal) — see §1.4. Nothing here is deployed; the Superset asset drafts in
`configs/superset/assets/` are inert import bundles.

> ## STATUS UPDATE (2026-08-20) — the plan executed; DONE and LIVE on `production`,
> **this PR ports it to `staging`**
>
> Between 2026-08-11 and 2026-08-12, a follow-on session (`feat/cpack-superset-full-dashboards`,
> repo PRs #790 + #794, merged straight to the `production` branch) **built and shipped** the
> full CPACK dashboard set this plan called for — **8 dashboards, 39 charts, 10 `bi.*`-backed
> datasets** — covering every gap view listed in §3 (`bi.live_status`, `bi.equipment_speed`,
> `bi.production_by_team`, plus `bi.production_orders`/`bi.production_targets` for the
> production-vs-target visuals). Verified LIVE on `bi.prod.packiot.app` this session (2026-08-20,
> via SSM `superset shell` on `i-0a5c5dadd9ea5e93e`): all 8 dashboards present
> (`oee-overview`, `shift-report`, `total-production`, `scrap-analysis`, `live-status`,
> `downtime-analysis-cpack`, `production-orders-cpack`, `machine-speed`), 39 charts, containers
> healthy 8+ days uptime. The critical **F1/F2/F3 dilution bugs** this repo's own audit
> (`docs/audits/superset-dashboard-data-review.md`, now historical) flagged are **fixed at the
> view level** in the current `db/superset/01-superset-ro-role.sql` (`bi.oee_shift`/`bi.oee_hourly`
> now carry `WHERE ts_value <= now() AND running_time > 0`), so the audit's F1–F3 findings no
> longer apply to what is live — F4–F7 (data-shape/definitional questions, not bugs) are unverified
> since that pass predates the CPACK data landing.
>
> **The gap this PR closes:** all of the above landed only on the `production` branch — it was
> **never merged/ported to `staging`** (`git diff origin/staging origin/production -- configs/superset
> db/superset` was a pure 64-file/3.5k-line addition; staging had none of it). See
> `docs/plans/cpack-superset-dashboard-buildout.md` (ported by this PR) for the full per-dashboard
> build log + live row counts.
>
> **One real bug found and fixed during the port (not cosmetic):** `configs/superset/assets/databases/packiot_analytics.yaml`
> was itself DRIFTED from what's actually live — it said `pgbouncer:6432/postgres`, but the live
> production registration (checked via `superset shell`, 2026-08-20) is a DIRECT connection to
> `10.20.10.89:5432/packiot`, bypassing pgbouncer. That's load-bearing, not incidental: the tenant
> isolation mechanism (`DB_CONNECTION_MUTATOR` in `superset_config.py`) stamps `app.tenant_id` as a
> libpq **startup option** per request — under pgbouncer's transaction-pooling mode that option is
> fixed for the lifetime of a pooled *server* connection, not the caller's request, so a reused pooled
> connection could serve one tenant's query with a stale/different tenant's stamp. Direct connection
> avoids that. The staging copy of this file is corrected to match (direct to `10.10.10.89/packiot_shadow`,
> staging's DB box) — **also fixed** `DB_CONNECTION_MUTATOR`'s tenant-stamp gate, which was hardcoded to
> `uri.database == "packiot"` and would silently never fire (fail-closed to empty dashboards, not a
> leak) against staging's `packiot_shadow` name; it now matches `packiot`/`packiot_shadow`/`packiot_analytics`
> so it survives the pending rename below with no further code change.
>
> **What this PR does NOT do:** stand up a running Superset instance
> on the staging box — `packiot-staging-app` (`i-06c9547a2c7091ab7`) has the `SUPERSET_*` secrets
> pre-provisioned in `.env` (12 keys) but `compose.superset.yml` has never been deployed/profile-activated
> there, and `db/superset/*.sql` has never been applied against staging's `packiot_shadow` database.
> That's a deliberate infra action left to a human (see the repo-root PR description for the exact
> run-list) rather than something to do unattended from an agent session.

> **UPDATE 2026-08-10 (extraction pass):** the earlier "we cannot read the reports without
> the user" boundary is **resolved**. The workspace is on **dedicated (Premium) capacity**,
> so the Power BI **Export API works** — we enumerated **75 reports / 67 datasets** and
> **exported + layout-parsed 17 priority reports** to full fidelity (pages, visual types,
> field bindings, datasources). Full capture: `docs/adr/reference/captures/0046-powerbi-workspace-inventory.md`.

Parent program: `docs/plans/front4-cognito-cutover-and-bi-migration.md` (W1 read-plane
cutover / W2 embedded Superset / **W3 = this doc**). W2 target tool is **decided:
Apache Superset** (re-cut from Metabase); scaffold spec at
`docs/plans/w2-embedded-superset.md`.

---

## TL;DR — the honest boundary

**What we CAN see from the repos (and reuse):**
- The **embed plumbing** end-to-end: front4 `ReportsPowerBi` → back4 `/getEmbedToken`
  (now also ported into edge-api `usecases/integrations/powerbi/`) → Azure AD
  service-principal → Power BI REST embed token. This tells us the **workspace GUID,
  the service-principal credentials, and one default report GUID**.
- The **real data model behind the reports**: the Power BI reports are **DirectQuery**
  against **per-tenant SQL views in prod Postgres** (`v13_mobile_power_bi_direct_query`,
  `c33_*`, `c35_*`, `v_13_*`, `report_shift_enterprsie_06`, `report_speed_enterprsie_33`,
  …). The OEE math is **in the SQL views, not in DAX** — this is the single most
  important finding, because it means the measures are already SQL and are highly
  portable to Superset.
- The **Superset semantic layer already exists as scaffolding**: `bi.*` curated views
  (`bi.oee_shift`, `bi.oee_hourly`, `bi.production_order_runtime`, `bi.downtimes`,
  `bi.equipments`) in `db/superset/01-superset-ro-role.sql`, plus a tested
  guest-token mint endpoint (edge-api PR #175).

**What we NOW have from the live workspace (extracted 2026-08-10, §1.4):**
- The **full report + dataset inventory**: 75 reports, 67 datasets, 0 dashboards, with
  page names for every report and per-visual field bindings for the 17 priority reports.
- **pbix exports** (dedicated capacity → Export API works) for the 17 priority reports:
  full `Report/Layout` (visual type + field bindings per page) + `DataModel` (VertiPaq).
- Confirmation that **every report DirectQueries/imports LEGACY prod Postgres**
  (`18.220.223.110` / `34.122.14.155`, db `packiot40`/`packiot`) — the OEE math is in the
  SQL views, exactly as predicted. The pbix "tables" are thin PQ wrappers over those views.

**What is still NOT read (one small residual):**
- The **per-tenant report→menu binding** (`v_menu_per_user_role.menu` JSONB). It lives in
  **legacy prod** (`packiot40`) — the same DB the guardrail says never to touch — so it was
  **not queried**. Report **priority is instead derived from the enterprise-id name prefix**
  (`01_`=Incoplast/CPACK, `06_`=Montebello sites, `13_`=Neopac, `37_`=Suzano, …) crossed with
  the active new-stack client roster (§1.4). To get the exact per-role binding, read the menu
  via the **new-stack refdata dataset `menu-per-user-role`** (not legacy prod) or with explicit approval.
- **DAX measures** are inside the VertiPaq `DataModel` binary; because the reports are
  DirectQuery the DAX is thin (see §2.1), and the field bindings already name the columns,
  so a byte-exact DAX dump was not required for the mapping. Recover it with Tabular
  Editor / DAX Studio / `pbi-tools` on the exported pbix only if a specific measure is unclear.

**Bottom line:** BOTH halves are now tractable. The *data* half is ~70% done (SQL views +
`bi.*` layer). The *presentation* half is a **structured manual rebuild** that can **start
now** — we have every report's pages, visual types, and field bindings.

---

## 1. Where the PowerBI reports live + how they're served

### 1.1 The embed chain (fully in-repo)

```
front4  src/pages/ReportsPowerBi/index.jsx
  │  <PowerBIEmbed> from powerbi-client-react; route /report/:dataset/:reportId
  │  POST /getEmbedToken { reportId }        ← reportId + dataset come from the SIDEBAR menu
  ▼
back4-api  src/app/controllers/PowerBIController/  (legacy; still the live token minter)
  │  index.js → embedConfigService.js → authentication.js
  │  service-principal (client-credentials) → Azure AD token
  │  GET  https://api.powerbi.com/v1.0/myorg/groups/{workspaceId}/reports/{reportId}
  │  POST https://api.powerbi.com/v1.0/myorg/GenerateToken   → embed token
  ▼
Power BI Service workspace  635f5c34-4183-4211-831b-241fbf1ec3dc   ← the reports live HERE
```

An edge-api port of the same broker already exists at
`edge-api/src/usecases/integrations/powerbi/` (ADR-0031 Family B) — same REST calls,
but secrets read from env instead of hardcoded. It is the un-cut-over shim; back4 is
still the live minter. (Note: the parent plan's "teach back4 to accept Cognito" interim
keeps PowerBI alive *during* W3; that's tracked separately and does not block this
migration.)

### 1.2 Identifiers we recovered from the repo

| Thing | Value | Source |
|---|---|---|
| Power BI workspace (group) GUID | `635f5c34-4183-4211-831b-241fbf1ec3dc` | back4 `index.js`, `config.json` |
| Default report GUID | `9746cfa2-10d7-494f-8fc2-b3a9a2ee55a2` | back4 `config.json` |
| Azure AD tenant GUID | `cea3ebef-b589-4f2a-8a46-74f9c3d1d781` | back4 `index.js` |
| Service-principal client (app) GUID | `527f65d9-719d-4ff3-b515-d56e131b939e` | back4 `index.js` |
| Service-principal client secret | **hardcoded in `back4-api/src/app/controllers/PowerBIController/index.js` + `config.json`** | back4 (⚠ see §6) |

> ⚠ **Security note (in passing, not the task):** the Power BI service-principal
> **client secret is committed in cleartext** in back4-api. It grants API access to the
> whole Power BI workspace. It should be rotated and moved to Secrets Manager
> regardless of the migration (edge-api's port already reads it from env). Flag to the
> user.

### 1.3 Where the reports actually are: Power BI Service, NOT the repo

- **No `.pbix` / `.pbit` / `.pbip` / `DataModelSchema` file exists in any packiot repo**
  (searched all ~25 repos under `~/github/packiot`). The reports exist **only** as
  published artifacts inside the Power BI Service workspace above.
- Per-tenant report GUIDs are **not in code** — front4 receives `:dataset/:reportId` as
  route params sourced from the tenant's menu (`v_menu_per_user_role.menu` JSONB,
  served via refdata dataset `menu-per-user-role`). So the authoritative list of "which
  reports exist and who sees them" is **a DB query on the menu**, or an enumeration of
  the workspace via the Power BI REST API using the service principal.

**→ Reports live only in the Power BI Service — but the service principal CAN read them.**
The workspace is on dedicated (Premium) capacity, so beyond enumerate, the REST **Export API**
(`GET /reports/{id}/Export`) returns the full `.pbix`. That path was exercised (§1.4).

### 1.4 ACTUAL report inventory (extracted live 2026-08-10)

Enumerated with the back4 service principal (client-credentials → AAD token → Power BI REST):
**75 reports** (74 `PowerBIReport` + 1 `PaginatedReport`), **67 datasets**, **0 dashboards**
in workspace `packiot40` (dedicated capacity `AF1A798C-…`). Full machine-readable capture:
`docs/adr/reference/captures/0046-powerbi-workspace-inventory.md`.

Reports are named `<entPrefix>_<Client>_<Purpose>`; the prefix is the enterprise/site id and
matches the per-tenant view families in §2.1. Priority below = enterprise prefix crossed with
the active/near-term new-stack client roster (CPACK, Incoplast, Montebello, Neopac, Suzano, Albea, Gulf).

| Priority | Report (GUID) | Pages (extracted) | Source PQ tables → views |
|---|---|---|---|
| **P0** | `01_INCOPLAST_PACKIOT` (`9746cfa2…`, the hardcoded default) | Setup · Downtime · Downtime_Shift | `01_Data_Setup_Incoplast`, `02_DOWNTIME_Incoplast` |
| **P0** | `06_Montebello_KENTUCKY_Shift_Report` (`0f5fc3a7…`) | Shift Report · Current Shift · JOBs · Report_Details · Shift Report 2 · LineStructure | `Shift_Report`, `Setups`, `LineStructure`, `Lines_Filter` |
| **P0** | `06_HWK_ShiftReports` (`d2d67e75…`) | Shift_Report · Downtime · Downtime List · DT Sectors | `Shift_Report`, `Stops`, `MICROSTOPS` |
| **P0** | `13_Neopac_DT_Since_Jan2022` (`9293d691…`) | Ausfall-Analyse · Liste der Ausfällen · Ausfall-General | `DT_Neopac`, `Lines_Filter` |
| **P0** | `13_OBD_MOBILE_direct_query` (`31234eb7…`) live status | Page 1 (9 KPI cards) | `RealTimeData` |
| **P1** | `37_Suzano_OEE_main_report2` (`4a6aaf6f…`) | OEE + OEE_{a,q,p}_{week,month} + Net_week + OEE_day + FrontPage (12) | `runtime_shift` (=equipment_runtime_shift) |
| **P1** | `37_DowntimeAnalysis` (`9c02bf5e…`) | Lista · Categorias · Microparadas · SubCategorias | `STOPS` |
| **P1** | `36-ALBEA_OEE_Stops_Production` (`df396d0d…`) | OEE (gauges+waterfall) · Shifts · Stops · List of Stops | `Cascata_OEE`, downtime views |
| **P1** | `10_GULF_CANS_OEE_main_report` (`37e68bb5…`) | OEE · Work Orders · Speed · Stops · Check_Resets · Speed_New | `Cascata_OEE`, `Speed`, `Stops_Coater` |
| **P1** | `01_CPACK_Sensors_Report` (`a662e67b…`) | SENSORES CPACK (import-mode, has data) | `Sensors`, `FilterDays` |
| **P2** | `01_SC_StopsReports` (`72d438d6…`) | Downtime List · Lista de Paradas | `Stops`, `MICROSTOPS` |
| **P2** | `04_Production_Control_Bruno` (`30293fc0…`) | Turno · POs · Caixas · Prensa_Etiquetas · Sensores | `Shifts`, `Shift_Labels`, `Press_Packed` |
| **P2** | `06_SETUP_ANALYSIS` (`adae5f0c…`) | Setup Analysis · Details | `Setup_Report` |
| **P2** | `13_Production_per_Team` (`89b0eb65…`) | Prod. per Team | `Prod_Teams` |
| **P2** | `05_Diameter_Product_Client_OPs` (`52440e4e…`) | Geral · Cliente_FOs · Cliente_Referência · Mensal | `Diameter_Clientes_Product` |
| **P3** | `02_Incoplast_Timeline2`, `33_Incoplast_Siegwerk_Frank` | timeline / test (import from **local dbeaver files**, not prod views) | File source |
| **skip** | `00_*`,`000_*`,`07_SAP_*`,`*Usage Metrics*`,`*_CQ_*`,`*Sensors_Report`,`teste_*` | admin / SAP-export / usage-telemetry / sensor-debug | out of scope (§3.6) |

**Distinct source-table catalog** (PQ query name → the prod SQL view it wraps; column names
recovered from field bindings). The heavy hitters, by cross-report reference count:

| PQ table (refs) | Key columns extracted | Grain → bi.* target |
|---|---|---|
| `Shift_Report` (99) | OEE/A/P/Q agg, Availability_DHM, {MNT,PLAN,PRO,RES,UNPLAN}_DT_dur, Run_dur, Scrap_Rate, AVG_PPM | shift × equip → **`bi.oee_shift`** (+ DT-by-class breakdown) |
| `Stops`/`STOPS`/`Stops_Coater` (81+47+12) | category, subcategory, duration, machine, dt_class, change_over, ts_event/ts_end | event → **`bi.downtimes`** (+ microstop bucket gap) |
| `runtime_shift` (26) | OEE_agg, OEE_{a,p,q}_agg, net, target, ideal_production, Availability_h | shift → **`bi.oee_shift`** |
| `RealTimeData` (18) | curr_info, gross, net, scrap_rate, id_order, last_update, txt_downtime_notes | live → **gap `bi.live_status`** |
| `Speed` (34) | clp, equipment, speed, speed2, ts_5min | 5-min speed → **gap `bi.equipment_speed`** |
| `01_Data_Setup_Incoplast`/`Setup_Report`/`Setups` (21+11+5) | Mechanical/Register/Color_min, Setup_total_min, Target_min, setup_start/end, clearance | setup/changeover → **gap `bi.setup_events`** |
| `Shift_Labels`/`Shifts`/`Press_Packed` (14+18+5) | box_order_number, increment, packed, target, prensado | scan/box → **gap `bi.production_scans`** (scanned_boxes) |
| `Prod_Teams` (18) | team1..team4, nm_equipment, dia | team production → **gap `bi.production_by_team`** |
| `DT_Neopac` (31) | txt_downtime_reason/notes, nm_equipment_type, ts_event, Dauer_h, Anzahl | event → **`bi.downtimes`** |
| `Cascata_OEE` (6) | Measure_OEE, Ideal_Prod_new, Display, id | OEE loss waterfall → **`bi.oee_shift`** metrics + waterfall viz |
| `Diameter_Clientes_Product` (51) | diameter, nm_client, nm_product, production_programmed, id_order | product dim → **gap `bi.product_orders`** (niche) |
| `LineStructure` (8) | line, machine, sector, pos_*, production_speed, stop_threshold_s | hierarchy dim → **`bi.equipments`** |

Slicers (`FILTER_*`, `*_Filter`, `Lines_Filter`, `Dias_Filter`, `Shift-Filter`, `WEEKENDS`)
are Power BI **slicers** → become Superset **native dashboard filters** (site/area/line/shift/date),
not charts.

---

## 2. The data model behind the reports

### 2.1 Key finding: the reports are DirectQuery over per-tenant SQL views

The compatibility gate that was run during the schema refactor
(`docs/powerbi-compat-report.md`, object list in
`docs/guides/powerbi-gate-objects.txt`) enumerates **30 Power BI-facing DB objects**.
Their names make the architecture obvious — they are **hand-built, per-enterprise /
per-site report views** in prod `public`:

| Object family | Example objects | Scope |
|---|---|---|
| Mobile / overview DirectQuery | `v13_mobile_power_bi_direct_query`, `v_13_overview_takt`, `v_13_overview_partial_scrap_rate` | site 13 |
| Downtime / microstops | `c33_downtime_events`, `v_13_microstops_piot`, `v_13_dt5min_piot4`, `c35_dashboard_paradas_24h` | equip 17 / ent 33 / ent 35 |
| Production / SAP sync | `v_13_production2_piot4`, `sap_report_data_sync_customer_13`, `production_data_sync_enterprise_06` | ent 6 / cust 13 |
| Shift / speed reports | `report_shift_enterprsie_06`, `report_speed_enterprsie_33`, `c35_v_shifts_data` | ent 6 / ent 33 |
| Timeline / labels / POs | `c35_v_dashboard_timeline`, `v_13_labels_piot4`, `v_13_pos_piot4`, `v_13_site_deb_*` | ent 35 / site 13 |

The full SQL definitions are captured in
`docs/adr/reference/captures/0012-wave0-prod-view-defs.sql`. Inspection confirms the
**OEE math is in the SQL** (e.g. `v13_mobile_power_bi_direct_query` computes duration,
joins speeds, filters `tp_equipment = 3` lines for site 13; `c33_downtime_events`
buckets `equipment_events` with `oee_p/oee_a/oee_q` from `equipment_runtime_shift`).

**Implication for migration:** because these are DirectQuery views, **DAX is almost
certainly thin** (formatting, a few running totals / percentages) — the heavy lifting
is server-side SQL Superset can point at directly. This is the best possible case for a
"no importer" migration. The risk is the opposite of DAX-heavy: these views are
**hardcoded per tenant** (`id_equipment = 17`, `id_site = 13`, one view per enterprise),
which is exactly the anti-pattern Superset RLS + a **parameterized `bi.*` view** should
replace with a single tenant-generic view.

### 2.2 What we now have as the Superset semantic layer (`bi.*`)

`db/superset/01-superset-ro-role.sql` (W2 scaffold, INERT until go) already defines a
clean, tenant-generic curated surface. Each row carries `id_enterprise` so Superset RLS
+ Postgres RLS can both key on it:

| `bi.*` view | Grain | Source table | OEE columns exposed |
|---|---|---|---|
| `bi.oee_shift` | shift × equipment | `equipment_runtime_shift` | `oee, oee_availability, oee_performance, oee_quality, count, gross, running_time` |
| `bi.oee_hourly` | hour × equipment | `equipment_runtime_1hour` | same set (trend workhorse) |
| `bi.production_order_runtime` | PO run | `production_orders_runtime` | `oee*, count, gross, begin/end_time` |
| `bi.downtimes` | downtime event | `downtimes` + `equipments` | `id_downtime_reason, begin/end/duration` |
| `bi.equipments` | dimension | `equipments` (active) | `nm_equipment, tp_equipment, id_area, lead_machine` |

These map to the F3 OEE columns (`oee_a/oee_p/oee_q`, `gross`, `net`, `count`) the
platform already computes. **The `bi.*` layer is the target Superset datasets bind to.**

### 2.3 Report-view → `bi.*` mapping (what's covered vs. what's a gap)

| PowerBI report view (data source) | Covered by existing `bi.*`? | Superset dataset to bind |
|---|---|---|
| `report_shift_enterprsie_06` (shift OEE) | ✅ `bi.oee_shift` (add enterprise-agnostic filter) | `bi.oee_shift` |
| `report_speed_enterprsie_33` (speed/perf) | 🟡 partial — needs a speed/rated-speed column | new `bi.equipment_speed` (gap, §3) |
| `v13_mobile_power_bi_direct_query` (live status + takt) | 🟡 partial — live status not in `bi.*` | new `bi.live_status` (gap, §3) |
| `v_13_overview_takt`, `v_13_overview_partial_scrap_rate` | 🟡 scrap-rate derivable from `count/gross`; takt = gap | extend `bi.oee_*` / new metric |
| `c33_downtime_events`, `v_13_microstops_piot`, `v_13_dt5min_piot4` | 🟡 event-grain; `bi.downtimes` is downtime-grain, not micro-stop 5-min buckets | new `bi.downtime_events` / `bi.microstops` (gap) |
| `c35_dashboard_paradas/producao/timeline_24h`, `c35_v_*` | 🟡 24h dashboards — timeline/stopped-time not in `bi.*` | new `bi.timeline` / reuse `bi.downtimes` (gap) |
| `production_data_sync_enterprise_06`, `sap_report_data_sync_customer_13`, `v_13_site_deb_sap_report` | ❌ SAP export shape, not OEE analytics | decide: keep as export, or `bi.sap_export_*` (gap) |
| `v_13_pos_piot4`, `v_13_site_deb_pos_*` | ✅ `bi.production_order_runtime` (+ PO dimension join) | `bi.production_order_runtime` |
| `v_13_site_deb_equipment_list`, `*_labels_*` | ✅ `bi.equipments` (labels = dimension attrs) | `bi.equipments` |

---

## 3. Gap list — measures/views with no `bi.*` equivalent yet

These need **new curated `bi.*` views/metrics** before the corresponding PowerBI page
can be rebuilt. Each must expose `id_enterprise` and have a Postgres RLS policy on its
base tables (the W2 isolation CI gate enforces "no bi.* view without a rule"):

1. **Live machine status / takt** (`v13_mobile_power_bi_direct_query`, `_overview_takt`)
   — current open events (`equipment_events.ts_end IS NULL`) + rated-speed takt. Base:
   `equipment_events`, `equipments`. → `bi.live_status`.
2. **Speed / rated-speed performance** (`report_speed_enterprsie_33`) — needs
   ideal/rated speed per equipment alongside actual. Base: speed source + `equipments`.
   → `bi.equipment_speed`.
3. **Micro-stops / 5-min downtime buckets** (`v_13_microstops_piot`, `v_13_dt5min_piot4`,
   `c35_v_stopped_time`) — event-grained/bucketed, finer than `bi.downtimes`. →
   `bi.downtime_events` (raw event grain) + a Superset time-bucket, or `bi.microstops`.
4. **24h timeline** (`c35_dashboard_timeline_24h`, `c35_v_dashboard_timeline`) — a
   Gantt/state-over-time source. → `bi.timeline`.
5. **Scrap / partial-scrap rate & takt metrics** — mostly derivable in Superset from
   `count`/`gross` on `bi.oee_*` as **calculated columns/metrics**, but confirm the
   exact PowerBI formula once the DAX is readable.
6. **SAP export views** (`*_sap_report`, `production_data_sync_*`) — these are ETL export
   shapes, not analytics; decide whether they belong in Superset at all or stay as
   report exports. Likely **out of scope** for Superset dashboards.

**Gap list is now evidence-backed** (validated against the extracted field bindings in §1.4),
not provisional. Confirmed gaps needing a new `bi.*` view before the page can be rebuilt:
`bi.live_status` (RealTimeData), `bi.equipment_speed` (Speed/clp/ts_5min),
`bi.setup_events` (setup/changeover minutes + clearance), `bi.production_scans`
(Shift_Labels/scanned_boxes increment), `bi.production_by_team` (Prod_Teams), and a
finer-grain `bi.downtime_events`/microstop bucket beneath `bi.downtimes`. Everything backed by
`Shift_Report`/`runtime_shift`/`Stops`/`DT_*` maps onto the **existing** `bi.oee_shift` /
`bi.downtimes` datasets with no new view. The one residual to eyeball per page is the exact
DAX filter/grain (thin, DirectQuery) — recover from the exported pbix DataModel if a specific
measure looks off, but the field bindings already name every column each visual reads.

---

## 4. How to EXTRACT a pbix definition (the toolchain)

A `.pbix` is a ZIP. The two parts that matter:

| Part | Contents | Extract with |
|---|---|---|
| `Report/Layout` | JSON: pages, visuals, positions, field bindings, filters | unzip + read JSON; or **`pbi-tools`** decompile → readable source tree |
| `DataModel` (VertiPaq) | tabular model: tables, relationships, **DAX measures**, Power Query (M) | **Tabular Editor** / **DAX Studio** (export measures); or `pbi-tools` extract → `DataModelSchema` JSON |

Practical extraction path once we have a `.pbix`:

```bash
# Layout (visuals/pages) — no special tooling needed for a first pass:
unzip -o report.pbix -d report_unpacked
#   report_unpacked/Report/Layout   → JSON (may be UTF-16); pages[].visualContainers[]

# Full decompile (model + layout as diffable source):
pbi-tools extract report.pbix        # → report/  (Model/, Report/ as JSON)

# DAX measures + model, interactively:
#   DAX Studio  → connect to the pbix → "All Measures" query, or
#   Tabular Editor → open pbix/model → export TMSL/TMDL
```

**What we actually did (2026-08-10):** option (2) — the service principal against the REST
API. The **license-tier question is answered**: `GET /myorg/groups?$filter=id eq '<ws>'`
returns `isOnDedicatedCapacity=True`, capacity `AF1A798C-7D8B-4E78-9595-482E1E680A8A`, so the
**Export API is available** and `GET /reports/{id}/Export` returned a full `.pbix` for every
priority report (e.g. `01_INCOPLAST_PACKIOT` = 408 KB; `13_Neopac_DT` = 14 MB import-mode).
The `Report/Layout` part parses directly (UTF-16 JSON → `sections[].visualContainers[].config.singleVisual`),
giving `visualType` + `projections` field bindings per visual (§1.4). No user pbix hand-off was needed.

Notes/limits hit:
- **`POST /datasets/{id}/executeQueries`** (DAX over REST) returned `DatasetExecuteQueriesError`
  (the "Dataset Execute Queries REST API" tenant setting is off / INFO functions blocked). Not
  needed — the pbix DataModel carries the model; parse it with Tabular Editor / DAX Studio /
  `pbi-tools extract` offline if a specific DAX measure must be recovered verbatim.
- The VertiPaq `DataModel` blob is compressed, so **string-grepping it for the native SQL did
  not work**; the underlying view is instead identified from the PQ table name + the datasource
  connection (`GET /datasets/{id}/datasources`) + the captured view defs.

Repro: the extraction scripts live in this session's scratchpad (`pbi_extract.py`,
`pbi_deep.py`, `batch_export.py`, `parse_layout.py`, `inventory.py`); they read the secret
from back4 `config.json` into memory only and never print it.

---

## 5. Recommended workflow (end-to-end)

1. **Inventory — ✅ DONE (§1.4).** Workspace enumerated via the service principal (75 reports /
   67 datasets). Ranked by enterprise-prefix + active-client roster. *Residual:* the exact
   per-role menu binding (`v_menu_per_user_role.menu`) — read it via the new-stack refdata
   dataset `menu-per-user-role` (not legacy prod) to attach precise per-tenant visibility.
2. **Extract — ✅ DONE for the 17 priority reports (§1.4).** pbix exported via the REST Export
   API; `Report/Layout` parsed → per-visual type + field bindings captured. *Remaining per report:*
   recover any non-obvious DAX from the exported pbix `DataModel` (offline, Tabular Editor / DAX
   Studio / `pbi-tools`) — only where a measure's grain/filter is ambiguous.
3. **Map to `bi.*`.** For each visual's data binding, map its source view/measure to an
   existing `bi.*` dataset (§2.3) or open a gap item (§3). Prefer promoting per-tenant
   report views (`v_13_*`, `c35_*`) into **tenant-generic `bi.*` views** carrying
   `id_enterprise`, so one Superset dataset + RLS replaces N hardcoded views.
4. **Fill gaps.** Add the new `bi.*` views from §3 (each with `id_enterprise` + an RLS
   policy in `db/superset/02-tenant-rls.sql`; the isolation CI gate blocks any view
   without a rule). Re-express any non-trivial DAX as a Superset **dataset calculated
   column** or **metric** (SQL), 1:1 with the DAX logic.
5. **Rebuild in Superset.** Recreate each report as a Superset **dashboard**; each visual
   → the nearest Superset **chart type** (see §5.1). Bind charts to `bi.*` datasets.
6. **Verify parity (the gate).** Pick a known tenant + period and compare the Superset
   numbers against the live PowerBI report cell-for-cell (mirror the existing prod-read
   fidelity method in `docs/powerbi-evidence-prod-read.md` / the compat gate). Sign off
   per report before decommissioning its PowerBI counterpart.
7. **Cut over.** Swap the tenant's menu item from the PowerBI embed route
   (`/report/:dataset/:reportId`) to the Superset embed. Migrate highest-usage tenants
   first; the rebuilt reports become the **curated seed set** customers then extend with
   W2 self-service.

### 5.1 PowerBI visual → Superset chart cheat-sheet

| PowerBI visual | Superset chart |
|---|---|
| Card / multi-row card (single KPI, OEE %) | **Big Number** / Big Number with Trendline |
| Gauge (OEE target) | **Gauge Chart** |
| Clustered/stacked column & bar | **Bar Chart** / **Time-series Bar** |
| Line / area (OEE trend, hourly) | **Time-series Line/Area** (bind `bi.oee_hourly`) |
| Donut / pie (downtime by reason) | **Pie Chart** (bind `bi.downtimes` grouped by reason) |
| Matrix / table (PO list, shift table) | **Table** / **Pivot Table** |
| Stacked-bar timeline / Gantt (24h state) | **Timeline / custom Gantt** (from `bi.timeline`) |
| Map | **deck.gl / MapBox** (rarely used here) |
| Slicers (site/area/line/date) | Superset **dashboard filters** (native filter bar) |

---

## 6. What the USER must provide (mostly UNBLOCKED now)

Extraction is no longer blocked — items 1 & 2 below are **resolved**. What remains is
decisions, not access:

1. ~~The reports themselves~~ **✅ RESOLVED** — extracted live via the service principal
   (dedicated capacity → Export API). 17 priority pbix exported + parsed (§1.4). The remaining
   ~58 reports (mostly admin/SAP/usage/sensor-debug, §3.6) are enumerable/exportable the same
   way on demand.
2. **Report→menu binding (optional refinement)** — to attach the exact per-role visibility,
   read `menu-per-user-role` via **new-stack refdata** (not legacy prod `packiot40`, which the
   guardrail keeps off-limits). Priority is already derived without it (§1.4).
3. **Confirmation of the W2 go decision** (Superset) so the `bi.*` layer + guest-token
   endpoint move from INERT scaffold to deployed — W3's rebuild target.
4. **(Independent of migration, but flag it — now more urgent):** the extraction used the
   **committed Power BI service-principal secret**; it is live and grants full workspace read.
   Rotate it and move to Secrets Manager (edge-api's port already reads it from env).

### 6.1 Superset assets drafted this pass

Report-derived charts + a dashboard that map **cleanly to the existing `bi.*` datasets**
(no new view required) were added to `configs/superset/assets/`:
- `dashboards/downtime_analysis.yaml` — replicates the recurring DT/stops report family
  (`37_DowntimeAnalysis`, `01_SC_StopsReports`, `13_Neopac_DT`, `06_HWK` DT pages,
  `01_INCOPLAST/Downtime`, `36-ALBEA/Stops`) over `bi.downtimes`.
- `charts/dt_by_subcategory_pie.yaml`, `dt_by_category_day_bar.yaml`,
  `dt_category_shift_pivot.yaml` — bind `bi.downtimes`.
- `charts/shift_oee_pivot.yaml` — the Montebello/HWK/Suzano shift-report OEE table over `bi.oee_shift`.

These are inert import bundles (stable UUIDs, cross-referenced by UUID). The gap-view pages
(Speed / Live-status / Setup / Team / microstops) are **not** drafted — they need the new
`bi.*` views in §3 first.

---

## 7. Automatable vs. manual — the honest split

| Step | Automatable? |
|---|---|
| Enumerate report GUIDs from the workspace REST | ✅ **done** — service principal, §1.4 |
| `pbix` export (REST) + unzip → layout/DataModel | ✅ **done** — Export API works (dedicated capacity) |
| Parse layout JSON → per-visual field/type inventory | ✅ **done** — `parse_layout.py`/`inventory.py` |
| Map report views → `bi.*` datasets | 🟡 semi — mechanical for the covered set, judgement for gaps |
| Re-express DAX → SQL metrics | 🟡 semi — most are thin (DirectQuery); non-trivial ones by hand |
| **Rebuild visuals/layout in Superset** | ❌ **manual** — no importer; visual-by-visual |
| Parity verification vs live PowerBI | 🟡 semi — reuse the prod-read fidelity harness pattern |

There is **no `.pbix` → Superset importer** and there will not be one; the presentation
rebuild is inherently manual. The value that *is* automatable/portable is the data model
— and that is already ~70% done via the DirectQuery SQL views + the `bi.*` layer.

---

## 8. References (in-repo)

- Embed plumbing: `back4-api/src/app/controllers/PowerBIController/{index,embedConfigService,authentication,utils}.js`;
  edge-api port `edge-api/src/usecases/integrations/powerbi/`.
- front4 consumer: `front4/src/pages/ReportsPowerBi/index.jsx`, `src/routes.jsx`,
  `src/components/Header/components/ListaSideBar.jsx`.
- **Extracted workspace inventory (2026-08-10):** `docs/adr/reference/captures/0046-powerbi-workspace-inventory.md`
  (75 reports + pages + priority datasources).
- Report data model (SQL): `docs/guides/powerbi-gate-objects.txt`,
  `docs/adr/reference/captures/0012-wave0-prod-view-defs.sql`,
  `docs/powerbi-compat-report.md`, `docs/powerbi-evidence-prod-read.md`.
- Superset report-derived assets (this pass): `configs/superset/assets/dashboards/downtime_analysis.yaml`
  + `configs/superset/assets/charts/{dt_by_subcategory_pie,dt_by_category_day_bar,dt_category_shift_pivot,shift_oee_pivot}.yaml`.
- Superset semantic layer + embed: `db/superset/01-superset-ro-role.sql`,
  `db/superset/02-tenant-rls.sql`, `docs/plans/w2-embedded-superset.md`, edge-api PR #175
  (`POST /api/superset/guest-token`).
- Parent program: `docs/plans/front4-cognito-cutover-and-bi-migration.md` (W1/W2/W3).
