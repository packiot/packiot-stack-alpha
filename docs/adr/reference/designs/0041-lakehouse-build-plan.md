# ADR-0041 reference — offline lakehouse concrete build plan (S3 + Glue + Athena)

**Companion to** [ADR-0041](../../0041-gcp-exit-lakehouse.md) (the decision) and [ADR-0036 §2.4](../../0036-data-architecture-medallion.md) (the medallion offline tier). This file is the **engineering spec**: bucket layout, parquet schema mapping, Glue DDL with partition projection, the batch export job shape, the Athena workgroup, the parity harness, and the `cq-logs` repoint. It carries the detail the ADR summarizes so the ADR stays readable.

**Status:** DESIGN / SCOPING. **Nothing here is provisioned.** The Terraform under [`terraform/modules/lakehouse/`](../../../../terraform/modules/lakehouse/) is a **scaffold module that is not wired into any root** (`terraform/staging` or `terraform/production`) — `terraform apply` in either env does not touch it. The Glue DDL ([`../migrations/0041-glue-catalog-ddl.sql`](../migrations/0041-glue-catalog-ddl.sql)) is Athena-dialect DDL to run *by hand or via CI once P0 is approved* — no migration runner executes it. Every prod/GCP-touching step remains USER-gated per ADR-0041 §5.2.

---

## 0. What we are building, in one paragraph

A **read-only, idempotent, watermark-driven batch job** copies closed windows of the immutable Bronze tier (`equipment_values_raw`, `equipment_events_raw`) and the Gold rollups (`equipment_runtime_*`) out of TimescaleDB into **partitioned Snappy-parquet on S3**, laid out `…/<layer>/<table>/id_enterprise=<t>/dt=<YYYY-MM-DD>/`. A **Glue Data Catalog** table (defined with **partition projection**, no crawler) describes each dataset, and **Athena engine v3 (Trino)** queries it serverlessly, pay-per-TB-scanned. The `cq-logs` Lambda is rebuilt on `pyathena`/`boto3` to read this lake instead of the never-shipped BigQuery path. The live serving path (Timescale + refdata-api) is untouched — this is offline-only (ADR-0036 §2.2).

---

## 1. S3 bucket & object layout

**One bucket per env**, layer-prefixed, mirroring the medallion so anyone who knows the live DB can navigate the lake:

```
s3://packiot-lake-staging/                 (later: packiot-lake-prod)
├── bronze/
│   ├── equipment_values_raw/id_enterprise=4/dt=2026-07-20/part-000.snappy.parquet
│   └── equipment_events_raw/id_enterprise=4/dt=2026-07-20/part-000.snappy.parquet
├── gold/
│   ├── equipment_runtime_shift/id_enterprise=4/dt=2026-07-20/part-000.snappy.parquet
│   ├── equipment_runtime_1hour/id_enterprise=4/dt=2026-07-20/...
│   └── equipment_runtime_1day/id_enterprise=4/dt=2026-07-20/...
├── silver/                                 (reserved — not populated in P0/P1)
├── _watermarks/<table>/id_enterprise=4/state.json   (export cursor, §4.3)
└── athena-results/                         (workgroup output, lifecycle-expired 30d)
```

**Bucket policy / hardening (Terraform scaffold):**
- **Block Public Access = ON** (all four flags), SSE-S3 (or SSE-KMS if a CMK is wanted later), bucket-owner-enforced (ACLs disabled).
- **Versioning ON** on the data prefixes so an idempotent partition overwrite (§4.4) is auditable/reversible; **lifecycle** expires `athena-results/` at 30d and old noncurrent versions at 90d.
- **`id_enterprise` first** is deliberate: every offline query is tenant-scoped, so tenant-first partitioning prunes hardest and keeps the one-tenant-per-scan isolation the read plane enforces (ADR-0038 §5.5). `dt` second matches date-ranged reporting.

