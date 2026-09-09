# Enterprise-06 / -13 Per-Tenant Report Object Parameterization Redesign

**Status:** DESIGN ONLY — nothing executed. Read-only survey of staging `packiot_analytics` (2026-09-09) + consumer code in `packiot-stack-alpha` (stream-engine, read-api), `back4-api`, and `edge-node-red`.

**Problem:** the legacy analytics DB carries a family of *per-enterprise* SQL objects — dedicated functions, carrier tables and views cut for one specific `id_enterprise` (the "06" family = enterprise 6 / Montebello-Montreal; the "13"/"customer_13" family = enterprise 13 / Neopac). The enterprise id is a hardcoded literal *inside the object body* rather than a parameter. Onboarding another customer to the same report today means copy-pasting the object under a new numeric suffix (`get_data_sync_enterprsie_09b`, `production_data_sync_enterprise_09`, …) — the anti-pattern this redesign kills.

> Note the historical misspelling **`enterprsie`** baked into every function name. The redesign drops it.

---

## 0. Executive orientation — what's already been done vs what remains

The new-stack forward-port (ADR-0012 Wave 2 / ADR-0014 P4) **already pool-ized the WRITE side**. stream-engine no longer runs the legacy per-enterprise procedures; it embeds their bodies and writes to *pool* tables that already carry a `customer_id` discriminator column:

| Pool table (already parameterized) | Columns | Written by |
|---|---|---|
| `customer_reports.speed` | `customer_id, id_equipment, id_order, …` | `reports.RunSpeed33` (fully generic — SQL takes `$1` = customer_id) |
| `customer_reports.shift` | `customer_id, line, shift, …, index2` | `reports.RunShift06` (writes generic, but READS legacy `get_report_shift_enterprsie_06c`) |
| `customer_reports.sap_data_sync` | `customer_id, linie, tag, shicht, …` (German) | `reports.RunSap13` (`__CUSTOMER_ID__` string-inject) |
| `production_data_sync_enterprise_06` | *(still per-enterprise-named target)* | `reports.RunSync06` (string-templated per enterprise) |

So the residual per-enterprise debt is concentrated in **two places**:

1. **The compute/read FUNCTIONS the writers still call** — `get_report_shift_enterprsie_06c`, `get_data_sync_enterprsie_06b`, `get_downtime_sync_enterprsie_06` — which hardcode `id_enterprise = 6`, `America/Montreal`, `id_site = 20`, `id_area not in (24)` in their bodies.
2. **The read-only VIEWS the read-api serves to external customers and front4** — `v_piot_production_data_sync_cust6`, `v_sap_report_data_sync_customer_13`, `v_13_site_deb_sap_report`, `v_13_overview_takt`, `v_13_overview_partial_scrap_rate` — each frozen to one enterprise.

stream-engine's current mitigation is **string-replacement templating** in Go (`sync06.go`: `ReplaceAll("id_enterprise = 6", "id_enterprise = 9")` and `get_data_sync_enterprsie_06b → _09b`). That is a code smell that *presumes the per-enterprise function will be cloned per tenant* — the exact anti-pattern. The redesign replaces it with a real SQL parameter.

---

## 1. Full inventory

### 1a. Functions (`pg_proc`)

| Object | Args | Returns | What is enterprise-specific | Live? |
|---|---|---|---|---|
| `public.get_report_shift_enterprsie_06c` | `(startdate date, enddate date)` | `TABLE(line,…,index2 jsonb)` — 23 cols | Body hardcodes `id_enterprise = 6`, `tp_equipment = 3`, `id_area not in (24)`, tz `America/Montreal`. Reads `equipment_oee_shift`. | **LIVE** — `reports.RunShift06` (`shift06.go` `shift06Insert`). |
| `public.get_data_sync_enterprsie_06b` | `(numdays integer)` | `SETOF data_sync_enterprise_06b` | Body hardcodes `id_enterprise = 6` in ≥4 joins (`equipments`, `production_orders`, `packml_register`). English column contract (Site/line/shift/PressCnt/PackCnt). | **LIVE** — `reports.RunSync06` (`sync06_body.sql` calls `get_data_sync_enterprsie_06b(21)`); read-api `/integration/job_data_integration/:id_enterprise` (`backingFn argc:1`). |
| `public.get_downtime_sync_enterprsie_06` | `()` | `SETOF downtime_sync_enterprise_06` | Body hardcodes `id_enterprise = 6`, grouped-microstop `id_site = 20` (Montreal) rule, `event_should_be_displayed` filter. Reads `equipment_events` + `_man`. | **LIVE** — read-api `/ext/montebello/events` (`runMontebelloEvents`, `backingFn argc:0`). |

