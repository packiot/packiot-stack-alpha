# ADR-0041 reference — QuickSight serve tier (the AWS-native PowerBI replacement)

**Companion to** [ADR-0041 §11](../../0041-gcp-exit-lakehouse.md) (the decision) and the lakehouse engineering spec [`0041-lakehouse-build-plan.md`](0041-lakehouse-build-plan.md). Where the build-plan doc ends at **Athena** (the query engine — the BigQuery replacement), this doc designs the **serve tier on top of it: Amazon QuickSight as the AWS-native PowerBI replacement**. Together they complete the AWS-native analytics stack: **Bronze → S3 → Glue → Athena → QuickSight**, retiring *both* the GCP BigQuery backend *and* the Microsoft PowerBI visualization + licensing surface, all inside the one-cloud/one-IAM boundary of [ADR-0038 §5.9](../../0038-north-star-factory-platform.md) (single-cloud principle).

**Status:** DESIGN / SCOPING ONLY. **Nothing here is provisioned.** No `aws_quicksight_*` resource is created, no QuickSight subscription is enabled, no PowerBI consumer is cut over, no prod object is touched. QuickSight is the lakehouse's **P4** phase — it is built only *after* Athena exists (build-plan P2) and the F2 refactor flip settles, and every customer cutover / PowerBI-retirement step is USER-gated (§4, §6). Prod/staging remain SELECT-only if probed.

> **Why "serve tier."** The medallion (ADR-0036) is *store → transform → serve*. Athena is the query engine; it does not *render*. PowerBI is what renders today (charts on customer machines). QuickSight is the render/serve tier that closes the loop — it is to Athena what PowerBI is to the ODBC-to-Postgres path it replaces.

---

## 1. What PowerBI does today — the migration surface

This is the surface we must reproduce. Sourced from the schema-map audit (`memory/project_staging_db_schema_map.md`), the PowerBI compat gate (`docs/guides/powerbi-compatibility-test-plan.md`, `docs/powerbi-compat-report.md`), and the prod OOM attribution (`docs/audits/prod-tsp12-oom-attribution-2026-07-13.md`).

### 1.1 Consumers & access path

- **Consumers:** PowerBI Desktop `.pbix` files hosted **on customer machines** — sites **Deb** and **Wil**, customers **cust_13**, **cust_33**, **enterprise_06**, **cust_35** — plus a **SAP** integration for customer 13. There is no PowerBI Service/Premium capacity we own; the reports live client-side and pull data live.
- **Access path:** **ODBC DirectQuery** against **prod `tsp12` / `packiot40`** through a dedicated Postgres role **`powerbi`**. This is a *live-query-against-the-OLTP-DB* pattern — every visual refresh runs SQL on the production serving DB.
- **Prod load attribution** (2026-07-13 OOM audit): the `powerbi` role burned **1.1 GB temp**, **88 min exec time**, and held **5 live connections** at snapshot time. So PowerBI is not just a licensing line — it is a **measurable load on the production Timescale DB**. Moving it to the offline lake (Athena) *removes that load from prod* as a side benefit, not only swaps a viz tool.

### 1.2 The objects PowerBI reads — 37 (+1) facing views/tables

The compat gate enumerates **37 PowerBI-facing objects** on prod (30 in the machine-checked gate list `docs/guides/powerbi-gate-objects.txt`). They cluster by function — and the cluster tells us the **visual type** each drives (see §3):

