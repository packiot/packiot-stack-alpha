# `analytics_v2` — mature ground-up target schema for `packiot_analytics`

**Status:** DESIGN + working PROOF-OF-CONCEPT with hardproof. Built live 2026-09-04
against `packiot_analytics` on `i-064bb36d1c454d861` (PG 15.17 / TimescaleDB 2.27.0),
account `639178078294`, `us-east-1`. **Only new objects were created, in schema
`analytics_v2`; no existing object was modified.** Production off-limits; legacy DB
(`18.220.223.110`) irrelevant here. Companion DDL: [`analytics-v2.sql`](./analytics-v2.sql).

> **SSM note:** the Run-Command document on this account is **`AWS-RunShellScript`**
> (not `AWS-RunShellCommand` → `InvalidDocument`). `get-command-invocation`
> `StandardOutputContent` truncates at ~2500 chars — write to a file on the box and
> retrieve in base64 chunks.

---

## 0. Why redesign — the problem in one paragraph

The current schema is a **Hasura-era accretion of 177 tables**. The metrics/serving
substrate that Superset + read-api sit on has four structural defects, each of which
this design fixes and (for the metrics layer) **proves fixed by equivalence**:

| # | Defect (current) | Fix (`analytics_v2`) |
|---|---|---|
| 1 | `agg_*` caggs are **flat** — every tier re-scans RAW `equipment_values`. | ONE **hierarchical** cagg family; each tier is an exact rollup of the tier below. |
| 2 | `avg(speed)` is stored per tier ⇒ **avg-of-avgs is wrong** when per-minute row counts differ. | Store decomposable partials `sum(speed)` + `count(speed)`; `avg = Σsum/Σcnt` is exact at every tier. |
| 3 | `agg_*` (6 keys) and `agg_*_10min/1hour` (~20 keys, state/order-preserving) are **different aggregations mislabelled as a hierarchy**. | Metrics family is a **pure time-hierarchy on the equipment grain**; categorical context is a separate concern. |
| 4 | ~55 unreferenced `h_piot_*` variants + `agg_` vs `ca_agg_` overlap = **serving cruft** (88 `h_piot_*` funcs exist; ~35 in contract). | One clean serving surface; cruft dropped after equivalence sign-off. |

Plus one **read-path correctness bug** to *not* reproduce (§5.3): Gold stores canonical
`A·P·Q`, but `h_piot_oee_score_*` re-derives the headline top-down (`Σnet/Σideal`),
disagreeing on ~60% of producing shifts (mean Δ 0.27).

---

## 1. Layered (medallion) target model

```
 RAW        equipment_values, equipment_events            (hypertables — kept as-is)
   │
 DIMENSIONS enterprises→sites→areas→equipments,           (FKs, typed, RLS)
   │        packml_register, shifts→shift_hours
   │
 SILVER     equipment_metrics_{1min,10min,1hour,1day}     (ONE hierarchical cagg family;
   │        (numeric partials: sum_net/gross/scrap,        sum+count partials → exact avg)
   │         sum_speed+cnt_speed, cnt_rows, max_speed)
   │
 GOLD       equipment_oee_{shift,hourly,daily}            (written by stream-engine Go
   │        (+ area/site variants = SUM of tier below)     worker; ONE canonical A·P·Q)
   │
 SERVING    bi.* views (stable contract, security_invoker) + clean h_piot_* fns
            → Superset, read-api
```

The dividing principle is **numeric vs categorical**. The SILVER metrics family carries
only *decomposable numeric measures* on the equipment × time grain, which is exactly why
its tiers telescope. Categorical/stateful context (machine `state`, `mode`,
`id_production_order`, downtime reasons) is a **different concern** served from
`equipment_events` and the Gold shift rollups — never a grouping key of the metric
rollup. This resolves the open blocker in `04_REVIEW_cagg_redesign_DECISION_NEEDED.sql`.

---

## 2. RAW layer (kept)

`equipment_values` (58 cols) and `equipment_events` are 1-dimension hypertables and stay
the source of truth. No schema change; `equipment_values` has **no RLS** (tenant scoping
is enforced downstream through the `equipments` join). The redesign only *adds* consumers.

---