**Not per-enterprise (matched the pattern spuriously — exclude):** the `h_piot_*` functions (`h_piot_get_downtimes_*`, `h_piot_set_production_target`, …) and the `piot_*` OEE builders take `in_id_enterprise` as a **parameter already** — they are the *correct* generic shape, not debt. The SAP-write path `upsert_sap_report_data_sync_customer_13()` has **already been retired** into `reports.RunSap13` (Go) and no longer exists as a DB function.

### 1b. Carrier / target tables (`pg_class` relkind `r`)

| Object | Rows | Role | Trap |
|---|---|---|---|
| `public.data_sync_enterprise_06b` | 0 | **SETOF rowtype carrier** for `get_data_sync_enterprsie_06b` | #235 SETOF trap — 0-row but **load-bearing** (`RETURNS SETOF data_sync_enterprise_06b`). Dropping it breaks the function signature. |
| `public.downtime_sync_enterprise_06` | 0 | **SETOF rowtype carrier** for `get_downtime_sync_enterprsie_06` | Same SETOF trap. |
| `public.production_data_sync_enterprise_06` | 0 (staging) | **Real target table** — the sync06 state machine's write target | Not a carrier; holds real data on prod. Read by `v_piot_production_data_sync_cust6`. |
| `public.v_13_overview_takt` | 0 | **STUB TABLE (relkind r, NOT a view)** — 4 cols `id_equipment, id_enterprise, id_site, avg_speed` | Named `v_` but is a table. read-api needs it to *exist* for a non-Hasura path; empty off ent 13. |
| `public.v_13_overview_partial_scrap_rate` | 0 | **STUB TABLE** — 8 cols `cd_equipment, id_enterprise, id_site, id_equipment, gross, net, scrap, scrap_rate` | Same — stub table, not a view. |

> `_hyper_13_*` chunks, `_materialized_hypertable_13`, `_direct_view_13`, `_partial_view_13`, `customer_reports.equipment_boxes_cust_13` and `pg_stat_gssapi` matched `%_13%`/`sap` **spuriously** — those are TimescaleDB hypertable-id-13 internals and a catalog view, NOT enterprise-13 objects. Excluded.

### 1c. Views (`pg_class` relkind `v`)

| Object | What is enterprise-specific | Consumer |
|---|---|---|
| `customer_reports.v_piot_production_data_sync_cust6` | Reads `production_data_sync_enterprise_06`; `America/Montreal`; hardcoded cutover ts `2025-02-20`; UNION of a frozen slice + a rolling 6h window | read-api `/ext/montebello/data-sync` (`runMontebelloDataSync`). |
| `customer_reports.v_13_site_deb_sap_report` | `id_enterprise = 13 AND id_site = 29`; tz `Europe/Budapest`; German SAP shape | read-api `/ext/neopac/sap-report` (`runNeopacSapReport`, `WHERE id_equipment = $1`). |
| `customer_reports.v_sap_report_data_sync_customer_13` | Pre-scoped to customer 13; **has no `id_enterprise` column** (tenant fence is the membrane assertion); German cols | read-api `/ext/neopac/sap-report-sync` (`runNeopacSapReportSync`). |
| `customer_reports.v_sap_report_data_sync_customer_13_deb` | `_deb` debug twin of the above | No live consumer found (likely dead / debug). Verify before drop. |