| Cluster | Objects (representative) | What it renders |
|---|---|---|
| **Overview KPIs** | `v_13_overview_takt`, `v_13_overview_partial_scrap_rate` | single-value KPI / gauge (takt time, scrap %) |
| **Downtime / stops** | `c33_downtime_events`, `c35_dashboard_paradas_24h` (*paradas*=stops), `c35_v_stopped_time`, `v_13_dt5min_piot4` (5-min downtime), `v_13_microstops_piot`, `v_13_site_deb_microstops_piot`, `v_13_site_wil_microstops_piot4` | bar charts (stop reasons), time-series (5-min) |
| **Production output** | `c35_dashboard_producao_24h` (*produção*), `v_13_production2_piot4`, `v_13_pos_piot4`, `v_13_site_deb_prod_per_equipment` | line/area (output over time), clustered bar (per-equipment) |
| **Timeline** | `c35_dashboard_timeline_24h`, `c35_v_dashboard_timeline` | **state-timeline / Gantt** (machine state over 24 h) — *see §3 gap* |
| **Shift / speed** | `c35_v_shifts_data`, `report_shift_enterprsie_06`, `report_speed_enterprsie_33`, `c33_setup_time_adjusted` | pivot/table + bar (per-shift, per-speed) |
| **Labels / lists / POs** | `v_13_labels_piot4`, `v_13_site_deb_labels_piot4v_13`, `v_13_site_deb_equipment_list`, `v_13_pos_piot4`, `v_13_site_deb_pos_labels` | tables / matrices |
| **Mobile** | `v13_mobile_power_bi_direct_query` | mobile-layout composite (KPIs + small charts) |
| **SAP data-sync** *(not a visual)* | `sap_report_data_sync_customer_13`, `v_13_site_deb_sap_report`, `production_data_sync_enterprise_06` | **ETL feed into SAP**, not a chart — *out of QuickSight scope, §3.4* |

**Key observation:** the naming (`_deb`, `_wil`, `_13`, `c33_`, `c35_`, `enterprsie_06`, `enterprsie_33`) is **per-tenant/per-site** — every object is already tenant-scoped. That is exactly the shape QuickSight row-level security expects, and it maps 1:1 to the lake's **`id_enterprise`-first partitioning** (build-plan §1). The tenant scoping is the same key at every layer (§2.3).

---

## 2. QuickSight architecture

```
   TimescaleDB (live, unchanged)                 front4 (React SPA, Amplify)
        │  batch export (build-plan §4)                 │  Cognito JWT (ADR-0034)
        ▼                                               ▼
   S3 lake  ──►  Glue Catalog  ──►  Athena  ◄────  QuickSight datasets
   (gold/bronze parquet)   (projection)   (engine v3)   │  ▲
        │                                               │  │ SPICE refresh (scheduled, daily)
        └──────── id_enterprise partition ──────────────┘  │
                                                     QuickSight analyses → dashboards
                                                           │  RLS by id_enterprise (tag-based)
                                                           ▼
                                     GenerateEmbedUrlForAnonymousUser (session tag id_enterprise)
                                                           ▼
                                            front4 <iframe> (embedded dashboard)
```

### 2.1 Datasets on Athena

A QuickSight **data source** points at the Athena workgroup `packiot-lake-<env>` (build-plan §5). On top of it, one **dataset per reporting table** — primarily the **Gold** rollups (`equipment_runtime_shift` / `_1hour` / `_1day`), which are the reporting source (build-plan §2.3), plus the `cq_logs` gold dataset (P3). Bronze datasets are reserved for ad-hoc/ML exploration, not standing dashboards.

