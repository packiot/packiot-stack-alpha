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
- ~~`terraform import` the 8 pilot resources; `apply` the IAM~~ — **DONE 2026-08-11** (§9; imports verified no-change, IAM applied 0-destroy).
- ~~`PyAthena` in the image; import the connection YAML~~ — **DONE 2026-08-11** (§7; `PyAthena[SQLAlchemy]==3.35.4` in `docker/superset/Dockerfile`, connection `packiot_historian` live on bi.prod, instance-role auth, test query green).
- **Tenant scoping for historian dashboards — see §11 (MUST read before any embed/guest-token exposure).**
- Optional: daily incremental top-up job (EventBridge → the script).

---

## 11. ⚠️ Tenant isolation for historian dashboards (READ BEFORE EMBEDDING)

The historian is **not** covered by the tenant-isolation machinery that protects
the operational `packiot_analytics` (bi.*) connection. Two independent reasons:

1. **Different engine — the Postgres-GUC RLS co-enforcer does not reach Athena.**
   `packiot_analytics` isolates via a Postgres `app.tenant_id` GUC + `NOBYPASSRLS`
   roles behind `SECURITY DEFINER` bi.* views (`db/superset/02-tenant-rls.sql`).
   The historian is **Athena over S3 Parquet** — there is no Postgres connection,
   no GUC, no row-level policy. None of that fail-closed enforcement applies here.

2. **Legacy id space.** The cold store deliberately preserves **legacy ids/topics**
   (§8): CPACK is `enterprise=1` here, not its F3 tenant id (ent-3). A guest token
   minted with an F3 tenant claim does **not** line up with the historian's
   `enterprise` partition column without an explicit legacy→tenant map.

**Consequence:** a chart/dataset built directly on `packiot_historian.equipment_values`
and dropped into the front4 embed (guest-token / `GUEST_ROLE_NAME=Public`) path
would serve **cross-tenant raw history** — no filter runs by default. Do **not**
wire the historian into the tenant embed without one of the following first:

- **Superset native RLS** (Settings → Row Level Security) on every historian
  dataset, keyed on the `enterprise` column, with a **legacy-id→tenant** clause
  bound to the guest token's tenant claim (the token carries the F3 id; the rule
  must translate). This is the Athena-appropriate substitute for the Postgres-GUC
  path — it must be authored and tested per dataset (extend `tests/superset/` with
  a 2-tenant historian isolation case before exposing any nav item), OR
- keep historian dashboards **internal-only** (authenticated Admin/analyst roles,
  not the `Public` guest role), never reachable through a guest token, OR
- publish **per-tenant curated Athena views/workgroups** so a given embed can only
  ever resolve one tenant's partitions.

Until one of those is in place, the historian connection is **SQL-Lab / internal
analyst use only** — it is exposed in SQL Lab (`expose_in_sqllab=true`) but is
**not** attached to any embedded dashboard. Flagged deliberately, not silently
wired.

---

## 12. Ongoing incremental append + F3 hot/cold tiering (retention)

This is the piece that makes the historian a **TIER** rather than a copy: F3 keeps
raw `equipment_values` HOT for **90 days**; the historian holds the full raw
archive FOREVER. F3 raw older than 90 days is dropped — **but only ever after the
historian already holds it.**

### 12.1 The append (F3 → S3, daily)

- **Script:** `scripts/historian-append.sh` — DuckDB `postgres_query` streams the
  trailing window (yesterday − `HISTORIAN_OVERLAP_DAYS`, default 2) of new-prod F3
  `equipment_values` (DB `packiot`, host `POSTGRES_HOST_UPSTREAM`) and writes the
  same 56-col Glue-shaped Parquet into the SAME partition layout as the backfill
  (`enterprise=<id>/year=/month=/data-<day>.parquet`) plus a `_watermark/…` marker.
  Idempotent (each day = one deterministic key, overwritten in place).