## 3. DIMENSION layer

Conformed dimensions with real FKs and correct types. The current DB **already has** the
right PKs/FKs (verified live) — the redesign keeps them and adds RLS + `active` filtering
consistently.

| Dimension | PK | FKs (to) | RLS |
|---|---|---|---|
| `enterprises` | `id_enterprise` | — | tenant root |
| `sites` | `id_site` | `id_enterprise` | via enterprise |
| `areas` | `id_area` | `id_site`, `id_enterprise` | via enterprise |
| `equipments` | `id_equipment` | `id_area`, `id_site`, `id_enterprise`, `id_parentequipment`(self) | **FORCE RLS**: `is_all_tenant() OR id_enterprise = current_tenant()` |
| `packml_register` | `id_packml_register` | `id_equipment` | via equipment |
| `shifts` | `id_shift` | `id_enterprise` | via enterprise |
| `shift_hours` | `id_shift_hour` | `id_shift` | via shift |

**Tenant model (as discovered live — this IS part of the contract):**
`current_tenant() = NULLIF(current_setting('app.tenant_id', true), '')::int`;
`is_all_tenant() = current_tenant() = -1`. Superset/read-api connect as a **non-BYPASSRLS**
role and `SET app.tenant_id` per request; `-1` = cross-tenant (BI/admin), an enterprise id
= that tenant only. See §4.2 for the serving-view implication.

---

## 4. SILVER — the hierarchical metrics cagg family

### 4.1 The partial trick (why avg is exact at every tier)

`avg()` is **not** decomposable — you cannot rebuild an hourly average from twelve
5-minute averages unless every bucket had the same sample count. `sum()` and `count()`
**are** decomposable. So each tier stores the *partials* and the serving view divides:

```
1min : sum_speed = Σspeed,          cnt_speed = count(speed)        -- over raw rows
10min: sum_speed = Σ(1min.sum_speed), cnt_speed = Σ(1min.cnt_speed) -- pure summation
1hour: sum_speed = Σ(10min.sum_speed),cnt_speed = Σ(10min.cnt_speed)
serving: speed = sum_speed / NULLIF(cnt_speed,0)
       ≡ avg(speed) over ALL raw rows in the bucket   (proven exact, §6 HP-1)
```

All tiers share the identical 6 grouping keys `(bucket, id_equipment, id_enterprise,
id_site, id_area, tp_equipment)`, which is what makes tier *n+1* an exact `sum()` rollup
of tier *n*. Same pattern for `sum_net / sum_gross / sum_scrap` (already additive) and
`cnt_rows`. `max_speed` uses `max()` (also decomposable). `ideal_production_speed`
carries via `max()` (constant per equipment within a bucket).

### 4.2 Serving layer — `security_invoker` views

**Discovered live:** the current `bi.*` views are owned by **`bi_owner`** (non-superuser,
non-BYPASSRLS) and execute *definer-rights*; consumers get SELECT on the views only, and
tenant scoping works because `bi_owner` is subject to RLS and reads the session's
`app.tenant_id`. This works but couples the view owner into the security model, and a
postgres-owned copy of the same SQL silently returns **all tenants** (superuser bypasses
RLS) — a real footgun we hit during the PoC.

**Target:** create serving views `WITH (security_invoker = true)` (PG15+). RLS then binds
to the **calling** role (the read-api / Superset login), not the view owner. This is the
industry-recommended pattern precisely to eliminate the definer-bypass hazard, and it is
**proven to preserve tenant isolation** in §6 HP-2a (all-tenant and single-tenant both
match `bi.*` exactly). The caller must hold SELECT on the underlying tables/caggs.

---

## 5. GOLD — OEE (one documented computation)

### 5.1 Who computes it

**Correction to earlier lore:** OEE is **not** computed in the DB. It is computed by the
**stream-engine Go worker** (`services/stream-engine`, binary `oeecloud-worker`), which
`UPDATE`s the Gold rollup tables. The 17 `piot_create_*_runtime_*` DB procs only
**provision empty time-bucket skeletons** (`LoopProvision`, every 6h); the `h_piot_*`
functions only **serve reads**. The redesign **keeps the stream-engine as the compute
engine** (it is the modern, correct implementation) and cleans up only the DB *schema*
(tables + caggs + the `h_piot_*` serving sprawl).

