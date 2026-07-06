# PowerBI compatibility test plan — ADR-0012 refactor gate

- **Status**: Test plan (2026-07-02)
- **Owner**: Emmanuel Podestá
- **Scope**: Every PowerBI-facing object identified on prod tsp12 (packiot40)
- **Prerequisite for**: Promoting the ADR-0012 refactor from sandbox to real staging → prod
- **Consumers**: PowerBI Desktop `.pbix` files hosted on customer machines (Deb, Wil, cust_13, cust_33, enterprise_06, cust_35), plus SAP integrations

## Why this exists

The ADR-0012 refactor consolidates customer-specific tables (`c35_*`,
`c33_*`, `enterprsie_*`, `customer_13*`) into pool-schema tables under
`customer_dashboards` and `customer_reports`, with façade views
preserving every historical name. This test plan verifies **PowerBI
reports keep working unchanged**.

Facade transparency is the whole point of the refactor. If any of
the 37 PowerBI-facing names diverge in shape, row count, or query
performance, the refactor is not shippable.

## Objects under test — 37 total (prod inventory)

Enumerated 2026-07-02 via SELECT-only query on prod tsp12:

### Customer dashboards (18)
```
public.c33_downtime_events
public.c33_setup_time_adjusted
public.c35_dashboard_paradas_24h
public.c35_dashboard_producao_24h
public.c35_dashboard_timeline_24h
public.c35_v_dashboard_timeline
public.c35_v_shifts_data
public.c35_v_stopped_time
public.report_shift_enterprsie_06     (typo preserved)
public.report_speed_enterprsie_33     (typo preserved)
public.sap_report_data_sync_customer_13
public.v13_mobile_power_bi_direct_query
```

### Customer 13 SAP/PowerBI views (19)
```
public.v_13_dt5min_piot4
public.v_13_labels_piot4
public.v_13_microstops_piot
public.v_13_overview_partial_scrap_rate
public.v_13_overview_takt
public.v_13_pos_piot4
public.v_13_production2_piot4
public.v_13_site_deb_dt5min_piot4
public.v_13_site_deb_equipment_list
public.v_13_site_deb_labels_piot4v_13
public.v_13_site_deb_microstops_piot
public.v_13_site_deb_pos_labels
public.v_13_site_deb_pos_piot4
public.v_13_site_deb_prod_per_equipment
public.v_13_site_deb_sap_report
public.v_13_site_wil_dt5min_piot4
public.v_13_site_wil_microstops_piot4
```

## Test dimensions per object

For each of the 37 objects, verify **all 5** dimensions pass. Any
one failure blocks the refactor promotion.

### Test 1 — Object presence

**Query** (run against `packiot_refactor` sandbox):
```sql
SELECT relkind, relnamespace::regnamespace FROM pg_class
WHERE relname = '<object_name>'
```

**Pass**: object exists in expected schema (usually `public`).

**Fail**: object missing → façade view wasn't created; refactor
migration incomplete.

### Test 2 — Column shape parity

**Query** (both `packiot.public` and `packiot_refactor.public`):
```sql
SELECT column_name, data_type, ordinal_position
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = '<object_name>'
ORDER BY ordinal_position
```

**Pass**: identical column names, same data types, same ordinal
positions. PowerBI relies on column ORDER for positional binding
in some report templates.

**Fail**: any column added, removed, renamed, or reordered.

### Test 3 — Row count parity (with time window)

**Query**:
```sql
-- On packiot.public
SELECT COUNT(*) FROM public.<object_name>
WHERE <time_column> >= now() - interval '24 hours';

-- On packiot_refactor.public (façade)
SELECT COUNT(*) FROM public.<object_name>
WHERE <time_column> >= now() - interval '24 hours';
```

**Pass**: identical row counts within a 24h window. Since the sandbox
doesn't have full production data, this test requires seeding the
sandbox with a representative snapshot (see §Preconditions).

**Fail**: counts differ → façade `WHERE customer_id = X` filter is
wrong, or canonical table missing rows.

**Note**: not all views have a natural time column. For those, use
`COUNT(*)` without a window.

### Test 4 — Query planner filter push-down

**Query**:
```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT * FROM <façade_object>
WHERE <typical_powerbi_filter>
```

