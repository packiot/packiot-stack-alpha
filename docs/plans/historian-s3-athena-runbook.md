# Raw-History Historian — S3 + Parquet + Athena Runbook

**Status:** PILOT PROVEN end-to-end (2026-08-11). Codified in IaC. Full-scale fill
is a gated follow-up (throttled batch job).
**Scope:** the "raw `equipment_values` → cheap cold store" half of the approved
hybrid (see `docs/plans/legacy-history-migration-costing.md` §7). AWS-native,
**deliberately OFF GCP** (no BigQuery, no `cq-logs` pipeline).

---

## 0. TL;DR

- **What:** unload legacy `equipment_values` (PG12/TimescaleDB, `packiot40`,
  SELECT-only) → ZSTD Parquet on S3, queried by Athena partition projection.
  Superset/BI (`bi.prod`) reads it for historical dashboards.
- **Cost (measured-based):** all-tenant ≈ **$1–2/mo** (S3 ~$0.50 storage + tiny
  Athena scan). CPACK-only ≈ **$0.05–0.30/mo**. **Glue = $0** (catalog storage
  only — NO crawler, NO ETL/Spark job).
- **Proven:** CPACK (ent 1) `2026-08-10` unloaded → Athena `count(*)` =
  **161,819 == legacy** for the same day (scanned **272 KB**); top-3-equipment
  spot-check matched legacy exactly. July-2026 full month (~5.5 M rows) unloaded
  as the scale-up proof.
- **Remaining:** run the throttled full backfill (all CPACK, then all tenants);
  `terraform import` the pilot resources into state (§9); bring up Superset +
  add `PyAthena` to its image (§7).

---

## 1. Architecture / data flow

```
legacy packiot40 (PG12 + TimescaleDB, SELECT-only awslambda role, us-east-2)
  │  DuckDB postgres_query()  ── Timescale-aware, streaming, one day per query
  │  (scripts/historian-unload.sh — cheap/existing compute, ≈$0)
  ▼
ZSTD Parquet, one object per (tenant, day)
  s3://packiot-production-historian-<acct>/equipment_values/
        enterprise=<id>/year=<Y>/month=<M>/data-<YYYY-MM-DD>.parquet
  ▼
Glue Data Catalog  (table definition only — NO crawler)
   database packiot_historian . table equipment_values
   partition projection: enterprise / year / month  (resolved at query time)
  ▼
Athena workgroup packiot_historian  ($5/TB scanned, pruned to MBs by Parquet)
  ▼
Superset / BI (bi.prod)  — historical dashboards (PyAthena, instance-role auth)
```

**Why this shape** (vs the alternatives priced in the costing doc): lowest $ and
lowest ops of the viable homes, and no GCP. The whole design avoids the two Glue
money-pits on purpose — see §6.

---

## 2. Codified artifacts (what's in the repo)

| Artifact | Path | Role |
|---|---|---|
| Terraform | `terraform/production/historian.tf` | S3 bucket (+PAB/SSE/lifecycle), Glue DB, Glue table (partition projection), Athena workgroup, IAM (unload-writer on app role; Superset-reader on superset role) |
| Unload job | `scripts/historian-unload.sh` | repeatable, throttled, idempotent PG→Parquet→S3 unload (DuckDB) |
| Superset conn | `configs/superset/assets/databases/packiot_historian.yaml` | importable Athena connection (instance-role auth) |
| This runbook | `docs/plans/historian-s3-athena-runbook.md` | commands, fill plan, cost |

---

## 3. The unload mechanism (why DuckDB `postgres_query`, not the scanner)

We attach the legacy PG in DuckDB **read-only** and stream via
`postgres_query('legacy', 'SELECT ...')`.

**Critical gotcha (do not "simplify"):** the obvious
`SELECT * FROM legacy.equipment_values WHERE ...` uses DuckDB's `postgres_scanner`
ctid-range **parallel** path, which scans the hypertable **parent** (empty — all
rows live in `_timescaledb_internal` chunks) and **hangs**. `postgres_query()`
hands the literal SQL to Postgres, whose own planner (with the TimescaleDB
chunk-exclusion hook) runs the scan and streams a single result set. This is the
difference between "hangs for minutes" and "10 s/day".

**Safety:** legacy role `awslambda` has no write grant (SELECT-only forever); the
attach is `READ_ONLY`; each query is bounded to one calendar day. We never write
to legacy and never touch the production operational DB.

### Run it

```sh
# one day (the pilot proof)
scripts/historian-unload.sh 1 2026-08-10 2026-08-11 0

# a month (representative scale-up), 1 s throttle between days
scripts/historian-unload.sh 1 2026-07-01 2026-08-01 1

# args: <id_enterprise> <start YYYY-MM-DD> <end-exclusive> [sleep_secs]
# env:  HISTORIAN_BUCKET, AWS_REGION, DUCKDB override the defaults
```

