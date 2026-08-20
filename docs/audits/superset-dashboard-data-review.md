# Superset Dashboard — Data-Correctness Review (READ-ONLY)

> **HISTORICAL — superseded 2026-08-20.** F1/F2/F3 (the critical dilution findings below) are
> **fixed** in the current `db/superset/01-superset-ro-role.sql` on `production`/this branch:
> `bi.oee_shift`/`bi.oee_hourly` now carry `WHERE ts_value <= now() AND running_time > 0`. F6/F7
> ("empty" downtime/PO tables) are also stale — `docs/plans/cpack-superset-dashboard-buildout.md`
> (2026-08-12) recorded `equipment_events`=1.48M rows and `production_orders`=19.8k rows live.
> Kept here for the reasoning trail (how the dilution bug was found), not as current state — see
> the STATUS UPDATE at the top of `docs/plans/powerbi-to-superset-migration.md`.

**Date:** 2026-08-10
**Scope:** Every Superset asset under `configs/superset/assets/` (2 dashboards, 16 charts, 5 datasets) + the underlying `bi.*` views (`db/superset/01-superset-ro-role.sql`).
**Method:** Static review of view DDL / dataset+chart configs against the **live prod F3 schema**, plus **read-only SQL** run on the prod analytics DB (`packiot` @ `10.20.10.89`, reached via SSM through the prod app box `i-02d255a1c21fb1da3`, every statement in `BEGIN READ ONLY … ROLLBACK` with `app.tenant_id=3` stamped). **Nothing was modified.**
**Prod tenancy:** single tenant — `enterprises` = `{3: CPACK, active}`. All data below is CPACK.
**Coordination:** Another agent is concurrently fixing the OEE Overview *empty-time-window* + flipping front4. For OEE Overview this review therefore focuses on **value correctness / isolation / source-match**; the two most severe findings (F1/F2) are time-window-adjacent and are called out for that agent to fold in.

> ⚠️ **State caveat:** the `bi.*` views and RLS are **staged/inert** — they are NOT applied to prod yet (`db/superset/*.sql` is "apply by hand after the W2 go decision"). So the checks below compute what each view/chart **would** return by running the view's own SELECT logic against the base tables. Findings are about the *design* as it will behave on go-live.

---

## TL;DR — most-severe first

| # | Severity | Finding | Charts affected |
|---|----------|---------|-----------------|
| **F1** | 🔴 CRITICAL | **Unfiltered OEE/KPI charts show ~2% when the real running OEE is ~60%.** The KPI charts carry **no `time_range`** and the dashboards have **no native time filter** (`native_filter_configuration: []`), so they `AVG(oee)` over **all 7 750** shift rows — **5 518 of which are future-dated, zero-OEE, empty shift-calendar buckets**. `AVG(oee)` all-rows = **0.0198**; running-only = **0.6023**. | oee_gauge, availability/performance/quality bignumbers, shift_net |
| **F2** | 🟠 HIGH | **OEE is averaged across empty/idle shift buckets** — even the *windowed* charts are diluted (last-7-day `AVG(oee)` = **0.1179** vs running-only 0.60). Averaging a ratio over zero-production buckets is semantically wrong; needs time-weighting or an idle-bucket filter. | shift_breakdown, shift_oee_pivot, oee_trend_line, daily_net |
| **F3** | 🟠 HIGH | **Future-dated rows** in the base tables (5 518 shift rows up to 2026-09-09; hourly rows too). Any view/chart without an **upper** time bound includes them. `bi.*` views do not cap `ts_value <= now()`. | all shift/hourly charts w/o an upper bound |
| **F4** | 🟡 MEDIUM | **Implausible perfect scores** (L10-type artifact): `oee = 1.0` exactly on **11 / 82** active shift rows (13%) and 31 hourly rows; `oee_q = 1.0` on **65 / 82** (79%). Real data, not a view bug, but a factory viewer will distrust 100% OEE. Likely first-boot / single-sample shifts; quality rarely records scrap. | every OEE chart |
| **F5** | 🟡 MEDIUM | **Stored `oee` ≠ `oee_a × oee_p × oee_q`** in **32 / 82** active rows (>2% gap). The headline OEE and the A/P/Q legs don't reconcile by the textbook identity — charts showing them side by side will look inconsistent. Confirm the metric definition with the OEE team. | oee_gauge + A/P/Q bignumbers, pivots |
| **F6** | 🔵 EMPTY (genuine) | **Entire Downtime Analysis dashboard + the Overview downtime-pareto + Last-events table are EMPTY**: `equipment_events` (the downtime source) has **0 rows** for CPACK. Source choice is *correct* (`downtimes`/`plc_events` tables do **not exist** in F3). `duration` unit (INTEGER) is **unverifiable** until data lands — the dataset's own "assumed seconds" caveat stands and MUST be checked then. | all 5 downtime charts + events table |
| **F7** | 🔵 EMPTY (genuine) | **Production-orders-OEE table is EMPTY**: `production_orders` = 0 rows (CPACK runs no POs yet). | po_oee_table |
| **G1** | 🟢 GOOD | **`scrap = gross - net` is CORRECT** — byte-identical to the native `scrap` column (`Σscrap_native = Σ(gross-net) = 229 319`; 0 rows where they differ; **0** `net>gross`; **0** `scrap<0`). Semantic question (a) resolved: the derivation is right. | production bars, scrap metrics |
| **G2** | 🟢 GOOD | **Tenant key resolves cleanly** — the `equipments` join yields **0 NULL** `id_enterprise`, no fan-out (`id_equipment` unique in `equipments`: 62/62), 0 rows dropped by the inner join. RLS design is sound (see §Isolation). | all views |

