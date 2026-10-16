# ADR-0063 — Is TimescaleDB still needed in the analytics database?

**Status:** Accepted — in progress (Phase A done; B1/B4 live on staging 2026-10-15; B2 gated; C started) · **Date:** 2026-10-14 (rewritten the same day; §13 added 2026-10-15) · **Scope:** the new stack's
analytics database (`packiot_analytics` on staging; the production target built by the transplant in
[`production-promotion-transplant-runbook.md`](reference/production-promotion-transplant-runbook.md)).
The legacy database, back4 and legacy oeecloud are out of scope (read-only, not touched).
**Builds on:** [ADR-0060](0060-local-development-environment-and-cpack-dev-seed.md) (seed pins PG 15.17 + TS 2.27.0),
the grain-tiered retention plan (`docs/plans/unified-hot-cold-serving-grain-tiered-retention.md`).

Every number below comes from a read-only query against staging on 2026-10-14 (first pass ~20:05
UTC, re-verified ~21:28 UTC) or from a `file:line` in this repo at `origin/staging`. Anything not
proven that way is marked **(unverified)**.

**Revision note.** The first version (#1771) concluded "partially: keep TimescaleDB". That verdict
mixed two questions. **Technical necessity** asks whether the workload needs TimescaleDB. It does
not. **Current coupling** asks whether the code depends on TimescaleDB today. It does, through
continuous aggregates the OEE engine reads. This version answers the two questions separately.

---

## 1. Verdict

**Not necessary. Coupled.**

- **Not necessary.** The workload is about 18 GB and 1.9 M rows/day (≈ 22 rows/s). That is small
  for plain PostgreSQL with declarative partitioning and BRIN indexes (§3). The cold tier
  already runs without TimescaleDB: it is PostgreSQL 16 + `pg_duckdb` + `postgres_fdw` over
  Parquet on S3 (§4).
- **Coupled.** The engine reads two continuous aggregates as **inputs**:
  `equipment_categorical_1min` and `_1hour`, 29.6 % of all DB statement time (§5a). The
  readers would need a replacement before the extension can go. Compression and retention
  management are not real dependencies (§5b, §5c).
- **Target architecture.**
  - **Hot:** plain partitioned PostgreSQL with a short retention window. The engine maintains
    the minute and hour rollups it reads, as it already maintains gold.
  - **Cold:** Parquet + DuckDB, which is the historian that already exists.
- **Production timing.** The production promotion (#1653) was rehearsed with TimescaleDB. When
  to leave it, before or after promotion, is a **scheduling decision for the user**. The
  technical facts do not force either order (§9).

### Decision drivers

| Driver | Finding | Section |
|---|---|---|
| Scale | 1.9 M rows/day ≈ 490 MB/day uncompressed; 14–30 day hot window ≈ 7–15 GB raw | §3 |
| Cold tier | historian = PG 16 + pg_duckdb + postgres_fdw, Parquet on S3; no TimescaleDB | §4 |
| Hot tier engine | many concurrent writers, row updates, transactions, constraints, per-tenant RLS → PostgreSQL required, not DuckDB | §4 |
| Real coupling | engine reads `equipment_categorical_1min/_1hour` (rollup, closer, CPAC deriver, line-lead); historian FDW reads `_1hour` | §5a |
| Compression | 21 GB saved, but **> half is `ca_discrete_changes_1s`, whose only reader produced 0 rows in 7 days** | §5b |
| Retention / partitions | 13 policies over 5 hypertables + caggs; trivially replaced by partition drops | §5c |
| Cost of keeping it | ≈ 16 % of one vCPU in background jobs (12 % was one empty cagg, removed in A1), 9.4 % of DB time in the cagg refresh-window query, the #1770 trap (DML on real-time caggs), 9 incidents/traps | §6 |
| Forcing function | none (prod is self-hosted `timescale/timescaledb:2.25.2-pg16` on EC2, `terraform/production/database.tf:132`) | §9 |

---

## 2. Inventory (live catalog, staging, 2026-10-14)

**Engine:** PostgreSQL 15.17 (aarch64, Alpine) · `timescaledb` 2.27.0, license `timescale` (TSL) ·
other extensions `btree_gist` 1.7, `dblink` 1.2, `pg_stat_statements` 1.10, `plpgsql`. No
`timescaledb_toolkit`. `pg_cron` 1.6 is preloaded and installed in the `packiot` database
(`cron.database_name = packiot`). `pg_partman` and `pg_ivm` are not in the image.
`shared_preload_libraries = timescaledb,pg_cron,pg_stat_statements,auto_explain`. Database size
**18 GB** (19,181,755,751 bytes at 21:28 UTC), of which chunks are 15 GB.

### 2.1 Hypertables (5)

| Hypertable | Chunk | On disk | Rows last 24 h (21:28 UTC) | Compression before → after | Retention |
|---|---|---|---|---|---|
| `silver.equipment_values` | 1 d | 2,443 MB | **645,924** | 6,558 MB → 381 MB (17.2×) | 90 d |
| `bronze.equipment_values_raw` | 7 d | 2,086 MB | **1,224,631** | 2,934 MB → 274 MB (10.7×) | 90 d |
| `silver.equipment_events` | 1 d | 1,063 MB | 4,620 | 536 MB → 236 MB (2.3×) | 5 y |
| `silver.plc_link_minutes` | 7 d | 67 MB | 33,097 | not compressed | 90 d |
| `bronze.equipment_events_raw` | 7 d | 24 kB | 0 | policy, no data | 90 d |

Every unique key already includes the time column, which native partitioning also requires.

### 2.2 Continuous aggregates (7 before Phase A, all real-time)

| Cagg | Bucket | Size | Compressed before → after | Refresh every / window | Avg run | Readers |
|---|---|---|---|---|---|---|
| `equipment_categorical_1min` | 1 min | 4,110 MB | no | 2 min / 3 h | 0.1 s | engine rollup, closer, CPAC deriver, line-lead (§5a) |
| `equipment_categorical_1hour` | 1 h (on `_1min`) | 104 MB | no | 30 min / 1 d | 0.1 s | engine hour/shift/line-lead, 5 serving functions, invariants, **historian FDW** |
| `equipment_metrics_1min` | 1 min | 2,018 MB | no | 1 min / 3 h | 0.1 s | `serving.mission_control`, `_timeline` |
| `agg_equipment_values_1min` | 1 min | 568 MB | 1,325 MB → 75 MB | 1 min / 30 min | 0.2 s | read-api `/v1/query`, SAP reports |
| `agg_equipment_values_1hour` | 1 h | 43 MB | 72 MB → 7.7 MB | 30 min / 3 d | 0.2 s | read-api, `uns.go` month refresh |
| `ca_discrete_changes_1s` | 1 s | 2,738 MB | **11 GB → 384 MB** | 15 min / 30 min | **27.1 s** | `events/deriver.go` only, which produces nothing today (§5b) |
| ~~`ca_equipment_boxes_1s`~~ | 1 s | 56 kB, 0 rows | no | 15 min / 6 h | **108.0 s** | none. **Dropped by A1 (#1774)** |

### 2.3 Background jobs

Job-execution logging was off, so the costs below come from `_timescaledb_internal.bgw_job_stat`
(cumulative). Phase A5 turns logging on.

| Job | What | Avg run | Share of one vCPU (avg ÷ interval) |
|---|---|---|---|
| 1014 | refresh `ca_equipment_boxes_1s` | 108.0 s | **12.0 %** (removed by A1) |
| 1013 | refresh `ca_discrete_changes_1s` | 27.1 s | 3.0 % |
| 1003 / 1057 / 1064 / 1005 / 1068 | refresh the 1-min / 1-hour caggs | 0.1–0.2 s | 0.5 % together |
| compression (7 jobs, 12 h) | | 113 s / 57 s / < 5 s | 0.4 % together |
| retention (13 jobs, daily) | | < 6 s | ≈ 0 |
| 1033 / 1072 / 1100 | user actions (purge, downtime-resolved refresh, invariants) | 0.08 / 0.85 / 65 s | 4.3 %. Not Timescale features; they would move to pg_cron |

**Why a refresh of 0 rows took 108 s (proved in A1).** The refresh policy splits its window into
one-bucket batches: 6 h of 1 s buckets gives 21,540 candidates. It tests each candidate against
every row of the cagg's invalidation log, and that log held **40,109** stale 1-second ranges from
late writes outside the window, which the policy never consumes. Reproduced on 2.27.0: 42 s with
39,703 ranges, 7 ms with none. This one query (`WITH dimension_slices AS …`) is **9.4 % of all DB
statement time** since 09-24. Job 1013 has the same pattern (48,906 ranges).

---

## 3. Scale: plain PostgreSQL is enough

**Ingest** (bounded `count(*)` of the last 24 h, 21:28 UTC): 645,924 silver values + 1,224,631
bronze values + 4,620 events + 33,097 PLC-link minutes = **1.91 M rows/day ≈ 22 rows/s on
average**. Peaks are a small multiple of that. A single PostgreSQL backend inserts tens of
thousands of rows per second, so ingest is three orders of magnitude below the limit.

**Bytes per row, uncompressed, table + indexes**, measured on the newest finished uncompressed chunks:
silver values 340–397 B, bronze values ≈ 196 B (992 MB / 5.05 M rows), events ≈ 375 B, PLC-link
minutes ≈ 157 B, `equipment_categorical_1min` 529 B, `equipment_metrics_1min` 248 B,
`agg_equipment_values_1min` 238 B, `equipment_categorical_1hour` 539 B.

**Sizing:** rows/day × bytes/row × retention window, without compression.

| Table | Rows/day | ≈ MB/day | 14 d | 30 d | 90 d (today's retention) |
|---|---|---|---|---|---|
| `silver.equipment_values` | 646 k | 239 | 3.3 GB | 7.2 GB | 21.5 GB |
| `bronze.equipment_values_raw` | 1.22 M | 245 | 3.4 GB | 7.3 GB | 22.0 GB |
| events + PLC-link minutes | 38 k | 7 | 0.1 GB | 0.2 GB | 0.6 GB |
| minute rollups (categorical + metrics + values), engine-maintained | ≈ 265 k | 90 | 1.3 GB | 2.7 GB | 8.1 GB |
| **total** | **≈ 2.2 M** | **≈ 580** | **≈ 8 GB** | **≈ 17 GB** | **≈ 52 GB** |

Gold, serving and the dimension tables add about 2.5 GB (`gold.equipment_oee_hourly` 577 MB,
`_shift` 385 MB, `serving.downtime_events_resolved` 674 MB, …). The DB volume is 128 GB.

- **With a 14–30 day hot window, the whole hot database is about 10–20 GB uncompressed**, about
  what TimescaleDB occupies today compressed. Daily range partitions (14–30 per table) plus a BRIN
  index on the time column keep scans pruned and indexes small.
- Even without changing retention, 90 days uncompressed (≈ 55 GB) fits the volume. Compression
  is a cost saving, not a capacity requirement.
- Older history belongs in the cold tier (§4). The silver catalog already declares a daily cold
  copy for `equipment_values`, `equipment_events`, `production_orders` and
  `gold.equipment_oee_shift` (`ops.retention_policy.cold_copy`).

**TimescaleDB is not needed for scale.**

---

## 4. Hot vs cold: who needs what

**The historian does not run TimescaleDB.** `hist-gateway` is **PostgreSQL 16 + `pg_duckdb`
(embedded DuckDB) + `postgres_fdw`** (image `pgduckdb/pgduckdb:16-main`, glibc; it cannot even load
into the Alpine/musl TimescaleDB image). It stores no rows itself:

- **cold** = Parquet on S3 (`s3://packiot-staging-historian-<account>/equipment_values/…`,
  `equipment_events/…`, `production_orders/…`, daily rollups) read by DuckDB;
- **hot** = foreign tables onto the analytics DB (`live.equipment_values` →
  `silver.equipment_values`, `live.equipment_events`, `live.production_orders`, and
  `live.equipment_values_1hour` → `silver.equipment_categorical_1hour`);
- the union views `silver.*` on the gateway stitch both at a stamped boundary.

Source: [Historian gateway](../wiki/understand/components/historian-gateway.md). The first version of
this ADR said nothing wrong about the historian, but implied TimescaleDB was the history store;
it is not. The only TimescaleDB touch-point is that one foreign table reads a cagg (§5a).

**Why not DuckDB for the hot tier.** DuckDB is a single-writer, read-mostly engine: one process
holds the database file open for writes, and it has no row-level concurrency control or roles. The
hot DB is the opposite:

| Hot-DB requirement | Who | DuckDB |
|---|---|---|
| Many concurrent writers | sparkplug decoder (bronze/silver), stream-engine (gold, events, flags), edge-api (POs, downtimes, shifts), legacy replicators, barcode service | single writer |
| Row updates in place | `recalc_needed` flags (thousands per minute), upserts, Change PO, event closes and rebinds | supported, but not as a multi-writer OLTP workload |
| Transactions + constraints | FK/UNIQUE/EXCLUDE keys (e.g. PO ranges), two-phase compute/apply with `SKIP LOCKED` | no `SKIP LOCKED`, no EXCLUDE, no cross-process locking |
| Per-tenant row security | RLS policies + least-privilege roles (`stream_engine`, `readapi_ro`, `histgw_ro`, …) | no roles, no RLS |

**PostgreSQL is required for the hot tier. The TimescaleDB extension is not.**

---

## 5. What TimescaleDB actually provides today

### 5a. Continuous aggregates the engine reads (the real coupling)

`pg_stat_statements` covers 2026-09-24 11:23 → 10-14 21:28 UTC, 3,077,037 s in total. Shares
overlap, because one statement can touch several objects.

| Object | Readers | DB time |
|---|---|---|
| `equipment_categorical_1min` | `rollup/availability.go`, `compute.go`, `hour.go`, `line_lead.go`, `inferspeed.go`; `events/closer.go`, `events/cpac_deriver.go` | **910,749 s (29.6 %)** |
| `equipment_categorical_1hour` | `rollup/hour.go`, `shift.go`, `line_lead.go`; 5 serving functions; `ops.job_data_invariants`; historian FDW | 27,545 s (0.9 %) |
| `agg_equipment_values_1min/_1hour` | read-api `query.go:61-62`, `external_integration.go:331`; SAP report functions; `uns.go` | 9,434 s (0.3 %) |
| `equipment_metrics_1min` | `serving.mission_control`, `_timeline` | 156 s |
| TimescaleDB internals | refresh-window query (jobs 1013/1014), the exporter's size functions | 346,072 s (11.2 %) |

The engine does not just consume these caggs: it **already writes** every grain above them
(`gold.*`, plain tables, 32 % of DB time). A minute rollup is the same kind of work, one level
lower. What TimescaleDB adds is **invalidation**: a late or repaired raw row marks its bucket for
re-materialization. The engine would need the same thing: an invalidation table fed by the
writers (decoder replays, backfills, repairs) and consumed by the rollup tick.

Real-time caggs also caused the **#1770 class of bug**. TimescaleDB constifies the watermark only
when it plans a `SELECT`. Inside `UPDATE`/`INSERT`/`DELETE` the raw tail is priced at every chunk
(staging plans: 458 M rows, cost ≈ 2.4 × 10⁸). The worst statements were
`events-close-stale` (461,216 s, 15 % of all DB time, 19.8 s mean) and the hour speed pass
(10 % of DB time in a 7-minute window). Phase A2 split both into a read and an apply (#1775).

### 5b. Compression: over half of the saving is a cagg nobody needs today

Compression saves about 21 GB: hypertables 10.0 GB → 0.9 GB, caggs 12.4 GB → 0.47 GB. **11 GB →
384 MB of it is `ca_discrete_changes_1s`.** Who reads that cagg:

- **Code:** only `services/stream-engine/internal/events/deriver.go:68-98` (`transitionsCTE`, the
  status-type-4 deriver). No view depends on it (`pg_depend` → `pg_rewrite`: 0) and no function
  names it (0).
- **`pg_stat_statements`:** only that deriver's two statements (57,578 calls as `postgres` plus
  1,013 as `stream_engine`, 147,960 s, **4.8 % of DB time**).
- **What the deriver gets from it:** its scope is `status_type = 4` equipment (**0** on staging)
  or machines of the wide-row enterprises (`EVENTS_WIDEROW_STATE_ENTERPRISES=4`, **4** machines,
  **0** `equipment_values` rows in 30 days). Events written for that scope in the last 7 days:
  **0**.
- **What the cagg materializes anyway:** about 640 k rows/day for enterprises 5, 3 and 2000003,
  none of which the deriver reads.

So the 1-second cagg, its 27 s refresh every 15 min (job 1013) and 4.8 % of DB time produce
nothing on staging today. Without it, compression saves about 10 GB. With a 14–30 day hot window
and Parquet behind it, the remaining compression gain is a few GB on a 128 GB volume (§3).
**Compression matters little.**

### 5c. Retention and partition management

13 retention policies plus `ops.apply_retention()` reconcile a catalog table to TimescaleDB jobs.
With native partitions this becomes `DROP TABLE` (or `DETACH`) of partitions older than `keep`,
plus creating tomorrow's partition, in one pg_cron job of a few dozen lines. `pg_cron` is already
preloaded. **Trivial.**

### 5d. Not used at all

`time_bucket_gapfill`, `locf`, `interpolate` and the toolkit have 0 hits in services, db, scripts
and configs. `first()`/`last()` appear only inside one cagg definition. `time_bucket` appears in
cagg definitions, one expression index and two report adapters. `date_bin` and `date_trunc` replace
it.

---

## 6. What keeping TimescaleDB costs

| Date | What happened | Mechanism |
|---|---|---|
| 09-07 (#196) | CPACK OEE stale for a week | real-time cagg without a refresh policy → frozen watermark → every read re-aggregated raw |
| 09-09 (bug-276) | false "2.7× divergence" nearly blocked a repoint | stale materialization over since-corrected raw rows |
| 09-24 (T1–T5) | memory blow-up; a repair locked 312 chunks | chunk-wise partial aggregation over 1,599 chunks |
| 09-30 | CPACK operator 500s for ~20 min | `decompress_chunk` holds ACCESS EXCLUSIVE |
| 10-01 / 10-09 | repairs silently updated 0 rows | DML on compressed chunks with a STABLE bound |
| 10-14 (#1770, A2) | DML on real-time caggs 1.3 s → 14 s; closer 19.8 s; hour speed 6–9 s | watermark constified only for SELECT |
| 10-14 (A1) | an empty cagg's refresh burned 12 % of a vCPU | stale invalidation ranges × one-bucket batches |
| standing | scheduler does not restart after a DB restart | `start_background_workers()` superuser-only → SECURITY DEFINER wrapper |
| 08-06 | staging DB swapped and OOM'd | cagg refresh memory |

Each of these produced a runbook rule (never `decompress_chunk`, literal bounds, read back every
repair, refresh order, no cagg reads inside DML). That is a recurring tax on every engineer who
touches the data.

**License.** `timescaledb.license = timescale` (TSL). Caggs, compression, every policy and
`add_job` are TSL-only. Self-hosted internal use is allowed. AWS RDS/Aurora do not offer the
extension **(external fact, not checkable from this repo)**.

---

## 7. Version alignment (Phase A4)

| Environment | Image | TimescaleDB | PostgreSQL |
|---|---|---|---|
| staging (live) | `packiot-postgres:local` built 2026-05-18 on `timescale/timescaledb:2.27.0-pg15@sha256:3f770468…` | **2.27.0** | **15.17** |
| dev seed, CI golden fixtures | `2.27.0-pg15`, digest-pinned since A4 (#1777) | 2.27.0 | 15.17 |
| production (empty target) | `timescale/timescaledb:2.25.2-pg16` (`terraform/production/database.tf:132`) | **2.25.2** | **16** |
| `latest-pg15` today (was staging's unpinned base) | `sha256:6343bdc8…` | 2.28.3 | 15.18 |

`db/Dockerfile` used the unpinned `latest-pg15`, which has since moved to 2.28.3, so any rebuild
would have upgraded staging silently. A4 pins it to the digest staging runs.

**Alignment plan.** Nothing is upgraded by this ADR.

1. **Before promotion: production runs the same TimescaleDB as staging.** Change
   `database.tf:132` to `2.27.0-pg16`. The production DB is still empty, so this costs nothing,
   and every TimescaleDB behaviour proven on staging (watermark constification, compressed-DML
   bounds, invalidation batching) then holds on prod. Whether 2.25.2 behaves the same is
   **unverified**.
2. **PostgreSQL major: staging 15 → 16** in its own maintenance window, either by `pg_upgrade`
   (TimescaleDB supports it within one extension version) or by the rehearsed transplant. Then the
   dev seed and CI move to `2.27.0-pg16` in the same PR.
3. **If Phases B and C happen first**, step 1 becomes "production runs plain PostgreSQL 16" and
   step 2 disappears into the Phase C rebuild.
4. **Rule:** one version change at a time, always pinned by digest, and every TimescaleDB change
   ships with its `ALTER EXTENSION timescaledb UPDATE` plan.

---

## 8. Plan

### Phase A: clean up inside TimescaleDB (now; small; reversible)

| Item | PR | State | Expected effect | Exit criterion |
|---|---|---|---|---|
| A1 drop the dead `ca_equipment_boxes_1s` (0 rows; readers stubbed with identical output) | #1774 | merged; migration to apply | −12 % of one vCPU (job 1014) | job 1014 gone; `WITH dimension_slices` rate falls |
| A2 closer + hour speed read the cagg as a SELECT | #1775 | open | closer ≈ 25 s → ≈ 1 s per minute; hour speed 6–9 s → < 1 s | means in `pg_stat_statements`; golden plan test green |
| A3 exporter size queries cached 5 min | #1776 | open | ÷20 calls | calls/10 min |
| A4 pin the image to 2.27.0-pg15 by digest | #1777 | open | no silent upgrade | `db/Dockerfile` has no `latest` |
| A5 `enable_job_execution_logging = on` | #1778 | open; ALTER SYSTEM to apply | per-run job cost visible | `job_history` has successful rows |

Effort: about 1 engineer-day (done). Risk: low. Rollback: each migration has a `rollback.sql`,
and each code change is a revert.

### Phase B: the engine owns its rollup inputs (removes the coupling)

1. The engine maintains `silver.equipment_minute` and `silver.equipment_hour`. These are plain
   tables with the columns of `equipment_categorical_1min/_1hour`. The engine updates them
   incrementally each tick for the trailing window. An **invalidation table**
   (`silver.rollup_invalidation(id_equipment, ts_from, ts_to)`) is fed by a statement trigger on
   `silver.equipment_values` for rows older than the tick window (late data, replays) and by the
   repair scripts. Gold already works this way: flags plus a tick.
2. **Shadow run** for 7 days against the caggs: zero-diff per equipment-minute and
   equipment-hour (the bug-276 method).
3. **Repoint readers one at a time behind a flag:** rollup, closer, CPAC deriver, line-lead,
   read-api (`agg_equipment_values_*` → the same tables), serving functions, Mission Control
   (`equipment_metrics_1min`), the historian FDW (`live.equipment_values_1hour`), invariants.
4. **Drop `ca_discrete_changes_1s`** (jobs 1013/1034/1046) and retire the status-4 deriver's cagg
   read. It has no input on staging (§5b). If a status-4 tenant appears, it reads state changes
   from `silver.equipment_values` over its 25 h window.
5. **Shorten the hot window behind the historian:** raw silver 90 d → 30 d, bronze 90 d → 14 d.
   Do this only after the daily cold copy is verified complete for the dropped range (row counts
   per day, hot vs Parquet).

- **Effort:** 3–4 engineer-weeks. **Risk:** medium–high, because live OEE depends on it.
- **Rollback:** each repoint is a flag flip, and the caggs stay until the exit criterion holds.
- **Exit criteria:** 7 days of zero-diff; no `SELECT` in `pg_stat_statements` reads any cagg for
  7 days; rollup tick time and DB CPU no worse than before; read-api p95 no worse.

### Phase C: drop the extension

1. Each hypertable becomes a native `PARTITION BY RANGE` table with daily partitions and a BRIN on
   time. Copy day by day, then rename-swap (the transplant's swap pattern). pg_cron creates and
   drops partitions from `ops.retention_policy`.
2. Policies and `add_job` actions move to pg_cron. The bronze immutability triggers stay as they are.
3. Tooling: transplant `build.py`/`10-policies.sql`, dev seed, restore script, exporter, Grafana,
   the edge-api teardown `SET LOCAL`.
4. `DROP EXTENSION timescaledb` after 30 days with no TimescaleDB call in `pg_stat_statements`.
5. **Re-rehearse the transplant** (0 catalog diffs, swap time, OOM check).

- **Effort:** 1–2 engineer-weeks plus the rehearsal. **Risk:** medium; it is mostly mechanical.
- **Rollback:** the swap keeps the old table until verified.
- **Exit criteria:** `pg_extension` has no `timescaledb`; the rehearsal is clean; disk and CPU are
  within the §3 sizing.

**Total B + C ≈ 4–6 engineer-weeks (estimate).**

---

## 9. Production promotion and timing

The promotion (#1653) builds production with a **rehearsed TimescaleDB transplant**: 5 hypertables
and 7 caggs `WITH NO DATA`, then policies, then cagg refreshes, with 0 catalog diffs. Two orders
are possible:

| Order | For | Against |
|---|---|---|
| Promote with TimescaleDB, then B/C on staging and prod | uses the rehearsed path; no new risk at cutover | Phases B/C run twice (staging and prod); prod should first move to 2.27 (§7 step 1) |
| B/C first, re-rehearse, promote on plain PostgreSQL 16 | prod never runs TimescaleDB; one migration | promotion waits 4–6 weeks; new rehearsal |

This is a **scheduling decision for the user**. Neither order is a technical necessity.

---

## 10. Evidence files

Saved outside the repo (scratchpad `ts-evidence/` and `tsa-ev/`), produced by read-only sessions
(`SET default_transaction_read_only = on`; plans are `EXPLAIN` without `ANALYZE` for DML):

| File | Content |
|---|---|
| `q1`–`q7` (`ts-evidence/`) | first pass: inventory, caggs, jobs, workload, statement shares, internals, `ca_equipment_boxes_1s` |
| `a1*.out`, `parity*.out` (`tsa-ev/`) | A1: invalidation log, readers, live definitions, `report_shift` parity |
| `a2*.txt`, `hourspeed.txt`, `snap1/2.out` | A2: plans of the DML vs SELECT forms; 7-minute statement deltas |
| `adrq*.out`, `cad.out` | the re-verification of §2–§5 and the `ca_discrete_changes_1s` readers/scope |
| `hostq.out` | staging DB host image digests (A4) |

## 11. Unverified

- Whether TimescaleDB 2.25.2 shows the same watermark, compressed-DML and invalidation behaviour as 2.27.0.
- The DML scan cost of uncompressed 30-day partitions versus today's compressed chunks for the widest reads.
- RDS/Aurora not offering the extension (external).
- Peak ingest rate (only 24 h averages were measured).

## 12. Consequences

- Phase A removes most of TimescaleDB's CPU cost now, without touching the promotion.
- New TimescaleDB features (new caggs, new compression, new `add_job` actions) should not be
  added. Each one deepens the coupling Phase B removes.
- "A cagg with a −infinity watermark or an unconsumed invalidation backlog is a defect" belongs
  in the data invariants until Phase C.

---

## 13. As built, and the Phase C design (2026-10-15)

The user asked to carry the work through to "TimescaleDB is no more". The order in §9 is unchanged for
production (promote with TimescaleDB first); everything below runs on staging first.

### 13.1 Phase B as built: twins + rename instead of per-reader repoints

Every cagg the engine and its readers use is a plain `GROUP BY` over `silver.equipment_values` (the
1-hour categorical one over the 1-minute one). Only `time_bucket` (→ `date_bin`) and `last()`
(→ `array_agg(… ORDER BY ts DESC)[1]`) are TimescaleDB-specific. So instead of §8's repoint of ~15
readers behind flags, each cagg got a **twin** with the identical name `+ __next`, built from the
cagg itself (`CREATE TABLE AS … WITH NO DATA`: same column names *and* types). The cutover is
`DROP` the cagg + `RENAME` the twin in one transaction; **readers change nothing**.

| Step | PR | State (2026-10-15) |
|---|---|---|
| B1 twins, `silver.rollup_tick()`/`rollup_refresh()`, invalidation triggers (rows older than 15 min), backfill procedure, diff | #1805, #1808 (names resolved at runtime) | applied on staging; backfilled 91 days in 12 min; 24-hour diff 145,761 buckets/target, **0** |
| Scheduler: stream-engine `internal/rollupshadow` (every minute, `ROLLUP_SHADOW_ENABLED`) | #1805 | on (staging) |
| Gate as data: hourly `R1_rollup_twin_vs_truth` (warn, must be 0) / `R2_cagg_vs_truth` (info) in `ops.data_invariant_result`, source `rollup-shadow` | #1810 | recording; first hour R1 = 0 |
| B2 cutover, **gated in SQL** (≥ 160 hourly R1 rows in 7 days, none failing, else `RAISE`) | #1811 | merged; earliest ~2026-10-22 |
| B4 deriver reads `equipment_values` (715/715 identical events in a golden test) | #1807 | live |
| B4 drop `ca_discrete_changes_1s` (−27 s refresh / 15 min, −4.8 % DB time) | #1809 | applied (engine down 4 s) |
| Go-live extract skips the twins (derived) | #1806 (release branch) | merged |

Proven on TimescaleDB 2.27.0-pg15 with staging's real definitions: `compress_chunk` fires **no**
row trigger, an insert into a compressed chunk **does** (both needed by the invalidation design);
late inserts, repair `UPDATE`s and `DELETE`s are drained to twin = truth while the cagg stays stale
(`cagg_vs_truth` > 0: the reason for Phase B, now measured hourly).

**B5 (new, after B2): consolidate.** Pre-aggregation stays necessary (the engine's minute grain is
29.6 % of DB time *with* it; raw is ~12× more rows). Five tables are more than the need:
`equipment_metrics_1min` equals the categorical minute table summed per minute (+ `max_speed`), and
`agg_equipment_values_1min/_1hour` carry 0.3 % of DB time. Measure a week of reads, then fold.

### 13.2 Phase C design

| Decision | Choice | Why |
|---|---|---|
| Target image | **our own `postgres:16` + pg_cron** (like `db/Dockerfile` builds pg_cron today), digest-pinned, same on dev/staging/prod | prod's stock TimescaleDB image has no pg_cron; Phase C replaces the image anyway |
| Housekeeping scheduler | **pg_cron** for the three `add_job` actions (`purge_analytics_plain` — staging only, prod excludes it by design; `serving.job_refresh_downtime_events_resolved` 2 min; `ops.job_data_invariants` 30 min), partition creation and retention | runs as the owner; top-level `CALL` may `COMMIT` (`job_data_invariants` does, so it cannot be `SECURITY DEFINER` for the engine's least-privilege role) |
| Engine-owned schedule | the rollup tick only | it is the engine's input, refreshed right before it reads |
| Partitioning | native `PARTITION BY RANGE`, BRIN on time | — |
| Partition size | `silver.equipment_values` daily; `bronze.*_raw` and `silver.plc_link_minutes` weekly; `silver.equipment_events` monthly (5-year retention) | partitions ≈ query windows; a few hundred at most |
| Conversion | copy into a partitioned twin with a **change-capture trigger** (PK of every row inserted/updated/deleted during the copy), then a short window: stop writers, replay the captured keys, rename-swap, recreate dependent views (they bind by OID), grants, RLS, triggers, comments | `equipment_events` rows are UPDATEd after insert (closes, justifications); copy-by-time alone would lose those |
| Order | the 4 hypertables without caggs first (`equipment_events`, `plc_link_minutes`, both bronze), `equipment_values` after B2 | caggs pin `equipment_values` to TimescaleDB until B2 |
| Drop | `DROP EXTENSION timescaledb` after 30 days with no TimescaleDB call in `pg_stat_statements`, then the image swap | §8 exit criterion |

Live code coupling left (small): stream-engine `start_background_workers()` at boot (delete with the
extension); `time_bucket` in the box reports (**C1 #1812**: `date_bin` with TimescaleDB's
2000-01-03 origin, 0 mismatches; month buckets forbidden by CHECK); the
`timescaledb.max_tuples_decompressed_per_dml_transaction` GUC in `rollup/history.go` (a harmless
unknown custom setting after the drop; remove with it); ops scripts that call `decompress_chunk` /
`refresh_continuous_aggregate`; dev seed extract/load; `restore-db.sh`; `db_init.sh`.