Idempotent: each day is one deterministic key; re-running a day overwrites just
that object. Safe to resume after interruption (re-run the remaining window).

---

## 4. S3 layout + partitioning

```
s3://packiot-production-historian-<acct>/
  equipment_values/
    enterprise=1/year=2026/month=7/data-2026-07-01.parquet
    enterprise=1/year=2026/month=7/data-2026-07-02.parquet
    ...
  athena-results/            # Athena query spill (lifecycle-expired at 30 d)
```

- **Partition keys:** `enterprise`, `year`, `month` — **path-encoded**, not stored
  in the files (recovered from the path). Month is **un-padded** (`month=7`) to
  match Athena integer projection.
- **Why not partition by `id_equipment`:** it would explode into 62 × months tiny
  files (bad Parquet economics). `id_equipment` stays a **column** — Parquet
  min/max stats + predicate pushdown prune it inside a file for free.
- **Grain:** one file per (tenant, day) ≈ 1–2 MB ZSTD. Good row-group size
  (122 880) → healthy Athena parallelism without small-file overhead.
- **Lifecycle:** `equipment_values/` → Standard-IA at 1 yr → Glacier **Instant
  Retrieval** at 2 yr (GIR still serves Athena at ms latency; we do NOT use Deep
  Archive — it would break interactive query). `athena-results/` expires at 30 d.

---

## 5. Athena table (partition projection — no crawler)

The table is codified as `aws_glue_catalog_table.equipment_values`. Equivalent DDL
(for reference / manual recreate):

```sql
CREATE EXTERNAL TABLE packiot_historian.equipment_values (
  ts_value timestamp, id_enterprise int, id_site int, id_area int,
  id_equipment int, net_production_incr double, ... , check_number bigint
)
PARTITIONED BY (enterprise int, year int, month int)
STORED AS PARQUET
LOCATION 's3://packiot-production-historian-<acct>/equipment_values/'
TBLPROPERTIES (
  'projection.enabled'='true',
  'projection.enterprise.type'='integer','projection.enterprise.range'='1,100',
  'projection.year.type'='integer','projection.year.range'='2019,2027',
  'projection.month.type'='integer','projection.month.range'='1,12',
  'storage.location.template'=
    's3://.../equipment_values/enterprise=${enterprise}/year=${year}/month=${month}/'
);
```

Partitions resolve **at query time** from the projection ranges — no crawler, no
`MSCK REPAIR`, no `ALTER TABLE ADD PARTITION`. A new tenant/month is queryable the
instant its Parquet lands. **Always filter on `enterprise`/`year`/`month`** so
Athena prunes to the right prefixes (the pilot count scanned 272 KB, not GBs).

### Proof query

```sql
SELECT count(*) FROM packiot_historian.equipment_values
WHERE enterprise=1 AND year=2026 AND month=7;   -- == legacy SELECT for July
```

---

## 6. Cost — explicit, Glue = $0

Measured pilot economics: **161,819 rows/day → 1.16 MB Parquet** (~7 bytes/row;
~40× vs uncompressed). A day-count query **scanned 272 KB**.

| Component | CPACK-only | All-tenant | Notes |
|---|---:|---:|---|
| **S3 storage** | ~$0.05/mo (2–3 GB) | ~$0.35–0.60/mo (15–25 GB) | Parquet ZSTD; drops further as lifecycle tiers old partitions to IA/GIR |
| **Athena query** | < $0.30/mo | < $1/mo realistic | $5/TB scanned; a pruned BI query scans single-digit MB → < $0.0001; a full tenant-year ≈ 380 MB ≈ $0.0019 |
| **Glue crawler** | **$0** | **$0** | **NOT USED** — partition projection instead |
| **Glue ETL/Spark** | **$0** | **$0** | **NOT USED** — DuckDB unload on existing compute |
| **Glue Data Catalog** | ~$0 | ~$0 | table-definition storage only (free < 1M objects) |
| **Unload compute** | ~$0 | ~$0 | DuckDB on the app box / a laptop / a spot Fargate task |
| **Total** | **~$0.05–0.30/mo** | **~$1–2/mo** | |

The two Glue money-pits — **crawlers** (2-DPU per-run minimum) and **ETL/Spark
jobs** ($0.44/DPU-hr × DPUs × hours) — are **deliberately avoided**. Confirmed:
this design uses **neither**.

> These all-tenant sizes come in **below** the costing doc's 25–60 GB estimate
> because measured Parquet ZSTD on this sparse telemetry is ~7 bytes/row. CPACK is
> sparser than average (many NULL quality/jsonb columns), so budget ~7–12 bytes/row
> across tenants → the 15–25 GB range above.

---

## 7. Superset / BI wiring