**File sizing:** coalesce each `(tenant, dt)` write to **128–512 MB** parquet (target one `part-000` per partition per day; split only if a tenant-day exceeds ~512 MB). Avoids the Trino small-files anti-pattern (per-object planning overhead dominates for KB files).

---

## 2. Parquet / Glue schema mapping (Postgres → Athena Hive types)

Types read from `db/init/00-schema.sql`. Partition columns (`id_enterprise`, `dt`) are **not** stored in the parquet payload — they live in the path and are declared as projected partitions.

### 2.1 `bronze.equipment_values_raw`

| Postgres column | PG type | Parquet/Athena type | Note |
|---|---|---|---|
| `ts_value` | timestamptz | `timestamp` | write UTC; Athena `timestamp` is tz-naive → normalize to UTC on export |
| `id_site`, `id_area` | integer | `int` | |
| `id_equipment` | integer | `int` | not-null |
| `net_production_incr`, `gross_production_incr`, `scrap_incr`, `*_val`, `process_scrap_*` | double precision | `double` | |
| `speed`, `conversion_factor` | real | `float` | keep 32-bit (matches prod) |
| `state`, `mode`, `number_cavities`, `id_team`, `ideal_production_speed`, `id_shift`, `id_equipment_line_connected`, `id_shift_hour`, `id_equipment_line_infeed/outfeed` | integer | `int` | |
| `sub_mode`, `id_order`, `box_code`, `transaction_code` | varchar | `string` | |
| `tp_equipment`, `signal_quality`, `position_in_equipment_line`, `is_equipment_line_infeed/outfeed` | smallint | `smallint` | |
| `id_production_order`, `check_number` | bigint | `bigint` | |
| `faults`, `analogs` | jsonb | `string` | serialize JSON as text; query with `json_extract`/`json_parse` in Athena |
| `ts_value_production` | date | `date` | |
| `ingested_at` | timestamptz | `timestamp` | B1 lineage col |
| `source_seq` | bigint | `bigint` | B1 lineage col; part of Bronze PK |
| **`id_enterprise`** | integer | *(partition)* `int` | path only |
| **`dt`** | — | *(partition)* `date` | derived `date(ts_value AT TIME ZONE 'UTC')` |

### 2.2 `bronze.equipment_events_raw`

| Postgres column | PG type | Parquet/Athena type | Note |
|---|---|---|---|
| `ts_event`, `ts_end`, `last_update` | timestamptz | `timestamp` | UTC |
| `id_equipment`, `status`, `fault`, `duration`, `cd_category_client`, `cd_subcategory_client` | integer | `int` | |
| `txt_downtime_notes`, `idle`, `cd_machine`, `cd_category`, `cd_subcategory`, `desc_category`, `desc_subcategory` | varchar | `string` | |
| `idle_processed`, `forced_creation_system`, `fault_processed`, `change_over`, `planned_downtime`, `ignore_cost` | boolean | `boolean` | |
| `ingested_at` | timestamptz | `timestamp` | B1 lineage |
| `source_seq` | bigint | `bigint` | B1 lineage; part of Bronze PK |
| **`id_enterprise`**, **`dt`** | | *(partitions)* | `dt = date(ts_event)` |

> `id_equipment_event` (BIGSERIAL PK) is **dropped** in the `_raw` table (see B1 migration) — the Bronze PK is `(id_equipment, ts_event, source_seq)`, so it is the natural sort/dedupe key in the lake too.

### 2.3 Gold (`equipment_runtime_shift` / `_1hour` / `_1day`)
Exported as-is from the rollup tables (all numeric/timestamp columns → the mapping above). Gold is the **reporting** source (what `cq-logs`/`reports` actually consume); Bronze is the **raw replay/ML** source. Both are partitioned identically.

---

## 3. Glue catalog — partition projection, no crawler