---

## The dilution, in numbers (F1/F2/F3 — the load-bearing evidence)

`equipment_runtime_shift`: **7 750** rows, range 2026-07-30 → **2026-09-09** (a month in the *future*).

| Population | rows | `AVG(oee)` | `AVG(oee_a)` | `AVG(oee_p)` | `AVG(oee_q)` |
|---|---|---|---|---|---|
| **All rows** (what the unfiltered gauge/bignumbers show) | 7 750 | **0.0198** | 0.023 | 0.020 | 0.033 |
| Past rows only (`ts_value ≤ now`) | 2 232 | 0.0688 | — | — | — |
| Last 7 days (windowed like the trend charts) | ~ | 0.1179 | — | — | — |
| **Running only** (`running_time > 0`) — the real number | 82 | **0.6023** | 0.711 | 0.617 | 0.934 |

- Future/empty buckets: `ts_value > now()` = **5 518 rows, every one oee=0, gross=0, running_time=0** (shift-calendar pre-expansion by the OEE engine).
- Of the 2 232 past rows, only **88** have `gross > 0` and **82** have `running_time > 0`.
- Latest active shift row = `2026-08-10 18:00Z` = **now** → the pipeline IS live and current; the problem is purely the aggregation window/population, not staleness.

**Why it's wrong:** OEE is a ratio. Averaging it across shift buckets that never ran (oee=0) is not "0% efficient", it's "not scheduled / no data" — including them collapses the headline toward zero. A factory manager glancing at the gauge sees **2%** while the line is genuinely running at **~60%**.

**Fix (all three fold together):**
1. Give the dashboards a **default native time filter** on `ts_value` (e.g. *current shift* / *last 24h*) — the KPI charts currently have `adhoc_filters: []` and rely on a dashboard filter that doesn't exist. (This is the piece the concurrent OEE-Overview agent is touching — hand them F1.)
2. **Exclude zero-activity buckets** from the OEE aggregates: either add `WHERE running_time > 0` to `bi.oee_shift`/`bi.oee_hourly`, or make the chart metric `AVG(oee) FILTER (WHERE running_time > 0)`. Prefer time-weighting for a true rollup (`SUM(oee*running_time)/SUM(running_time)`).
3. **Cap the views at `ts_value <= now()`** (or add `always_filter_main_dttm`) so future calendar buckets never leak into any chart, regardless of the user's time range.

---

## Per-chart correctness matrix

Legend — Non-empty? / Sane? / Matches-source? are for **CPACK on prod today**.

### Dashboard: OEE Overview (`oee_overview.yaml`, uuid 6c4fa4a1…)