- **Gate:** hard no-op unless `HISTORIAN_APPEND_ENABLED=true`. Enabled now that the
  ADR-0045 **P1 first-boot decode fix is LIVE on prod (PR #788)** so it archives
  clean data. `HISTORIAN_SPIKE_GUARD` is a belt-and-suspenders backstop only.
- **Schedule:** `historian-append.service` + `historian-append.timer` (installed by
  `terraform/production/user_data/app_init.sh`, daily **02:30 UTC**, enabled). The
  `.env` self-heal in app_init appends the `HISTORIAN_*` keys on redeploy even on an
  existing box, so activation is a redeploy — no hand-editing.
- **Local proof:** `scripts/historian-append-verify.sh` stands up a throwaway
  TimescaleDB, runs the REAL script, and reconciles Athena-equivalent count ==
  source, proves idempotency + the spike backstop. ✅ passing.

**First-run reconcile (the "a day archived, reconciles" check):** after the timer's
first run (or a manual `HISTORIAN_APPEND_ENABLED=true bash scripts/historian-append.sh 3 <day> <next>`),
confirm the day landed and matches F3:
```sh
# S3 object + watermark present:
aws s3 ls s3://packiot-production-historian-639178078294/equipment_values/enterprise=3/ --recursive | tail
aws s3 cp s3://packiot-production-historian-639178078294/_watermark/enterprise=3/last-append.json -
# Athena count for the day == F3 count for the same day (should be equal).
```

### 12.2 The F3 tiering policies (compression + retention)

Migration `docs/adr/reference/migrations/0045-f3-hot-cold-tiering-90d.sql`, codified
into fresh-DB init at `db/init-f3/snapshot/05-f3-cagg-agg.sql`. On
`equipment_values` **ONLY**:

| Policy | Value | Was | Why |
|---|---|---|---|
| Compression | compress chunks > **7 days** | 14 days (0036-b0) | columnstore (~33x) shrinks the cold part of the hot window |
| Retention | drop chunks > **90 days** | 2 years (0036-b0) | historian is now the forever tier; F3 only needs the operational window |

**Scope guardrail:** retention @ 90d is on `equipment_values` and nothing else.
`equipment_events` (2y), `equipment_events_raw`/`equipment_values_raw` (2y, the
ADR-0045 capture layer — NOT archived by the historian), and `lab_equipment_values`
(1y) keep their long horizons; the `agg_*`/`ca_*` caggs and `equipment_runtime_*`
are downsampled OEE tiers, never retention-dropped.

### 12.3 ⚠️ Safety + mandatory sequencing (non-negotiable)

**F3 must never drop raw the historian does not already hold.** Two invariants,
both proven:

1. **Historian covers past the drop horizon.** Backfill complete (CPACK 2021→2026-08)
   **AND** the daily append live + caught up (covers ~yesterday). Since 90d ≫ the
   ~1-day append lag, there is ~89 days of margin. A newly-onboarded tenant whose
   oldest F3 chunk is < 90d old drops **zero** rows on install (verified live on
   staging: 0 chunks > 90d; the retention job ran and dropped nothing, rowcount
   unchanged at 2,150,331). Its first real drop lands months later, long after the
   append is proven.
2. **Caggs materialize before the raw is dropped.** Every cagg over `equipment_values`
   refreshes with a small finite `start_offset` (2h–3d live) — materialized ~87
   days before the raw beneath it is dropped; materialized cagg data is **not**
   cascade-deleted when source chunks drop. So dropping raw > 90d preserves all
   OEE history. `scripts/f3-tiering-verify.sh` proves this deterministically
   (synthesises > 90d chunks, materializes the cagg, drops raw, asserts raw gone +
   cagg survives + hot raw untouched) and includes a counter-proof that an
   **un**-materialized region is lost — i.e. the ordering is load-bearing. ✅ passing.

**SEQUENCING (do not reorder):**
```
1. P1 decode fix live on prod ........................ DONE (PR #788)
2. Historian backfill complete for the tenant ........ DONE (CPACK)
3. Enable + run the daily append; confirm caught up .. codified enabled; PROD-GATED (redeploy)
4. THEN enable F3 retention @ 90d .................... STAGING done (inert); PROD-GATED
```
Never enable step 4 on a tenant/env without steps 2–3 proven for it.

### 12.4 Status (staging vs prod-gated)

- **Staging (`packiot_shadow`):** tiering LIVE — compress@7d (job 1031) + retention@90d
  (job 1032); inert (0 chunks > 90d); retention job executed clean, no loss; caggs
  intact. Note staging has no historian (test data) — acceptable; prod is the
  historian-backed env.
- **Prod (`packiot`):** GATED. Append not yet deployed on the box (no ent=3 in S3
  yet, no watermark). Promote = redeploy prod app box (installs+enables the timer +
  self-heals `.env`), let the append run + catch up, verify coverage, THEN apply
  migration 0045 to prod F3 under the prod-apply gate.

### 12.5 Cost note (ledger)

Retention @ 90d **shrinks** F3 EBS over time (a saving, not a cost): raw
`equipment_values` stops growing unboundedly and settles at ~90 days on-disk
(the 7–90d portion compressed ~33x). The full history moves to S3 at
~$0.004–0.023/GB-mo (Standard→IA→GIR via the `historian.tf` lifecycle) — far cheaper
per byte than EBS gp3 (~$0.08/GB-mo). Net: EBS/snapshot spend on the prod DB trends
DOWN as old raw is dropped; historian S3 stays a few $/mo even at full scale.