Full DDL: [`../migrations/0041-glue-catalog-ddl.sql`](../migrations/0041-glue-catalog-ddl.sql). The load-bearing choice is **partition projection**: Glue computes the partition set from the query predicate at plan time from table properties, so there is **no crawler** (no DPU-hours, no partition-staleness window, $0 catalog upkeep). We own the export schema, so crawler-style schema-drift discovery buys us nothing.

Projection properties per table:
```
'projection.enabled'            = 'true'
'projection.id_enterprise.type' = 'integer'
'projection.id_enterprise.range'= '1,100000'          -- tenant id space; widen as pool grows
'projection.dt.type'            = 'date'
'projection.dt.range'           = '2024-01-01,NOW'
'projection.dt.format'          = 'yyyy-MM-dd'
'projection.dt.interval'        = '1'
'projection.dt.interval.unit'   = 'DAYS'
'storage.location.template'     = 's3://packiot-lake-${env}/bronze/equipment_values_raw/id_enterprise=${id_enterprise}/dt=${dt}/'
```
A query with `WHERE id_enterprise = 4 AND dt BETWEEN date '2026-07-01' AND date '2026-07-20'` then plans **20 partitions**, not a full-table scan — the cost-control mechanism (§5).

---

## 4. The batch export job

### 4.1 Runtime shape
- **Trigger:** EventBridge Scheduler (cron, e.g. daily 02:00 UTC) → **a small ECS Fargate task** (preferred over Lambda: the 15-min Lambda ceiling and 10 GB `/tmp` are tight for multi-tenant-day parquet coalescing; Fargate has no wall-clock ceiling and streams to S3). Lambda is fine for the low-volume Gold export; Bronze wants Fargate.
- **Language:** Python (`psycopg2` read + `pyarrow` parquet write + `boto3` S3 put) or Go (`pgx` + `parquet-go`) — Python is faster to ship and matches the `cq-logs` toolchain; the job is I/O-bound so language choice is not perf-critical.
- **Read posture:** `BEGIN READ ONLY;` — fits the standing **prod-DB-is-SELECT-only** rule (memory: `feedback_prod_db_readonly`). A read-export never needs write access; run it as the `awslambda`/read-only role.

### 4.2 Per-(tenant, day) algorithm
```
for tenant in active_tenants():                      # from the tenant pool, NEVER hardcoded (feedback_no_hardcoded_enterprise_ids)
    wm = load_watermark(table, tenant)               # s3://…/_watermarks/<table>/id_enterprise=<t>/state.json
    for dt in closed_days_since(wm.high_water):       # only fully-closed days (dt < today UTC) + any dt flagged re-export
        rows = read_only_select(table, tenant, dt)    # SELECT … WHERE id_enterprise=%s AND ts::date=%s
        if rows.empty and not force: continue
        parquet = to_parquet(rows, schema[table], compression='snappy', coalesce='128-512MB')
        put_atomic(s3_path(table, tenant, dt), parquet)   # write to .tmp then copy → overwrite whole partition
    save_watermark(table, tenant, new_high_water)
```

### 4.3 Watermark (idempotency cursor)
Drive off the Gold lineage columns **`source_watermark` / `computed_at`** (ADR-0036 §5A) so the export knows exactly which window is *final*. Persist per `(table, tenant)` as `_watermarks/<table>/id_enterprise=<t>/state.json`:
```json
{ "table": "equipment_values_raw", "id_enterprise": 4,
  "high_water_dt": "2026-07-20", "high_water_source_seq": 918342001,
  "exported_at": "2026-07-21T02:03:11Z", "run_id": "…" }
```
Only **closed** days (`dt < today` UTC) are exported; the current UTC day is always re-exported next run (its rows are still arriving).

### 4.4 Late-arriving data & idempotency
Bronze is append-only (B1: `INSERT`, no `ON CONFLICT`), so a late sample lands with a *later* `ingested_at`/`source_seq` under its true `ts_value` day. The export handles this by **re-exporting the whole affected `dt` partition** (idempotent overwrite of exactly that partition — the medallion replay principle, ADR-0036 §3.3, applied to the lake). Partition-scoped overwrite + S3 versioning = safe, auditable, reversible. Never append-into a partition (that reintroduces the small-files problem and dup rows).