| Chart (file) | Source view | Metric | Non-empty? | Values sane? | Matches source? | Issues |
|---|---|---|---|---|---|---|
| OEE gauge (`oee_gauge`) | bi.oee_shift | `AVG(oee)` | ⚠️ shows **0.02** | ❌ diluted | ❌ | **F1** no time filter → all-rows avg incl 5 518 future zeros. Also mislabeled "current shift" (it's a grand AVG over all equipment × shifts). |
| Availability (`availability_bignumber`) | bi.oee_shift | `AVG(oee_a)` | ⚠️ 0.023 | ❌ diluted | ❌ | **F1**. Real running value 0.711. |
| Performance (`performance_bignumber`) | bi.oee_shift | `AVG(oee_p)` | ⚠️ 0.020 | ❌ diluted | ❌ | **F1**. Real 0.617. |
| Quality (`quality_bignumber`) | bi.oee_shift | `AVG(oee_q)` | ⚠️ 0.033 | ❌ diluted | ❌ | **F1**. Real 0.934; also **F4** (q=1.0 on 79% of active rows). |
| Shift production (`shift_net_bignumber`) | bi.oee_shift | `SUM(net)` | ✅ (~1.89M) | ⚠️ | ✅ sum matches | No time_range → **all-time** net, not "shift". Mislabeled + unbounded (harmless-ish since it's a SUM, but includes all history). |
| Daily production trend (`daily_net_bignumber_trend`) | bi.oee_hourly | `SUM(net)` | ✅ | ✅ | ✅ | `time_range: last day` — OK. |
| OEE trend hourly (`oee_trend_line`) | bi.oee_hourly | `AVG(oee/a/p/q)` by hour | ✅ | ⚠️ **F2** | ⚠️ | `last week`, so bounded, but idle hours pull the line toward 0. Acceptable as a *trend* but note the dilution. |
| Production by hour (`production_hourly_bar`) | bi.oee_hourly | `SUM(net)`,`SUM(scrap)` stacked | ✅ | ✅ **G1** | ✅ | scrap=gross-net verified. `last day`. OK. |
| Downtime by reason (`downtime_pareto`) | bi.downtimes | `SUM(duration)` by desc_category | ❌ **EMPTY** | n/a | n/a | **F6** equipment_events=0. `duration` unit unverified. |
| Last events (`events_table`) | bi.downtimes | raw rows | ❌ **EMPTY** | n/a | n/a | **F6**. All referenced columns exist in `equipment_events`. |
| Shift breakdown (`shift_breakdown_table`) | bi.oee_shift | AVG oee/a/p/q + SUM net/gross by equip×shift | ✅ | ⚠️ **F2/F4** | ✅ | Grouped, so per-equipment rows are meaningful, but idle shifts show 0; oee=1 rows present. |
| Production orders OEE (`po_oee_table`) | bi.production_order_runtime | raw per-PO | ❌ **EMPTY** | n/a | n/a | **F7** production_orders=0. Columns/mapping correct. |

### Dashboard: Downtime Analysis (`downtime_analysis.yaml`, uuid 087560b5…)

| Chart (file) | Source view | Metric | Non-empty? | Sane? | Matches? | Issues |
|---|---|---|---|---|---|---|
| Downtime by reason (`downtime_pareto`, shared) | bi.downtimes | SUM(duration)/desc_category | ❌ EMPTY | n/a | n/a | **F6** |
| Downtime by sub-category (`dt_by_subcategory_pie`) | bi.downtimes | SUM(duration)/desc_subcategory | ❌ EMPTY | n/a | n/a | **F6**. Verify `desc_subcategory` resolves to labels (not ids/NULL) when data lands. |
| Downtime by category daily (`dt_by_category_day_bar`) | bi.downtimes | SUM(duration)/desc_category ×day | ❌ EMPTY | n/a | n/a | **F6** |
| Category × shift pivot (`dt_category_shift_pivot`) | bi.downtimes | SUM(duration),COUNT ×planned | ❌ EMPTY | n/a | n/a | **F6**. Note: columns pivot on `planned_downtime` (bool), **not** shift — the slice name "× shift" is a **misnomer** (there is no shift column on bi.downtimes). |
| Last events (`events_table`, shared) | bi.downtimes | raw rows | ❌ EMPTY | n/a | n/a | **F6** |

### Orphan asset (defined, not on either reviewed dashboard)

| Chart (file) | Source | Issues |
|---|---|---|
| Shift OEE pivot (`shift_oee_pivot`) | bi.oee_shift | Not referenced in either dashboard `position` tree. Same **F2/F4** dilution as shift_breakdown if used. `last week`. |

---

## Semantic questions from the brief — resolved

- **(a) `scrap = gross - net`?** ✅ **Correct.** Verified against the native `scrap` column on `equipment_runtime_shift`/`_1hour`: identical to the last unit (0 rows differ), and consistent with the platform's own convention (`04-operator-views.sql`: `gross = net_production + scrap`). Never negative in practice (0 rows). *Minor note:* a native `scrap` column exists and is ignored by the views — the derivation is equivalent, so no fix needed, but exposing `scrap` directly would be cheaper/clearer.
- **(b) `bi.downtimes.duration` units.** Column is **INTEGER** on `equipment_events`. **Unverifiable — table is empty.** The dataset yaml already flags "assumed BIGINT seconds — verify". **Blocker for go-live of the downtime charts:** confirm seconds vs ms once CPACK emits events, or the pareto is 1000× off.
- **(c) A/P/Q transposed?** ✅ **Not transposed.** The view maps `rs.oee_a→oee_a` etc. 1:1. Running-only averages (A=0.71, P=0.62, Q=0.93) are ordered sensibly (quality highest, performance lowest). But see **F5** — `oee ≠ A×P×Q` in 39% of rows, so the headline and legs won't multiply out.
- **(d) Category/subcategory labels resolve?** Unverifiable (empty). `desc_category`/`desc_subcategory` columns exist; the pareto/pie group on the `desc_*` (text) columns, not the `cd_*` ids — **correct choice**. Re-check for NULLs when data lands.

---

## Tenant isolation (§5)

- Design is sound: `bi.*` are SECURITY-DEFINER views owned by `bi_owner` (NOLOGIN, **NOBYPASSRLS**); base tables carry RLS keyed on the `app.tenant_id` GUC via `current_tenant()`; `superset_ro` has **no** base-table grant. `production_orders_runtime` / `equipment_runtime_*` (no native `id_enterprise`) isolate via an `EXISTS` join to the RLS-protected `equipments`; `equipment_events` (compressed hypertable, can't take RLS) isolates **transitively** through the same join + the Superset guest-token clause as primary.
- Empirically: the `equipments` join yields **0 NULL `id_enterprise`** and no fan-out, so every exposed row carries a valid tenant key. **Cross-tenant leakage could not be empirically tested — prod has only one tenant (CPACK).** The 2-tenant CI isolation gate (`tests/superset/`) is the real proof; keep it blocking.
- ⚠️ Perf watch (already noted in `02-tenant-rls.sql`): the `EXISTS`-join RLS predicate on the hypertable-backed `equipment_runtime_1hour`/`_shift` can defeat chunk exclusion. Denormalize `id_enterprise` onto the rollups before this bites at scale.

---

## Recommended fix order

1. **F1 (CRITICAL, coordinate with OEE-Overview agent):** add a default native time filter + drop zero-activity/future buckets from the OEE KPI aggregates. This single change moves the gauge from a misleading 2% to a truthful ~60%.
2. **F3:** cap `bi.oee_shift`/`bi.oee_hourly` at `ts_value <= now()` so future calendar buckets can never leak.
3. **F2:** switch OEE rollup metrics to time-weighted (`SUM(oee*running_time)/SUM(running_time)`) or `FILTER (WHERE running_time>0)`.
4. **F5 / F4:** take to the OEE team — confirm `oee` vs `A×P×Q` definition and whether q=1.0/oee=1.0 buckets are first-boot artifacts to be suppressed.
5. **F6 duration unit:** confirm seconds vs ms before the Downtime dashboard goes live.
6. **Cosmetic:** rename `oee_gauge` ("current shift" → "average, selected range"), `shift_net_bignumber` (drop "shift" or add a window), and `dt_category_shift_pivot` ("× shift" → "× planned/unplanned").

---

## Reproduction

Read-only, via prod app box SSM shell → `psql` inside `stack-hasura-1` (reuses `HASURA_GRAPHQL_DATABASE_URL`), wrapped `BEGIN READ ONLY … ROLLBACK`. Key probes:

```sql
-- F1/F2/F3 dilution
SELECT round(avg(oee)::numeric,4) FROM equipment_runtime_shift;                       -- 0.0198 (all)
SELECT round(avg(oee)::numeric,4) FROM equipment_runtime_shift WHERE running_time>0;  -- 0.6023 (real)
SELECT (ts_value>now()) fut, count(*) FROM equipment_runtime_shift GROUP BY 1;        -- t=5518 zeros
-- F4/F5
SELECT sum((oee=1)::int) FROM equipment_runtime_shift WHERE running_time>0;           -- 11/82
SELECT sum((abs(oee-oee_a*oee_p*oee_q)>0.02)::int) FROM equipment_runtime_shift WHERE running_time>0; -- 32/82
-- G1
SELECT sum((abs(scrap-(gross-net))>0.5)::int), sum((net>gross)::int) FROM equipment_runtime_shift WHERE gross>0; -- 0,0
-- F6/F7 emptiness
SELECT count(*) FROM equipment_events;        -- 0
SELECT count(*) FROM production_orders;        -- 0
SELECT to_regclass('public.downtimes'), to_regclass('public.plc_events');  -- NULL, NULL (source choice correct)
```