Datasets carry the joins/derived fields (QuickSight **calculated fields**) that today live inside the PowerBI `.pbix` model or the `v_13_*` view SQL. Where a PowerBI report leans on a database view, we have two clean options, both AWS-native:
- **Push the logic into the lake** — the export job (or a `silver/` transform) materializes the shaped table, QuickSight reads it flat. Preferred for anything heavy/reused.
- **Athena view** — define the `v_13_*`-equivalent as an Athena/Glue view over the gold tables; QuickSight reads the view. Preferred for light per-customer shaping. (This is the direct analog of today's Postgres reporting views — same idea, Trino dialect.)

### 2.2 SPICE vs Direct Query — the load-bearing cost/latency choice

| | **SPICE** (in-memory import) | **Direct Query** (live Athena) |
|---|---|---|
| Latency | sub-second (in-memory columnar) | 2–10 s per interaction (Athena cold-ish) |
| Athena cost | **1 scan/dataset/day** (scheduled refresh) | **1 scan per filter/drill per reader** |
| Freshness | as of last refresh (daily) | live |
| Availability | decoupled from Athena | fails if Athena throttles |
| Extra cost | SPICE storage ($/GB/mo) | none |

**Recommendation: SPICE for all standing dashboards, refreshed daily right after the export job lands the partition.** The reasoning is that this reporting is **daily-grained and small** (build-plan §6: 10s of GB, gold is aggregated), and the batch cadence already makes the data *daily-fresh at best* — there is no live signal to preserve, so paying per-interaction Athena scans buys nothing. The elegant fit:

> The export job writes `…/id_enterprise=<t>/dt=<today-1>/` at ~02:00 UTC → an EventBridge/QuickSight **SPICE incremental refresh** (keyed on `dt`, small look-back window) re-imports only the new/changed partitions → readers hit in-memory data all day. **One Athena scan per dataset per day**, not one-per-reader-click. This caps the Athena bill at the same place the export cadence already caps freshness.

**Direct Query** is reserved for the rare ad-hoc Bronze deep-dive where an analyst genuinely needs a fresh, arbitrary slice — bounded by the workgroup bytes-scanned cap (build-plan §5) so it can't run away.

### 2.3 Per-tenant Row-Level Security — the isolation invariant must hold in QuickSight too

The tenant-isolation invariant (ADR-0038 §5.5 — *one tenant per scan, by construction*) cannot weaken at the BI layer. QuickSight enforces it with **row-level security keyed to `id_enterprise`**, and the design deliberately makes `id_enterprise` **the same key at every layer**:

| Layer | Where `id_enterprise` shows up |
|---|---|
| **Identity** | Cognito token claim (`custom:id_enterprise` / tenant mapping, ADR-0034) |
| **Embed** | QuickSight **session tag** `id_enterprise` passed to `GenerateEmbedUrlForAnonymousUser` |
| **RLS** | dataset **tag-based RLS rule** — rows returned only where `id_enterprise = ${session tag}` |
| **Storage** | **first S3 partition key** `…/id_enterprise=<t>/…` (build-plan §1) |
| **Query** | Athena `WHERE id_enterprise = <t>` predicate → partition prune |

One key, enforced at **five layers**. That is not redundant paranoia — it means (a) tenant isolation holds *by construction* even if one layer is misconfigured (defense in depth), and (b) **isolation and cost-control are the same mechanism**: the RLS `id_enterprise` filter *is* the partition-prune predicate, so a correctly-isolated query is also automatically the cheapest possible scan. Tenant A can never see tenant B's rows, and can never even *scan* tenant B's partitions.

**RLS mechanism choice:** use **tag-based RLS** (rules reference a session tag), not a permissions dataset (rules reference a QuickSight username). Tag-based is the multi-tenant-SaaS pattern — it works with **anonymous** embedded sessions (no per-end-user QuickSight account to provision), and the tag is set from the trusted Cognito claim by the embed-minting backend (§2.4). A permissions-dataset approach would force us to register every factory operator as a QuickSight user — unworkable at fleet scale.

### 2.4 Embedding into front4 — tie to the Cognito path

front4 is a static SPA on Amplify that already authenticates via **Cognito** (ADR-0034; `aws_cognito_user_pool_client.front4`, `terraform/staging/cognito.tf`) and already sends a Cognito JWT to refdata-api. QuickSight dashboards embed into front4 the same trust way:

1. front4 requests an embed URL from an **authenticated backend endpoint** — a small handler on **refdata-api** (it already verifies the Cognito JWT) or a dedicated embed Lambda. The browser never holds AWS credentials.
2. The backend **validates the Cognito JWT**, extracts **`id_enterprise`** from the verified claim (never from a client-supplied field — the isolation seam), and calls:
   ```
   quicksight:GenerateEmbedUrlForAnonymousUser(
     AwsAccountId, Namespace,
     AuthorizedResourceArns = [<dashboard arn>],
     SessionTags            = [{Key: "id_enterprise", Value: "<t>"}],   # drives RLS §2.3
     AllowedDomains         = ["https://staging.packiot.com"],          # origin allow-list
     SessionLifetimeInMinutes = 60)
   ```
3. The backend returns the signed, short-lived URL; front4 renders it with the **QuickSight Embedding SDK** (`amazon-quicksight-embedding-sdk`) inside an `<iframe>`. RLS + the session tag guarantee the reader sees only their tenant's rows.

**Why anonymous embedding (not registered-user):** registered-user embedding (`GenerateEmbedUrlForRegisteredUser`) requires each viewer to be a QuickSight user (IAM/identity-federated) — fine for a few internal CS analysts, wrong for hundreds of factory operators. **Anonymous embedding + session-tag RLS** is the AWS-blessed SaaS multi-tenant pattern and needs QuickSight **Enterprise + session-capacity pricing** (§5). Internal CS/analyst *authoring* uses registered accounts; embedded customer *viewing* uses anonymous sessions.

**Boundary with front4's own dashboards:** front4 already has a first-party dashboard composition engine (ADR-0029/0038 P10 — `front4/src/lib/dashboard/`) for the in-product OEE Overview. QuickSight does **not** replace that; it is the embedded surface for the **deep-analytical / report-shaped** views that PowerBI serves today (SAP-style shift/speed reports, per-equipment breakdowns, 24 h timelines) — the things you would *not* hand-build as first-party React widgets.

---

## 3. Visual parity — can we keep the same visuals?

**Verdict: YES for the analytical/reporting visuals — every standard OEE visual has a clean QuickSight equivalent. Four items are flagged (one real gap, three "rebuild-effort / out-of-scope").**

### 3.1 Direct-equivalent mapping (the bulk — clean)

| PowerBI visual (in use) | Source cluster (§1.2) | QuickSight equivalent | Clean? |
|---|---|---|---|
| Card / multi-row card (KPI) | takt, scrap rate | **KPI** visual | ✅ |
| Gauge | scrap %, takt vs target | **Gauge** chart | ✅ |
| Clustered / stacked column & bar | downtime reasons, microstops, per-equipment | **Bar chart** (H/V, clustered/stacked) | ✅ |
| Line / area | 5-min downtime, production over time | **Line chart** (+ area) | ✅ |
| Table | labels, equipment list | **Table** visual | ✅ |
| Matrix (pivot) | shift data, speed report | **Pivot table** | ✅ |
| Slicers (dropdown / date / relative-date) | site / shift / date filters | **Filter controls** (dropdown, date-range, relative-date) | ✅ |
| Drill-down (hierarchy) | site → area → equipment | **Field hierarchies + drill-down** | ✅ |
| Drill-through (to detail page) | overview → detail | **Navigation actions** (to another sheet) + **filter actions** | ✅ (rebuilt as actions) |
| Filled / bubble map | *(none observed)* | **Geospatial** (points/filled) | ✅ (available, unused) |
| Conditional formatting | thresholds on KPIs/tables | **Conditional formatting** | ✅ |

### 3.2 The one real gap — Gantt / state-timeline

`c35_dashboard_timeline_24h` / `c35_v_dashboard_timeline` render a **24 h machine-state timeline** (a Gantt-style band of running/stopped/changeover). **QuickSight has no native Gantt/state-timeline visual.** Options, in preference order:
1. **Stacked horizontal bar as a pseudo-Gantt** — one bar per equipment, segments colored by state, width = duration. Approximates the timeline; the standard QuickSight workaround. Loses precise hover-per-segment fidelity.
2. **Keep the state-timeline in Grafana** — Grafana's `state-timeline` panel is purpose-built for exactly this, and Grafana is already the ops-viz tool (§4.3). If the timeline is more operational than analytical, it may simply *stay in Grafana* rather than move to QuickSight.
3. **Custom-viz via QuickSight's limited extensibility** — weakest option; QuickSight has no PowerBI-`.pbiviz`-marketplace equivalent.

This is the **only visual PowerBI does today that QuickSight cannot reproduce natively.** Flag it explicitly to the timeline's owner (cust_35) at cutover.

### 3.3 Rebuild-effort items (not gaps, but not free)

- **DAX measures → QuickSight calculated fields.** Any `.pbix` DAX (measures, time-intelligence like `SAMEPERIODLASTYEAR`) does **not** port — it is **rewritten** as QuickSight calculated fields (different function library; QuickSight has `periodOverPeriod`/`lag`/window functions but different syntax). This is the main hand-labor of the rebuild — expected, since there is no importer (§4.1).
- **Marketplace / third-party custom visuals.** If any customer `.pbix` uses a PowerBI marketplace custom visual (e.g. a fancy KPI or a Sankey), QuickSight has a **fixed visual catalog** and no third-party custom-visual SDK. Inventory each `.pbix` at cutover; most OEE reports use only standard visuals, so this is low-probability but must be checked per customer.

### 3.4 Out of QuickSight scope — the SAP data-sync feeds

`sap_report_data_sync_customer_13`, `v_13_site_deb_sap_report`, `production_data_sync_enterprise_06` are **not visuals** — they are **ETL feeds into SAP** (the compat test-plan explicitly excludes SAP: *"flows into SAP via a separate integration path… tested by the SAP team, not this harness"*). QuickSight does not replace a data-sync pipeline. These stay a data feed; their only lakehouse concern is that their **upstream should read Athena/Gold instead of `tsp12`** — an export-job / data-API repoint (build-plan scope), **not** a QuickSight dashboard. Do not conflate the SAP feed with the visual migration.

---

## 4. Migration approach — rebuild, validate, cut, retire

### 4.1 Rebuild, not import

**There is no PowerBI → QuickSight migration/import tool.** `.pbix` is a proprietary Microsoft format; QuickSight cannot ingest it. Each dashboard is **rebuilt** — datasets + calculated fields + visuals authored fresh (via the QuickSight console for the first pass, then **captured as `aws_quicksight_analysis`/`template` JSON** so subsequent tenants/dashboards are reproducible-as-code, not hand-clicked). This is expected and bounded: the visuals are standard (§3.1), the data is already shaped in Gold, and the per-tenant objects share structure (`v_13_*` families repeat across sites Deb/Wil).

### 4.2 Phased cutover (parallel-run, then flip — per customer)

Reuse the **F2/F3 + PowerBI-compat parity discipline** (byte-exact where integer, tolerance-band where float), pointed at the new target:

1. **Build in parallel** — stand up QuickSight datasets + dashboards on the lake for one pilot customer (cust_13 is the richest — 19 of the 37 objects). PowerBI keeps running untouched.
2. **Validate side-by-side** — same object, same filter, **QuickSight-on-Athena vs PowerBI-on-tsp12**: row-count zero-drift + `sum(metric)` in-band per `(id_enterprise, dt)`. This is the *exact* discipline of `docs/guides/powerbi-compatibility-test-plan.md`, retargeted from `packiot_refactor` façades to the QuickSight/Athena render. Extend the harness with a QuickSight-dataset query leg.
3. **Cut consumers over, customer-by-customer** — the customer opens the **embedded front4 dashboard** (or a QuickSight reader link) instead of their `.pbix`. Get **sign-off per customer** (their numbers match) before retiring their `.pbix`. Same "customer sign-off is a separate coordination step" gate the compat plan already names.
4. **Retire PowerBI** — once *all* customers are signed off: drop the prod **`powerbi` role** + its ODBC path, decommission the 5 DirectQuery connections. This also removes the 1.1 GB-temp / 88-min prod load (§1.1). **USER-gated** (prod role change + external customer coordination).

**Parallel-run is correct here** (unlike the BigQuery leg's hard-cut): PowerBI *is* live with real consumers, so there is a legacy to run against — do not hard-cut.

### 4.3 Where QuickSight sits relative to Grafana — the boundary

| | **Grafana** (existing) | **QuickSight** (this design) |
|---|---|---|
| Audience | internal SRE / platform / CS-ops | customers + CS-analytics |
| Data | Prometheus + live Timescale (real-time) | offline lake / Athena (batch, daily) |
| Purpose | **operational** — service health, board 19, ~13 provisioned ops dashboards, alerting | **business/analytical BI** — OEE reports, shift/speed/downtime analytics, ad-hoc |
| Cadence | seconds / real-time | daily-grained |
| Replaces | (nothing — it *is* the ops tool) | **PowerBI** |

They are **complementary, non-overlapping**: Grafana never becomes a customer BI tool; QuickSight never does real-time alerting. The one debatable object is the **state-timeline** (§3.2) — if it reads as operational, it *stays in Grafana*; if analytical/customer-facing, it becomes the QuickSight stacked-bar workaround. And front4's **own** composition engine (P10) remains the primary in-product customer viz — QuickSight is the embedded *report/deep-analytics* surface beside it, not a replacement for it.

---

## 5. Cost model

**Edition: Enterprise is mandatory** — both **RLS** and **embedding** require QuickSight Enterprise (Standard supports neither). This is the single non-negotiable cost driver.

Approximate list pricing (**verify at build time — AWS pricing drifts**):

| Component | Model | Est. |
|---|---|---|
| **Authors** (CS/analysts who build) | Enterprise author seat | ~$18/user/mo (annual) / ~$24 monthly. Handful of authors → **~$36–72/mo** for 2–3 |
| **Readers — internal** | pay-per-session $0.30, capped **$5/reader/mo** | infrequent CS readers → **low $10s/mo** |
| **Readers — embedded (customer)** | **session-capacity pricing** (required for anonymous embedding) — a pre-bought bucket of sessions | scales with reader volume; a small committed bucket → **~$250/mo entry tier**, cheaper/session than pay-go at fleet scale |
| **SPICE storage** | $0.38/GB/mo Enterprise (10 GB/author included) | gold datasets are small (10s of GB, aggregated); realistically **< $10/mo** |
| **Q natural-language** (optional) | +$250/mo base + $0.50/question | **skip** unless the user wants NL query |

**Realistic footprint:** a small deployment (2–3 authors, modest embedded reader volume, SPICE < 20 GB) lands roughly **~$40–120/mo** without the embedded-session-capacity commitment, or **~$300+/mo** once anonymous embedding at scale is turned on with a session-capacity bucket. This is the **largest new line** the lakehouse adds — but note:
- It is still small against the **$1,670/mo** run-rate (`docs/ops/aws-cost-optimization.md`), and it **folds into the ~$5–15/mo lakehouse footprint** (S3+Athena+Glue) as the serve tier — SPICE keeps Athena scans at 1/dataset/day, so QuickSight does not blow up the Athena line.
- It **retires PowerBI licensing** (per-seat PowerBI Pro / any Premium capacity) **and** removes the 5 DirectQuery connections + 1.1 GB-temp / 88-min load from **prod Timescale** (§1.1) — a real prod-DB relief, not only a license swap.
- Net framing for the cost tracker: a new **"QuickSight BI serve tier"** line beside the **"GCP-exit lakehouse"** line, offset by **retiring PowerBI** and **reducing prod-DB DirectQuery load**.

**Aside — Amazon Managed Grafana:** if the user later wants to retire the self-hosted Grafana containers too, **Amazon Managed Grafana** is ~$9/active-editor/mo + ~$5/active-viewer/mo. Orthogonal to this design (Grafana stays operational, §4.3), noted only so the "one-cloud managed-BI" option is on record. Not in scope here.

---

## 6. Phased build plan — P4 (QuickSight serve tier)

QuickSight extends the lakehouse P0–P3 (build-plan §8) with a **P4**, gated on **P2 (Athena live) + the F2 refactor flip settling** (so the Gold data the reports read is the canonical post-refactor data, not a mid-migration shape).

| Phase | Name | Deliverables | Prod/external touch | Exit criteria |
|---|---|---|---|---|
| **P4a** | **Subscribe + wire** | Enterprise subscription; QuickSight **Athena data source**; **datasets** on Gold tables (+ `cq_logs`); **tag-based RLS** (`id_enterprise`); **SPICE** import + daily refresh schedule tied to the export cadence. Terraform: `aws_quicksight_*` (§6.1). | **No** (new AWS only; staging) | Datasets refresh green; RLS returns only the tagged tenant's rows; SPICE refresh fires after the export job. |
| **P4b** | **Rebuild dashboards** | Rebuild the 37-object set as QuickSight **analyses → dashboards**, grouped by customer (cust_13, cust_33, cust_35, ent_06, sites Deb/Wil); rewrite DAX → calculated fields; capture as `aws_quicksight_template` JSON. **Parity-validate** vs PowerBI (§4.2 step 2). | **No** (build); parity read is SELECT-only | Every migrated object matches PowerBI (row zero-drift + sum in-band); timeline gap (§3.2) resolved per owner. |
| **P4c** | **Embed in front4** | Embed endpoint on refdata-api (or a Lambda) minting `GenerateEmbedUrlForAnonymousUser` with the `id_enterprise` session tag from the verified Cognito claim (§2.4); front4 iframe via the embedding SDK; origin allow-list. | **No** (staging front4) | A staging Cognito user sees only their tenant's dashboard, embedded, RLS-enforced. |
| **P4d** | **Cut over + retire PowerBI** | Cut customers **one-by-one** with per-customer sign-off; then drop the prod **`powerbi` role** + ODBC DirectQuery path. | **Yes — USER-gated** (external customer coordination + prod role change) | All customers signed off on QuickSight; PowerBI ODBC path decommissioned; prod DirectQuery load gone. |

**Sequencing rule:** P4a–P4c are **staging + new-AWS-only, autonomous-eligible** (no prod write, no customer touch). Only **P4d** (external customer cutover + prod `powerbi`-role drop) is **USER-gated** — same discipline as the build-plan §8 teardown line and the compat plan's "customer sign-off is a separate coordination step."

### 6.1 Terraform surface (P4a — do not apply before the gate)

A new **`terraform/modules/quicksight/`** scaffold module (unrooted, like the lakehouse module), later wired into `terraform/staging` at P4a:

| Resource | Purpose |
|---|---|
| `aws_quicksight_data_source` (Athena) | points at the `packiot-lake-<env>` workgroup |
| `aws_quicksight_data_set` (per gold table) | with **`row_level_permission_tag_configuration`** → tag-based RLS on `id_enterprise` (§2.3); SPICE import mode |
| `aws_quicksight_refresh_schedule` | daily SPICE refresh after the export job |
| `aws_quicksight_analysis` / `aws_quicksight_dashboard` / `aws_quicksight_template` | the rebuilt dashboards, reproducible-as-code (P4b) |
| `aws_quicksight_group` + `aws_quicksight_*_permissions` | author/analyst grouping |
| **IAM — QuickSight service role** | read on Athena + Glue catalog + the **lake bucket** and **`athena-results/`** prefix (least-privilege to the workgroup output) |
| **IAM — embed-minting role** | `quicksight:GenerateEmbedUrlForAnonymousUser` scoped to the specific dashboard ARNs, assumed by the refdata-api/Lambda embed endpoint (§2.4) |

QuickSight **analyses/dashboards** are often authored in the console first, then exported to template JSON for Terraform — the same "define containers in TF, define the shaped artifact via the API/DDL" split the lakehouse module uses (module makes the bucket/workgroup; DDL makes the Glue tables).

---

## 7. Open questions / decisions to confirm at P4

1. **Embedded reader pricing tier** — pay-per-session vs session-capacity bucket depends on real reader/session volume, unknown until a pilot. Start metered, commit to capacity once volume is measured.
2. **Timeline gap resolution** (§3.2) — stacked-bar pseudo-Gantt in QuickSight, or leave the state-timeline in Grafana? Decide per the cust_35 owner at cutover.
3. **View logic placement** (§2.1) — push each `v_13_*` shaping into a `silver/` lake transform vs an Athena view. Default: Athena views for light shaping, `silver/` materialization for heavy/reused logic. Don't build `silver/` ahead of a consumer (build-plan §9.2).
4. **Custom-visual inventory** (§3.3) — audit each customer `.pbix` for marketplace visuals before promising 1:1 parity. Low-probability for OEE reports, but confirm.
5. **Embed endpoint home** — refdata-api handler (reuses its Cognito verifier) vs a standalone embed Lambda. Lean refdata-api (one fewer moving part; the JWT verification already lives there).
6. **SAP feed repoint** (§3.4) — the `sap_report_data_sync_*` upstream repoint from `tsp12` → Athena/Gold is a build-plan/data-API task, tracked separately from QuickSight. Confirm ownership so it isn't dropped.

---

## Cross-references

- [ADR-0041 §11](../../0041-gcp-exit-lakehouse.md) — the decision this doc details (QuickSight serve tier).
- [`0041-lakehouse-build-plan.md`](0041-lakehouse-build-plan.md) — the tier below (S3 + Glue + Athena); QuickSight reads its Gold datasets. §1 (partitioning), §2.3 (gold reporting source), §5 (workgroup cap), §6 (parity/cost).
- [ADR-0036 §2.4](../../0036-data-architecture-medallion.md) — the medallion; QuickSight is the *serve* of *store→transform→serve*.
- [ADR-0038 §5.9 / §6 A0](../../0038-north-star-factory-platform.md) — single-cloud principle + the GCP-exit milestone this completes (analytics-and-BI now AWS-native too).
- [ADR-0034](../../0034-adopt-cognito-amplify-auth.md) — the Cognito identity the embed path (§2.4) trusts.
- [ADR-0021 tenant-isolation gate](0021-tenant-descriptor-and-isolation-gate.md) / ADR-0038 §5.5 — the one-tenant-per-scan invariant RLS upholds (§2.3).
- `docs/guides/powerbi-compatibility-test-plan.md` — the 37-object inventory + the parity discipline reused in §4.2.
- `docs/audits/prod-tsp12-oom-attribution-2026-07-13.md` — the `powerbi`-role prod load that retirement removes (§1.1).