**Pass**: planner shows an index scan (not sequential) AND the
façade's implicit `WHERE customer_id = X` is combined with the
outer filter into a single composite index scan. This is exactly
the pattern proven in the ADR-0012 POC (see
`docs/adr/reference/0012-poc-customer-dashboards.sql`).

**Fail**: sequential scan on the canonical pool table, or planner
doesn't inline the façade WHERE clause → query performance
regresses for PowerBI's typical filter patterns.

### Test 5 — Byte-identical row sample

**Query** (both sides):
```sql
SELECT * FROM <object_name>
WHERE <primary_key_field> = <sampled_value>
```

Take the same row on both sides and compare column-by-column.

**Pass**: byte-identical values (accounting for float representation
+ time zone display).

**Fail**: any drift → façade view definition has a bug in its
projection.

## Preconditions

1. **Sandbox seeded** — `packiot_refactor` must have the full
   ADR-0012 façade set applied (via
   `docs/adr/reference/0012-poc-customer-dashboards.sql` extended
   for every one of the 37 objects). Currently the POC covers
   only `c35_dashboard_producao_24h`, `c33_dashboard_producao_24h`,
   `c35_dashboard_paradas_24h`, `c35_dashboard_timeline_24h`.
   **The remaining 33 façades must be added before this test plan
   can run to completion.**

2. **Data snapshot** — Sandbox needs enough real data to make
   row-count parity meaningful. Two options:
   - **Manual seed**: pg_dump the last 24h of relevant rows from
     `packiot.public` (or prod, SELECT-only) into `packiot_refactor`.
   - **Live tap**: extend shadow-mirror to also write into
     `packiot_refactor` (skip for POC).

3. **PowerBI report definitions accessible** — Ideally, we'd pull
   the actual SQL queries from customer `.pbix` files to validate
   against. Without them, we approximate PowerBI's query patterns:
   - `SELECT * FROM <view> WHERE ts_value >= now() - interval '<N> days'`
   - `SELECT ts_value, SUM(<metric>) FROM <view> WHERE ... GROUP BY ts_value`
   - `SELECT DISTINCT <dim> FROM <view>`

## Test harness (planned)

A `scripts/test-powerbi-compatibility.sh` shell script that:

1. Enumerates the 37 objects from a canonical list file
2. For each object + each of the 5 test dimensions, runs the query
   against both `packiot.public` (source of truth) and
   `packiot_refactor.public` (façades)
3. Diffs results with clear pass/fail per test
4. Emits a Markdown report at `docs/powerbi-compat-report.md` with:
   - Object × test-dimension matrix
   - Per-failure details (expected vs actual)
   - Overall gate status: PROMOTABLE / BLOCKED
5. Exit code 0 on all-pass, non-zero on any fail (CI-friendly)

Ships as a follow-up PR once the sandbox has all 37 façades.

## Acceptance criteria

The refactor is promotable when:

- [ ] All 37 objects present in packiot_refactor with matching
      schema shape (Tests 1 + 2)
- [ ] Row-count parity within ±1% (Test 3) — allowing small drift
      for edge cases like FK resolution timing
- [ ] Query planner shows filter push-down for all 37 objects
      (Test 4)
- [ ] Byte-identical row samples on 3+ randomly-picked rows per
      object (Test 5)
- [ ] Test harness script exits 0 on a fresh sandbox reprovision

## What this DOESN'T test

- **PowerBI itself** — we don't execute against a real PowerBI
  Desktop / Service. We validate the SQL layer. Actual PowerBI
  quirks (visual layer, refresh cadence, ODBC driver quirks) are
  out of scope
- **Customer-hosted `.pbix` templates** — we don't have those.
  Customer sign-off on their own PowerBI post-refactor is a
  separate coordination step
- **SAP integration** — the `sap_report_data_sync_customer_13`
  family flows into SAP via a separate integration path. That
  integration should be tested by the SAP team, not this harness

## Timeline

- **Week 1**: extend sandbox with the remaining 33 façades (blocking
  #82 3-flow parity work anyway)
- **Week 2**: implement the test harness script
- **Week 3**: run against sandbox, fix any refactor gaps found
- **Week 4**: customer coordination + rollout to real staging

## References

- ADR-0012 — the refactor this gates
- `docs/adr/reference/0012-poc-customer-dashboards.sql` — the
  façade pattern
- `memory/project_staging_db_schema_map.md` — full prod schema
  audit context