### 5.2 The one canonical formula (`services/stream-engine/internal/rollup/oee.go`)

Gated by `OeeCanonicalAPQ`. All factors clamped to `[0,1]`; `OEE` **stored as the product**
so `oee == oee_a·oee_p·oee_q` holds by construction:

```
A = clamp01(running_time / available_time)                 -- available = elapsed − planned downtime
Q = clamp01(net / gross)
P = clamp01(gross / (ideal_speed_per_min · running_time/60))  -- DIRECT, not back-solved
OEE = A · P · Q
```

Gold `equipment_oee_shift` (target rename of `equipment_runtime_shift`) carries
`oee, oee_a, oee_p, oee_q, available_time, running_time, gross, net, scrap,
ideal_production, ideal_speed, target, proportional_target`, with a `CHECK` bounding every
factor to `[0,1]`. **Higher grains (day/week/month) and higher entities (area = tp3 lines
only; site = its areas) are the `SUM` of the tier below with factors re-derived from the
summed components — never recomputed from RAW.**

### 5.3 Bugs to fix (do NOT reproduce)

1. **Two coexisting OEE definitions.** Gold stores canonical `A·P·Q`, but the read path
   `h_piot_oee_score_*` recomputes the headline top-down (`Σnet / Σideal_production`, P a
   residual). ~60% of producing shifts differ by >0.01 (mean 0.27). **The redesign picks
   ONE — canonical `A·P·Q` — and serving SUMs the stored factors, never re-derives.**
2. **"Amber" copy-paste bug** — a *week* proc wrote to the *month* table (same family as
   the already-fixed self-select bug). Ground-up procs are generated from one template,
   parameterised by grain, so the class cannot recur.
3. **`stop_threshold_time` NULL platform-wide** ⇒ the micro-stop distinction is inert.
   Target makes it an explicit dimension default (documented), not a silent NULL.

---

## 6. HARDPROOF — equivalence (real outputs, 2026-09-04)

PoC materialized the metrics family over the recent 14 days (2026-08-21 → 09-04):
1-min = **689,999** buckets, 10-min = **76,474**, 1-hour = **13,985**.

### HP-1 — hierarchical 1-hour cagg ≡ direct RAW aggregation

Null-safe symmetric comparison, **all equipments, full 24 h** (2026-09-01):

```
 compared_buckets | gross_mismatch | net_mismatch | scrap_mismatch | sumspeed_mismatch | cntspeed_mismatch
------------------+----------------+--------------+----------------+-------------------+-------------------
             1593 |              0 |            0 |              0 |                 0 |                 0
```

Weighted-avg vs the naive avg-of-1-min-avgs (equipment 2000053, hour 03:00) — the bug the
partials fix:

```
 id_equipment |   truth   | v2_partial | flat_cagg_naive | v2_error | naive_error
--------------+-----------+------------+-----------------+----------+-------------
      2000053 | 35.896552 |  35.896552 |       36.697740 | 0.000000 |    0.801188
```

**v2 exact; the flat/naive rollup is off by 0.80.**

### HP-2a — `analytics_v2.oee_shift` ≡ `bi.oee_shift` (executed as `bi_owner`, RLS live)

```
ALL-TENANT (app.tenant_id = -1):
 v2_rows | cur_rows | v2_not_cur | cur_not_v2
---------+----------+------------+------------
    2293 |     2293 |          0 |          0

SINGLE-TENANT (app.tenant_id = 3):
 v2_rows | cur_rows | v2_distinct_ent | v2_not_cur | cur_not_v2
---------+----------+-----------------+------------+------------
    1948 |     1948 |               1 |          0 |          0
```

Exact match on the full column set, **and** the single-tenant run scopes to enterprise 3
only (0 rows leaked) — proving the `security_invoker` design preserves tenant isolation.

### HP-2b — `analytics_v2.equipment_speed_raw` ≡ `bi.equipment_speed` (byte-identical)

3 equipments × 1 day:

```
 v2_rows | cur_rows | v2_not_cur | cur_not_v2
---------+----------+------------+------------
   10197 |    10197 |          0 |          0
```