### 4.5 Why gated to closed windows
Exporting an open day would produce a partition that changes under Athena readers and would need constant re-export. Closed-day-only makes each partition **write-once-then-stable** (barring rare late arrivals), which is exactly the property columnar analytics wants.

---

## 5. Athena workgroup & cost control

A dedicated **workgroup per env** (`packiot-lake-staging`) with three guardrails:
1. **Per-query bytes-scanned cap** (`BytesScannedCutoffPerQuery`, e.g. 20 GB) — a hard stop against a runaway `SELECT *` full-scan bill. This is the single most important cost guardrail: Athena bills per TB *scanned*, so an unpartitioned scan is the failure mode.
2. **Results location** pinned to `s3://…/athena-results/` with **enforced workgroup config** (users can't override to an unmanaged bucket) + 30-day lifecycle expiry.
3. **CUR / CloudWatch cost attribution by workgroup**, and `EnforceWorkGroupConfiguration = true`.

Estimated bill (ADR-0041 §6): **< $5/mo realistic**, **$5–15/mo ceiling** — S3 (~$0.023/GB-mo, 10s of GB), Athena ($5/TB scanned, kept < 1 TB/mo by parquet + partition pruning), Glue projection ($0, no crawler). The exit's value is *seam elimination* (one IAM/bill/credential surface), not dollars.

---

## 6. Parity harness (the gold export is the thing that must be trusted)

`cq-logs` greenfield has no legacy to compare (BQ never shipped), so the parity effort is entirely **new-gold-export ↔ Timescale**. Reuse the F2/F3 comparator discipline (byte-exact where integer, tolerance-banded where float):

```sql
-- Timescale side (source of truth), per tenant-day:
SELECT id_enterprise, ts_value::date AS dt, count(*) n, sum(gross_production_incr) g
FROM equipment_values_raw WHERE id_enterprise=$t GROUP BY 1,2;

-- Athena side (the lake):
SELECT id_enterprise, dt, count(*) n, sum(gross_production_incr) g
FROM bronze.equipment_values_raw WHERE id_enterprise=$t GROUP BY 1,2;
```
- **Row-count: zero drift** required per `(tenant, dt)`.
- **`sum(metric)`: small tolerance band** for the double round-trip (parquet double is IEEE-754, same as PG `double precision`, so drift should be ~0; band covers ordering/rounding).
- **Checksum spot-check**: ordered hash of key columns on a sample of partitions.
- **Gate teardown on a clean bake over ≥ one full reporting cycle** (month boundary — reporting is monthly-grained).

---

## 7. `cq-logs` repoint — greenfield `pyathena` build (not a port)

Because the BQ path never shipped (ADR-0041 §2.2), this is a **build**, not a rewrite. The current `test.py` handler already imports `boto3` and talks Postgres via `psycopg2`; the AWS-native shape is *closer* to what exists than BigQuery ever was. Cross-repo (lives in `cq-logs-bigquery`, a sibling repo) — documented here, executed in that repo's own PR under P3.

Reference handler shape (replaces the vendored `google-cloud-bigquery` layer with a `pyathena` layer):
```python
# cq-logs-bigquery/handler_athena.py  (P3 — lands in the cq-logs repo, not here)
from pyathena import connect
import os

def lambda_handler(event, context):
    conn = connect(
        s3_staging_dir=os.environ["ATHENA_RESULTS_S3"],      # s3://packiot-lake-<env>/athena-results/
        work_group=os.environ["ATHENA_WORKGROUP"],           # packiot-lake-<env>
        region_name=os.environ.get("AWS_REGION", "us-east-1"),
    )
    tenant = int(event["id_enterprise"])                     # tenant-scoped, from the pool — never hardcoded
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM gold.cq_logs "
            "WHERE id_enterprise = %(t)s AND dt BETWEEN %(a)s AND %(b)s",
            {"t": tenant, "a": event["from"], "b": event["to"]},
        )
        rows = cur.fetchall()
    return {"statusCode": 200, "items": rows}
```
**BQ→Trino dialect deltas** for any *future* SQL: see ADR-0041 §4.3 (backticks→double-quotes, `_PARTITIONTIME`→explicit `dt`, `SAFE_CAST`→`try_cast`, `APPROX_COUNT_DISTINCT`→`approx_distinct`, `UNNEST`→`CROSS JOIN UNNEST`, `STRUCT`→`ROW`, etc.). Today there is **zero** BQ SQL to port.

---

## 8. Phased build plan (P0 → P3)

| Phase | Name | Deliverables (this repo unless noted) | Prod/GCP touch | Exit criteria |
|---|---|---|---|---|
| **P0** | **Scaffold** | `terraform/modules/lakehouse/` (S3 + Glue DB + Athena workgroup, **unrooted**); `0041-glue-catalog-ddl.sql`; this design doc; ADR §10. **No apply.** | **No** | Doc + scaffold merged; module `terraform validate`s standalone; DDL reviewed. |
| **P1** | **Export** | Wire the module into `terraform/staging` (S3 + Glue + workgroup **applied to staging only**); build the read-only, watermark-driven Bronze+Gold export job (EventBridge→Fargate); first partitions land in `s3://packiot-lake-staging/`. | **No** (new AWS infra only; nothing depends on it) | Job runs green for a tenant-day; parquet visible in S3; watermark advances idempotently; re-run overwrites cleanly. |
| **P2** | **Athena** | Run the Glue DDL; validate partition projection; run the **parity harness** (§6) Timescale↔Athena; wire cost guardrails (bytes-scanned cap, results lifecycle). | **No** | Zero row-count drift + in-band sum over a bake cycle; bytes-scanned cap enforced; sample checksums match. |
| **P3** | **Repoint `cq-logs`** | *(sibling repo `cq-logs-bigquery`, its own PR)* swap vendored BQ layer → `pyathena`/`boto3` handler (§7); land `cq_logs` dataset as parquet in the lake; ship. Then the ADR-0041 §5.2 teardown checklist becomes **USER-gated** actionable. | **No** for the build; teardown steps **USER-gated** | `cq-logs` reads the lake green; then hand off the §5.2 teardown (rotate leaked pw, revoke SA key post-0034, close GCP project — all USER-gated). |

**Sequencing rule (from ADR-0041 §9):** the BigQuery leg (P0–P3) is *independent and cheap* — ship it now, staging, autonomous-eligible (no GCP touched). The GCP project-**close** waits on the Firebase→Cognito leg (ADR-0034) and is USER-gated. Do not couple them; do not fire an irreversible teardown step before its consumer is confirmed dead.

---

## 9. Open questions / decisions to confirm at P1

1. **Export engine language** — Python (ship-fast, matches cq-logs) vs Go (matches the worker fleet). Recommendation: Python for P1, revisit if volume demands.
2. **Silver in the lake?** — P0/P1 export Bronze + Gold only. A `silver/` prefix is reserved; populate only if an offline transform needs an intermediate (ML feature tables). Don't build ahead of a consumer.
3. **KMS vs SSE-S3** — SSE-S3 default for P1 (no CMK ops); switch to SSE-KMS if a compliance requirement appears.
4. **Redshift Spectrum** — deferred (ADR-0041 §3.3); layer over the *same* S3 only if a warehouse-shaped BI workload emerges.
5. **Prod BigQuery consumer** — teardown step 1 (ADR-0041 §5.2) must confirm no prod BQ consumer via the GCP billing/query-history console before any dataset deletion. USER-gated.