### 1d. Canonical DDL source

The CREATE statements for the `data_sync_enterprise_06`/`v_13_*`/etc. objects live in **`edge-node-red/db/00-schema.sql`** and the Hasura-parity files (`17-`, `19-`, `20-`, `23-*.sql`) — these are the *definers* (schema-parity snapshots), not consumers. Any redesign that changes object shape must update these parity files too or the next fresh-DB bootstrap re-creates the legacy objects.

---

## 2. Consumer map (blast radius)

### stream-engine (`services/stream-engine`) — WRITERS

| Report job | File | Reads (legacy per-ent) | Writes (pool) | Enterprise binding |
|---|---|---|---|---|
| speed33 | `internal/reports/speed33.go` | *(none — inlined SQL over base tables, `$1`)* | `customer_reports.speed` | `cfg.Speed33CustomerID` (`$1`), default **33** |
| shift06 | `internal/reports/shift06.go` | **`get_report_shift_enterprsie_06c(start,end)`** | `customer_reports.shift` | `cfg.Shift06CustomerID` (write only), default **6** — the READ fn is unparameterized |
| sap13 | `internal/reports/sap13.go` + `sap13_body.sql` | *(inlined, `__CUSTOMER_ID__`)* | `customer_reports.sap_data_sync` | `cfg.Sap13CustomerID`, default **13**; gated `SAP13_REPORT_ENABLED=false` |
| sync06 | `internal/reports/sync06.go` + `sync06_body.sql` | **`get_data_sync_enterprsie_06b(21)`** (string-templated to `_%02db`) | `production_data_sync_enterprise_06` (or `cfg.Sync06Target`) | `cfg.Sync06EnterpriseID`, default **6** — `ReplaceAll("id_enterprise = 6", …)` |

Wiring: `cmd/oeecloud-worker/main.go:279–296` (`LoopSpeed33/LoopShift06/LoopSap13/LoopSync06`). Config: `internal/config/config.go` (`SPEED33_CUSTOMER_ID`, `SHIFT06_CUSTOMER_ID`, `SAP13_CUSTOMER_ID`, `SYNC06_ENTERPRISE_ID`, `SYNC06_TARGET`).

**Key smell:** `sync06.go:44` — `ReplaceAll("get_data_sync_enterprsie_06b(21)", fmt.Sprintf("get_data_sync_enterprsie_%02db(21)", enterpriseID))`. This *assumes a per-enterprise function is cloned per tenant*. That is the anti-pattern the redesign removes: after the fix the call is `serving.data_sync($enterprise, 21)` with **no string templating**.

### read-api / refdata-api (`services/read-api/cmd/refdata-api`) — READERS

External customer sync + front4 dashboards, via the `externalShims` registry (`external.go`):

| Endpoint | Reads | Object | Tenant fence |
|---|---|---|---|
| `/ext/montebello/data-sync` | `v_piot_production_data_sync_cust6` | view | `runMontebelloDataSync` (`external_montebello_incoplast.go:117`), `site = UPPER($1)` |
| `/ext/montebello/events` | `get_downtime_sync_enterprsie_06()` | fn (argc 0) | `runMontebelloEvents:139`, `nm_site = UPPER($1)` |
| `/integration/job_data_integration/:id_enterprise` | `get_data_sync_enterprsie_06b` | fn (argc 1) | `runJobDataIntegration`, membrane owner-bind |
| `/ext/neopac/sap-report` | `v_13_site_deb_sap_report` | view | `runNeopacSapReport`, `WHERE id_equipment = $1` |
| `/ext/neopac/sap-report-sync` | `v_sap_report_data_sync_customer_13` | view | `runNeopacSapReportSync`, membrane (view has no id_enterprise) |
| datasets `overview-takt` | `v_13_overview_takt` | stub table | `datasets.go:974`, `EXISTS(equipments … $1)` fence |
| datasets `overview-scrap-rate` | `v_13_overview_partial_scrap_rate` | stub table | `datasets.go:982`, same fence |