- **Connection:** `configs/superset/assets/databases/packiot_historian.yaml` — a
  Superset database-export YAML with the Athena SQLAlchemy URI:
  ```
  awsathena+rest://@athena.us-east-1.amazonaws.com:443/packiot_historian
    ?s3_staging_dir=s3://packiot-production-historian-<acct>/athena-results/
    &work_group=packiot_historian
  ```
  **No static keys** — empty `user:pass`; PyAthena authenticates via the Superset
  EC2 instance role (`packiot-production-superset-historian-reader`, historian.tf).
- **Image dep (follow-up on the superset branch):** add `PyAthena[sqlalchemy]` to
  `docker/superset` requirements. It is not on this branch — same cross-branch
  posture as `superset.tf`'s other gated follow-ups.
- **Import** (once Superset is up): include this YAML in the assets bundle and
  import (`README` in `configs/superset/assets`); no password prompt needed (IAM
  auth). Then build datasets/charts over `packiot_historian.equipment_values` for
  historical dashboards.

---

## 8. Full-scale fill plan

Throughput (measured, day-by-day, throttled): ~**15 k rows/s** effective
(network + PG scan bound; ~10–12 s per CPACK day including a fresh-DuckDB startup
per day and a 1 s inter-day sleep).

| Fill | Rows | Parquet | Wall-clock (day-grain, throttled) |
|---|---:|---:|---|
| **CPACK all history** (~6 yr) | ~330 M | ~2–3 GB | ~6–7 h (resumable; run overnight) |
| **All-tenant all history** | ~2.19 B | ~15–25 GB | ~40 h single-stream — **parallelize per tenant** to compress wall-clock |

**Bulk-backfill tuning** (for the historical one-shot, not the live-safe default):
- Unload **per-month** (or per-week) instead of per-day to amortize the
  per-invocation DuckDB startup + attach (~3–4 s each). One `postgres_query` for a
  month streams fine; watch DuckDB memory (it spills to disk).
- **Parallelize across tenants** (one process per `id_enterprise`) — they hit
  disjoint chunks; keep an eye on the live client DB's load and back off if needed.
- Keep the **1 s+ inter-batch sleep** and the server `statement_timeout` — this is
  a live client DB; never saturate it.
- **Incremental top-up** after the historical backfill: a daily job unloading
  `yesterday` per active tenant keeps the cold store current (cron/EventBridge →
  the same script). Cheap and idempotent.

**id/topic remap NOT needed here.** The raw historian keeps **legacy ids/topics
as-is** (ent-1, `C-PACK/…`). The ent-1→ent-3 + `C-PACK/`→`CPACK/` remap is only
required if/when joining to F3 — do it in the query/view layer at that point, not
in the cold store.

---

## 9. Codify / import (no click-ops drift)

The pilot resources were created via CLI to prove the path fast. `historian.tf` is
the matching IaC. Reconcile state so nothing is orphaned:

```sh
TF="terraform -chdir=terraform/production"
$TF import aws_s3_bucket.historian                                 packiot-production-historian-639178078294
$TF import aws_s3_bucket_public_access_block.historian             packiot-production-historian-639178078294
$TF import aws_s3_bucket_server_side_encryption_configuration.historian packiot-production-historian-639178078294
$TF import aws_s3_bucket_versioning.historian                      packiot-production-historian-639178078294
$TF import aws_s3_bucket_lifecycle_configuration.historian         packiot-production-historian-639178078294
$TF import aws_glue_catalog_database.historian                     639178078294:packiot_historian
$TF import aws_glue_catalog_table.equipment_values                 639178078294:packiot_historian:equipment_values
$TF import aws_athena_workgroup.historian                          packiot_historian
# Then `terraform plan` — the only CREATEs left should be the IAM policies +
# attachments (they were never created via CLI). `terraform apply` creates them.
# The superset-reader attachment applies when the Superset box is applied
# (superset.tf); the app historian-writer attachment applies immediately.
```

> Alternatively, since everything is additive, a fresh account/environment just
> runs `terraform apply` and the CLI step is skipped entirely — the CLI path here
> was only to prove the pilot before the IaC landed.

---

## 10. Proven vs remaining

**Proven (2026-08-11):**
- DuckDB `postgres_query` unload is Timescale-safe and streams (~10 s/CPACK-day).
- Parquet is byte-faithful: Athena `count(*)` = **161,819 == legacy** (2026-08-10);
  spot-check matched; July-2026 full month unloaded.
- Athena partition projection prunes correctly (272 KB scanned for a day-count).
- All infra live: bucket + lifecycle + Glue DB + Glue projection table + Athena
  workgroup. Terraform `validate` passes.

**Remaining (gated):**
- Full backfill (all CPACK, then all tenants) — §8.
- `terraform import` the 8 pilot resources; `apply` the IAM — §9.
- Superset bring-up + `PyAthena` in the image; import the connection YAML — §7.
- Optional: daily incremental top-up job (EventBridge → the script).