### HP-2c — NEW cagg `equipment_speed`: totals conserved, weighted avg exact, granularity documented

```
 id_equipment | old_raw_rows | new_1min_buckets |  new_gross   |  raw_gross   | d_gross | true_wavg_speed | new_wavg_speed | d_speed
--------------+--------------+------------------+--------------+--------------+---------+-----------------+----------------+---------
      2000053 |         2968 |             1435 | 5.102546e+06 | 5.102546e+06 |       0 |         72.6841 |        72.6841 |  0.0000
      2000054 |         3848 |              975 |        90893 |        90893 |       0 |         94.3693 |        94.3693 |  0.0000
      2000057 |         3381 |              922 |        83438 |        83438 |       0 |         97.0969 |        97.0969 |  0.0000
```

**Expected/intended diffs** (not regressions):
- **Granularity:** the new serving view is per-minute (2968 raw rows → 1435 buckets), not
  per-sample. Consumers needing per-sample rows use `equipment_speed_raw` (HP-2b, exact).
- **Weighted avg:** `speed` is now the correct decomposable weighted mean (`d_speed = 0`
  vs truth); the old per-row view substituted a derived speed for zero/null PLC speed.
- **Totals conserved:** `d_gross = 0` — no production is lost in the rollup.

---

## 7. Equivalence-validation plan for the remaining consumers

The PoC proves the *hard* parts (hierarchical caggs + the two representative views + RLS).
The remaining serving surface — **~33 more `h_piot_*` contract functions + 8 more `bi.*`
views** (`downtimes, equipments, live_status, oee_hourly, production_by_team,
production_order_runtime, production_orders, production_targets`) — is validated the same
mechanical, adversarial way before any cutover.

**Method (per consumer):**
1. **Freeze inputs.** Pick a fixed historical window (no live tail) and a tenant set
   `{-1, one busy enterprise, one quiet enterprise}`. Determinism requires
   `materialized_only = true` on the caggs for the window.
2. **Same RLS context.** Run both the `bi.*`/`h_piot_*` current object and its
   `analytics_v2` reproduction **as the same executing role** (`bi_owner` for definer
   views; the invoker role for `security_invoker`), with the same `SET app.tenant_id`.
   Comparing as `postgres` is invalid (superuser bypasses RLS) — this was the trap in the
   PoC.
3. **Symmetric-difference = 0.** `SELECT count(*) FROM (v2 EXCEPT current)` **and**
   `(current EXCEPT v2)` must both be 0 over the full projected column set. Use
   `IS DISTINCT FROM` / `FULL OUTER JOIN` so NULLs compare correctly. Round only the
   documented float columns and record the tolerance.
4. **Classify every non-zero diff** as either a **bug being fixed** (e.g. the two-OEE
   headline in `h_piot_oee_score_*`, §5.3 — expected to differ; assert the *new* value
   equals canonical `A·P·Q`) or a **regression** (must be driven to 0).
5. **Rollup integrity** (for every aggregate consumer): assert the cagg tier ≡ a direct
   RAW aggregation over the same window, exactly as HP-1 — this catches partial-column
   mistakes independently of the view SQL.
6. **Performance gate.** `EXPLAIN (ANALYZE, BUFFERS)` the current vs new plan; the
   hierarchical caggs must not re-scan RAW (assert no `Seq Scan on equipment_values` in
   the 10min/1hour path).

**Function batching.** Cluster the ~33 functions by their return composite; functions
sharing a composite share one comparison harness. Cross off each against the
consumer-contract inventory; the ~55 non-contract `h_piot_*` variants are **not** ported —
they are dropped after the contract set is green (defect #4).

**Cutover gate.** All contract views + functions symmetric-diff 0 (or diffs classified as
intended fixes with the new value asserted correct) across the three tenant contexts, on
two independent windows, with the performance gate met.

---

## 8. Reproduce / teardown

Full DDL in [`analytics-v2.sql`](./analytics-v2.sql). Refresh bottom-up (parents read the
child's materialization). Teardown is `DROP SCHEMA analytics_v2 CASCADE` + dropping the
three materialized views — fully reversible, RAW untouched.