The read-api already registers each object in `backingViews`/`backingFunctions` with a **drift gate** that checks EXISTENCE + ARITY at boot — so a signature change (fn args) is a *coordinated* Go+SQL deploy or the gate fails the service.

### back4-api — the ORIGINAL source (context)

The read-api shims are 1:1 ports of back4-api Node controllers: `back4-api/src/app/controllers/integrations/neopac/{data-sync,sap-report}.controller.js`, `repositories/JobDataIntegration/…`, `repositories/ApiMontebelloEvents/Downtimes.js`. Per `sap13.go` header (#223), back4-api's neopac `data-sync.controller.js` **co-writes** the SAP dataset — so the SAP pool-key cutover is coordinated with the back4 owner, not a unilateral deploy.

### edge-node-red — DEFINER only

`edge-node-red/db/00-schema.sql` + Hasura-parity SQL hold the CREATE DDL. No runtime consumer. Must be updated in lockstep so fresh-DB bootstrap emits the new generic objects.

### Superset — no direct dependency

`configs/superset/.../production_orders.yaml` is the only match and does not reference any per-enterprise object. Superset is **out of blast radius**.

### Blast-radius summary

| Object | # live consumers | Deploy coupling |
|---|---|---|
| `get_data_sync_enterprsie_06b` | 2 (stream-engine write + read-api integration) | SETOF signature → **coordinated** SQL+Go |
| `get_downtime_sync_enterprsie_06` | 1 (read-api) | SETOF signature → coordinated |
| `get_report_shift_enterprsie_06c` | 1 (stream-engine) | TABLE-returning → coordinated |
| `v_piot_production_data_sync_cust6` | 1 (read-api) | view swap |
| `v_13_site_deb_sap_report` | 1 (read-api) | view swap |
| `v_sap_report_data_sync_customer_13` | 1 (read-api) | view swap |
| `v_13_overview_takt` / `_partial_scrap_rate` | 1 each (read-api datasets) | stub-table swap |
| `production_data_sync_enterprise_06` | writer + `v_piot…cust6` reader | rename via config knob |

---

## 3. Why per-enterprise? — the actual divergence

There are **two distinct axes** of divergence, and they demand different fixes:

### Axis A — hardcoded id WITHIN a report family (the real anti-pattern → parameterize)

Within the **"06" / OEE-English family** (data-sync, shift, downtime, speed) the *only* thing that varies by enterprise is a set of **literals**: `id_enterprise`, timezone (`America/Montreal`), a site-scoped rule (`id_site = 20` grouped microstops), an area exclusion (`id_area not in (24)`). The *shape* (English columns Site/line/shift/PressCnt/PackCnt, the same joins, the same OEE math) is identical. The proof: stream-engine already string-templates this to serve enterprise 9 and 33 from the *same body*. **This is copy-paste with a hardcoded id → ONE parameterized function per report type serves all tenants**, with the tenant-specific literals (tz, site scope, area exclusions) pulled from config.

### Axis B — genuinely different report SHAPES across families (→ keep separate, still parameterize the id)

The **"13" / Neopac-SAP family** is a *different product*: German column contract (`linie, tag, shicht, rumpfe, gutmenge, rustzeit, produktionszeit, geplante_ausfallzeit`), `Europe/Budapest` timezone, `id_site = 29`, a distinct ERP sync envelope. This is **not** copy-paste of the "06" report — it is a separate customer contract. A single universal function **cannot** serve both families (their output columns differ). 

**Conclusion:** the design is **per-family parameterized functions** (not one universal function) + a **per-tenant config** (from `core.client_descriptors.descriptor` jsonb) supplying the literals. i.e.:
- ONE `serving.data_sync(id_enterprise)` replaces `get_data_sync_enterprsie_06b` **and** any future `_09b`/`_33b` clones.
- ONE `serving.sap_report_data_sync(id_enterprise)` replaces the customer_13 SAP views and serves future SAP customers.
- Timezone / site scope / area exclusions come from `core.client_descriptors.descriptor->'reports'`, **not** literals — killing the last per-enterprise thing in the body.

This is a **hybrid**: parameterize the id (Axis A), config-drive the tenant literals (both axes), keep the two report *shapes* as two function families (Axis B).

---

## 4. Parity baseline (capture before touching anything)

For each object, the redesign must prove **row-for-row + column-type identity** against the legacy object on prod. Baselines to capture (staging is empty for most, so **capture on prod under read-only**):

| Object | Parity capture | Note |
|---|---|---|
| `get_report_shift_enterprsie_06c` | 23-col signature (`line varchar … index2 jsonb`); run `(now-21d, now)` window and `md5(array_agg(row order by index1))` | Montreal calendar; verified ~358 rows on prod historically |
| `get_data_sync_enterprsie_06b(21)` | full column list + row hash for `numdays=21` | ~1,194 rows on prod (per sync06.go note) |
| `get_downtime_sync_enterprsie_06()` | column list + row count for last 15d | grouped-microstop site-20 branch must reproduce |
| `v_piot_production_data_sync_cust6` | col types (the COALESCE→0 + `numeric(10,2)` casts, `integer` presscnt) + row hash for `site=UPPER($site)` | node-pg JSON typing is contract (bigint→string) |
| `v_13_site_deb_sap_report` | German col list + row hash per `id_equipment` | Budapest tz |
| `v_sap_report_data_sync_customer_13` | 19-col German list (`linie,tag,shicht,…,id_order_label`) + row hash | no id_enterprise col |
| `v_13_overview_takt` / `_partial_scrap_rate` | 4-col / 8-col lists | empty stub tables — parity = column-shape only |

**Method (per object):** `SELECT md5(string_agg(t::text, '|' ORDER BY <pk>)) FROM legacy_obj t` vs the new generic object called with the same enterprise → identical hash = byte-parity. read-api has **golden tests** (`external_golden_test.go`, `external_montebello_incoplast_golden_test.go`, `datasets_test.go`) that pin the frozen envelopes — those are the automated parity harness; extend them to run against the new objects.

---

## 5. Proposed generic replacement

**Home schema:** `serving` (the read-serving layer already exists alongside `customer_reports`/`bi`). External-customer views stay in `customer_reports` as **thin generic wrappers** so the read-api path names don't churn; the compute moves to `serving` functions.

**Per-tenant config source:** `core.client_descriptors.descriptor` jsonb, new sub-object `descriptor->'reports'`:
```jsonc
"reports": {
  "timezone": "America/Montreal",        // Neopac: "Europe/Budapest"
  "site_scope": [20],                     // grouped-microstop / SAP site fence
  "area_exclude": [24],                   // shift report area exclusion
  "family": "oee_en"                      // or "sap_de"
}
```
A helper `serving.report_config(p_id_enterprise int) RETURNS jsonb` resolves it (fallback to sane defaults). This removes **every** hardcoded literal from the bodies.

### 5a. Function replacements (clean names, `enterprsie` killed)

| Legacy | Generic replacement | Signature |
|---|---|---|
| `get_report_shift_enterprsie_06c(date,date)` | `serving.report_shift(p_id_enterprise int, p_start date, p_end date)` | same 23-col `RETURNS TABLE` |
| `get_data_sync_enterprsie_06b(int)` | `serving.data_sync(p_id_enterprise int, p_numdays int)` | `RETURNS TABLE(...)` — **replace the SETOF-carrier** with an explicit `RETURNS TABLE` so the 0-row carrier table can be dropped |
| `get_downtime_sync_enterprsie_06()` | `serving.downtime_sync(p_id_enterprise int)` | `RETURNS TABLE(...)` — same, kill the carrier |

> Converting `RETURNS SETOF carrier_table` → `RETURNS TABLE(explicit cols)` is what lets us **drop the two 0-row carrier tables** (`data_sync_enterprise_06b`, `downtime_sync_enterprise_06`) — the #235 SETOF trap is dissolved, not worked around.

### 5b. View / external-endpoint replacements

| Legacy | Generic replacement | Notes |
|---|---|---|
| `v_piot_production_data_sync_cust6` | `serving.production_data_sync(p_id_enterprise int)` (function) + optional `customer_reports.v_production_data_sync` wrapper | read from the pool `production_data_sync` (renamed target) filtered by customer_id; move the `2025-02-20` cutover + tz into config |
| `v_13_site_deb_sap_report` | `serving.sap_site_report(p_id_enterprise int, p_id_equipment int)` | Budapest tz + site from config |
| `v_sap_report_data_sync_customer_13` | `serving.sap_report_data_sync(p_id_enterprise int)` | **add** an `id_enterprise` arg (legacy view had none — the fence moves from membrane-only to explicit param, membrane stays as defense-in-depth) |
| `v_13_overview_takt` | `serving.overview_takt(p_id_enterprise int)` | replace stub table with a real parameterized read |
| `v_13_overview_partial_scrap_rate` | `serving.overview_scrap_rate(p_id_enterprise int)` | same |
| `production_data_sync_enterprise_06` (target) | `customer_reports.production_data_sync` (pool, `customer_id` col) | mirrors the speed/shift/sap pool pattern; keeps sync06 write generic |

### 5c. Go changes per consumer

**stream-engine:**
- `sync06.go` — delete the `ReplaceAll` templating; call `serving.data_sync($1, 21)` binding `$1=enterpriseID`; write target `customer_reports.production_data_sync` with `customer_id`. Remove `Sync06Target` special-casing.
- `shift06.go` — `shift06Insert` FROM `serving.report_shift($1, start, end)` (add `$1` = customerID; today customerID is write-only).
- `sap13.go` / `speed33.go` — already generic on the write side; no change needed except pointing any legacy-view *reads* (none currently) at `serving.*`.
- Config: retire `SYNC06_TARGET`; keep the `*_CUSTOMER_ID`/`*_ENTERPRISE_ID` knobs (now real fn params). Consider a single `REPORTS_ENTERPRISE_IDS` CSV to fan the same generic job over multiple tenants (the endgame Axis-A payoff).

**read-api (`external.go` / `external_montebello_incoplast.go` / `datasets.go`):**
- Swap `backingViews`/`backingFunctions` names to the `serving.*` objects and **update the drift-gate arities** (`get_data_sync_enterprsie_06b` argc 1 → `serving.data_sync` argc 2; `get_downtime_sync_enterprsie_06` argc 0 → `serving.downtime_sync` argc 1).
- `runNeopacSapReportSync` — pass the injected `cid` as the new `$1` to `serving.sap_report_data_sync($1)` (today it passes `_ int` because the view had no id_enterprise). This *strengthens* the tenant fence.
- `datasets.go overview-takt/scrap-rate` — `FROM serving.overview_takt($1)` etc., keeping the `EXISTS(equipments … $1)` fence.
- Extend the golden tests to assert the new objects reproduce the frozen envelopes.

---

## 6. Phased cutover (expand → migrate → prove → contract)

The invariant throughout: **the two 06-family functions are SETOF-typed and read by two services each; the SAP objects feed an external Neopac customer sync + back4 co-writer.** Every phase keeps legacy + generic side by side until parity is proven.

### Phase 0 — Config seed (non-breaking)
- Add `descriptor->'reports'` to `core.client_descriptors` for ent 6 (Montreal) and ent 13 (Budapest). Ship `serving.report_config()` helper. No consumer change.

### Phase 1 — EXPAND: create generic objects alongside legacy
- Create `serving.data_sync`, `serving.downtime_sync`, `serving.report_shift`, `serving.sap_report_data_sync`, `serving.sap_site_report`, `serving.overview_takt`, `serving.overview_scrap_rate`, `serving.production_data_sync` as `RETURNS TABLE` (no carrier tables).
- Create pool `customer_reports.production_data_sync` (customer_id) next to `production_data_sync_enterprise_06`.
- **Update `edge-node-red/db/*.sql` parity files** so fresh bootstrap emits the generic objects.
- Legacy objects untouched → zero consumer impact.

### Phase 2 — PROVE parity (read-only, on prod)
- For each object, run legacy vs `serving.*(6|13)` and compare row-hash + column types (§4). Extend read-api golden tests. Gate: **byte-identical** for ent 6 and ent 13.

### Phase 3 — MIGRATE readers (read-api), coordinated Go+SQL deploy
- Repoint `backingViews`/`backingFunctions` + arities to `serving.*`; deploy read-api. The drift gate validates existence+arity at boot (fail-fast if SQL not yet applied → deploy SQL first, then Go).
- Neopac SAP sync + Montebello endpoints now served from generic objects. **Coordinate the SAP pool-key with the back4-api owner (#223)** before flipping the SAP write path.

### Phase 4 — MIGRATE writers (stream-engine)
- Deploy `sync06.go`/`shift06.go` reading `serving.*` and writing the pool `production_data_sync`. Remove string templating. Backfill the pool from `production_data_sync_enterprise_06` if history matters.
- Flip `SAP13_REPORT_ENABLED` only with the back4 owner.

### Phase 5 — CONTRACT: drop legacy
- After a dual-run soak with parity dashboards green, `DROP` in dependency order: views → functions → carrier tables (`data_sync_enterprise_06b`, `downtime_sync_enterprise_06`) → stub tables (`v_13_overview_*`) → the `production_data_sync_enterprise_06` target. Use `DROP … RESTRICT` first (0 dependents ⇒ safe, per #235 method). Remove the parity DDL from `edge-node-red/db`.
- Drop `v_sap_report_data_sync_customer_13_deb` early if confirmed dead.

---

## 7. Top risks

1. **SETOF-carrier signature change is a coordinated deploy.** `get_data_sync_enterprsie_06b` / `get_downtime_sync_enterprsie_06` are `RETURNS SETOF <carrier>` read by BOTH stream-engine and read-api. Converting to `RETURNS TABLE` and renaming = the DB object and *both* Go services must land together, or read-api's boot drift-gate fails (existence/arity mismatch). Sequence: **apply SQL → deploy read-api → deploy stream-engine**, never Go-first.
2. **SAP feeds an EXTERNAL customer (Neopac) + a co-writer (back4-api).** The `sap_report_data_sync` and `sap_site_report` outputs are consumed by Neopac's ERP sync; back4's `data-sync.controller.js` co-writes the pool (#223). A shape drift is a customer-visible incident. Freeze the German column contract; gate the SAP write flip on the back4 owner.
3. **`v_sap_report_data_sync_customer_13` has no `id_enterprise` column** — the tenant fence is membrane-only. Adding a `$1` param is *safer* but changes the SQL; prove the membrane + new param agree (no double-fence dropping rows).
4. **Two *shapes*, not one.** Do NOT collapse the OEE-English and SAP-German families into one universal function — their columns differ. Keep two function families; only the id + literals are parameterized.
5. **Timezone/site literals are load-bearing.** `America/Montreal` vs `Europe/Budapest`, `id_site=20` grouped-microstops, `id_area not in (24)`, the `2025-02-20` cutover in `v_piot…cust6`. Every one must move to config with the *exact* legacy value or the parity hash breaks.
6. **`edge-node-red/db` parity drift.** If the DDL parity files aren't updated in lockstep, the next fresh-DB bootstrap silently re-creates the legacy per-enterprise objects, resurrecting the anti-pattern.
7. **node-pg JSON typing contract.** `v_piot…cust6` casts (`numeric(10,2)`, `integer` presscnt, bigint→string) are frozen by the external client's parser. Preserve exact types in `serving.production_data_sync`.
8. **stream-engine string-templating removal is the deliberate anti-pattern kill** — but any tenant already onboarded via a cloned `_09b`/`_33b` function (if any exist on prod) must be migrated to `serving.data_sync($ent)` too. Audit prod `pg_proc` for other `get_data_sync_enterprsie_%db` clones before Phase 5.
