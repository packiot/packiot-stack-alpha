# ADR-0063 — Is TimescaleDB still needed in the analytics database?

**Status:** Proposed · **Date:** 2026-10-14 · **Scope:** the new stack's analytics database
(`packiot_analytics` on staging; the production target built by the transplant in
[`production-promotion-transplant-runbook.md`](reference/production-promotion-transplant-runbook.md)).
The legacy database, back4 and legacy oeecloud are out of scope (read-only, not touched).
**Builds on:** [ADR-0060](0060-local-development-environment-and-cpack-dev-seed.md) (seed pins PG 15.17 + TS 2.27.0),
the grain-tiered retention plan (`docs/plans/unified-hot-cold-serving-grain-tiered-retention.md`).

This ADR is an investigation. It changes no runtime behaviour. Every number below comes from a
read-only query against staging on 2026-10-14 (~20:05 UTC) or from a `file:line` in this repo at
`origin/staging`. Anything not proven that way is marked **(unverified)**.

---

## 1. Verdict

**Partially: keep TimescaleDB through production promotion, and drop or fix the parts that cost
more than they give.**

- **Keep (proven load-bearing):** hypertables, compression, retention policies, and the
  continuous aggregates that the OEE engine and APIs read (`equipment_categorical_1min`,
  `equipment_categorical_1hour`, `ca_discrete_changes_1s`, `agg_equipment_values_1min/_1hour`,
  `equipment_metrics_1min`).
- **Drop or fix now (proven waste or risk):** `silver.ca_equipment_boxes_1s` (0 rows, never
  materialized, ~12 % of one vCPU), engine DML that reads real-time caggs (the #1770 class),
  and the exporter's frequent chunk-size queries.
- **Full removal is feasible but not justified today:** every Timescale feature in use has a plain
  PostgreSQL replacement, but the estimate is **5–8 engineer-weeks** plus a new promotion
  rehearsal, and nothing forces it. The production target is a **self-hosted TimescaleDB
  container on EC2**, not RDS/Aurora (§6). If the platform moves to a managed PostgreSQL service,
  that would decide the question, and §8 is the plan.

### Decision drivers

| Driver | Finding | Weight |
|---|---|---|
| Is the OEE engine coupled to Timescale? | Yes. The rollup reads `equipment_categorical_1min/_1hour` in 8 Go files (§3.2); 29.7 % of all DB statement time reads `equipment_categorical_1min` | High: removal = re-implementing incremental rollups |
| Does compression pay? | Yes. ~21 GB saved on an 18 GB database (hypertables 10.0 GB → 0.89 GB; caggs ≈ 12.4 GB → 0.47 GB) | Medium: disk is cheap, but no core PG equivalent |
| Is there a forcing function (managed DB)? | No. Prod DB = `timescale/timescaledb:2.25.2-pg16` on an r7g EC2 (`terraform/production/database.tf:132`); RDS rejected on cost (`docs/plans/new-stack-cost-ledger.md:92`) | High: it would be decisive if it changed |
| What does Timescale cost us in CPU? | Background jobs ≈ 16 % of one vCPU (≈ 8 % of the 2-vCPU host); 75 % of that is one dead cagg | Medium: fixable inside Timescale |
| What does it cost in incidents? | 8 incidents/traps since 09-07 come from Timescale behaviour (§5.1) | High: recurring class of surprise |
| License | `timescaledb.license = timescale` (TSL). Caggs, compression, policies and `add_job` are TSL features; self-hosted internal use is allowed | Low today; blocks managed PG (§5.3) |

---

## 2. Inventory (live catalog, staging, 2026-10-14)

Raw outputs: `q1_inventory.txt`, `q2_caggs_jobs.txt`, `q3_workload.txt` (see §9).

**Engine:** PostgreSQL 15.17 (aarch64, Alpine) · `timescaledb` 2.27.0 · other extensions:
`btree_gist` 1.7, `dblink` 1.2, `pg_stat_statements` 1.10, `plpgsql`. **No `timescaledb_toolkit`**
(not even available). `pg_cron` 1.6 is preloaded and available but installed only in the `packiot`
database (`cron.database_name = packiot`). `pg_partman` and `pg_ivm` are not available in the image.
`shared_preload_libraries = timescaledb,pg_cron,pg_stat_statements,auto_explain`;
`timescaledb.max_background_workers = 12`. Database size 18 GB, of which
`_timescaledb_internal` (chunks) is 15 GB.

### 2.1 Hypertables (5)

| Hypertable | Chunk interval | Chunks (compressed) | Size on disk | Rows last 24 h | Compression before → after | Retention |
|---|---|---|---|---|---|---|
| `silver.equipment_values` | 1 day | 92 (84) | 2,432 MB | 638,662 | 6,558 MB → 381 MB (**17.2×**) | 90 d (job 1032) |
| `bronze.equipment_values_raw` | 7 days | 5 (3) | 2,073 MB | 1,211,973 | 2,934 MB → 274 MB (**10.7×**) | 90 d (job 1089) |
| `silver.equipment_events` | 1 day (+ `compress_chunk_time_interval` 30 d) | 157 (141) | 1,063 MB | 4,704 | 536 MB → 236 MB (2.3×) | 5 y (job 1094) |
| `silver.plc_link_minutes` | 7 days | 2 (0) | 66 MB | 33,120 | not compressed | 90 d (job 1102) |
| `bronze.equipment_events_raw` | 7 days | 0 | 24 kB | 0 | policy, no data | 90 d (job 1088) |

Segment-by is `id_equipment` everywhere; order-by is the time column DESC (+ `source_seq` on bronze).
Every unique key already includes the time column (`equipment_values_pkey (id_equipment, ts_value)`,
`equipment_values_raw_pkey (id_equipment, ts_value, source_seq)`, …), which native partitioning
also requires. Bronze has `BEFORE UPDATE/DELETE` immutability triggers.

### 2.2 Continuous aggregates (7, all real-time: `materialized_only = false`)

| Cagg | Bucket | Source | Size | Compressed (before → after) | Refresh: every / window | Avg run | Watermark lag |
|---|---|---|---|---|---|---|---|
| `agg_equipment_values_1min` | 1 min | `equipment_values` | 566 MB | 1,325 MB → 75 MB | 1 min / 30 min | 0.15 s | 2 min |
| `agg_equipment_values_1hour` | 1 h | `equipment_values` | 43 MB | 72 MB → 7.7 MB | 30 min / 3 d | 0.25 s | 2 h 08 m |
| `ca_discrete_changes_1s` | 1 s | `equipment_values` | 2,722 MB | **11 GB → 384 MB** | 15 min / 30 min | **27 s** | 7 min |
| `ca_equipment_boxes_1s` | 1 s | `equipment_values` | 56 kB | no | 15 min / 6 h | **108 s** (last 153 s) | **−infinity: 0 rows, never materialized** |
| `equipment_metrics_1min` | 1 min | `equipment_values` | 2,016 MB | no | 1 min / 3 h | 0.085 s | 2 min |
| `equipment_categorical_1min` | 1 min | `equipment_values` | 4,106 MB | no | 2 min / 3 h | 0.12 s | 4 min |
| `equipment_categorical_1hour` | 1 h | cagg on `equipment_categorical_1min` | 103 MB | no | 30 min / 1 d | 0.10 s | 2 h 08 m |

### 2.3 Jobs (31) and their cost

Job-execution logging is off (`timescaledb.enable_job_execution_logging = off`), so
`job_history` is empty; costs come from `_timescaledb_internal.bgw_job_stat` (cumulative since
each job was created). Failures in the last 14 days: one (job 1003, a concurrent-refresh
collision on 10-01).

| Job | What | Runs | Failures | Avg run | Share of one vCPU (avg ÷ interval) |
|---|---|---|---|---|---|
| 1014 | refresh `ca_equipment_boxes_1s` | 8,217 | 0 | 108.0 s | **12.0 %** (cumulative 246 h 34 m) |
| 1013 | refresh `ca_discrete_changes_1s` | 9,093 | 4 | 27.1 s | 3.0 % (68 h 20 m) |
| 1003 / 1057 / 1064 / 1005 / 1068 | refresh the 1-min / 1-hour caggs | 132,825 / 52,652 / 26,083 / 4,514 / 1,741 | 7 / 6 / 4 / 0 / 2 | 0.08–0.25 s | 0.5 % together |
| 1031 / 1019 / 1027 / 1028 / 1034 / 1036 / 1038 | compression (every 12 h) | 82–168 each | 0 | 113 s / 57 s / < 5 s | 0.4 % together |
| 1032, 1046, 1048, 1088–1095, 1102 | retention (daily) | 21–64 each | 0 | < 6 s | ≈ 0 |
| 1033 / 1072 / 1100 | user-defined actions: plain-table purge, downtime-resolved refresh, data invariants | 43 / 16,473 / 623 | 0 | 0.08 s / 0.85 s / 65 s | 4.3 % (not Timescale features: they would move to pg_cron) |

Timescale's own policies use **≈ 16 % of one vCPU ≈ 8 % of the 2-vCPU DB host** (upper bound:
wall-clock, includes I/O waits). Three quarters of it is job 1014 refreshing a cagg that holds
nothing.

---

## 3. Usage in code (grep of `origin/staging`)

Raw outputs: `grep_ts_api_files.txt`, `grep_ts_api_nonmigration.txt`, `grep_cagg_services.txt`.

### 3.1 Not used anywhere

`time_bucket_gapfill`, `locf`, `interpolate`, hyperfunctions/`timescaledb_toolkit` — **0 hits** in
services, db, scripts, configs. `first()`/`last()` appear only inside the
`agg_equipment_values_1min` cagg definition (`last(box_code, ts_value)`, `last(transaction_code, ts_value)`).
`time_bucket` appears in the cagg definitions, one expression index
(`equipment_values_time_bucket_idx`), and two report adapters
(`services/stream-engine/internal/reports/boxes_adapter.go:75`, `boxes_bridge.go:38`).

### 3.2 Who reads the caggs

| Cagg | Readers (file:line or DB function) | DB time (`pg_stat_statements`, since 09-24) |
|---|---|---|
| `equipment_categorical_1min` | stream-engine rollup: `rollup/availability.go:172,234,298,344`, `rollup/compute.go:182-192`, `rollup/hour.go:152`, `rollup/line_lead.go:156,229,442`, `rollup/inferspeed.go:115`, `events/closer.go:115`, `events/cpac_deriver.go:174,192,293`; parent of `equipment_categorical_1hour` | 909,557 s (**29.7 %**) |
| `equipment_categorical_1hour` | `rollup/hour.go:78,204`, `rollup/shift.go:104,179`, `rollup/line_lead.go:139-166,385-389`; `serving.machine_speed`, `oee_score_by_team`, `overview_production_chart`, `single_period_by_team`, `targets`; `ops.job_data_invariants`; historian-gateway FDW (`services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh:183`) | 28,028 s (0.9 %) |
| `ca_discrete_changes_1s` | `events/deriver.go:72` (wide-row state, ADR-0031, `config.go:162`) | 147,299 s (4.8 %) |
| `agg_equipment_values_1min` | read-api `refdata-api/query.go:61`, `external_integration.go:331`; `serving.report_shift`, `sap_report_data_sync`, `sap_site_report` (+ `_pre_p3b` twins); `reports/sap13_body.sql:108` | 1 s |
| `agg_equipment_values_1hour` | read-api `query.go:62`; `uns/uns.go:98` | 9,046 s (0.3 %) |
| `equipment_metrics_1min` | `serving.mission_control`, `serving.mission_control_timeline` | 148 s |
| `ca_equipment_boxes_1s` | `serving.report_shift` (+ `_pre_p3b`), `reports/sap13_body.sql:122` | 1 s — and it returns nothing (0 rows) |

**The engine does not replace the caggs; it consumes them.** `gold.*` is engine-written plain
tables (32.0 % of DB time), but its minute and hour inputs come from the caggs above. No cagg is
redundant with gold today, except possibly `agg_equipment_values_*` versus
`equipment_categorical_*` (same source, overlapping columns; **unverified** whether one can serve
both readers).

### 3.3 Timescale API calls by feature

| Feature | Call sites |
|---|---|
| Schema creation (`create_hypertable`, caggs, policies) | `scripts/promotion/transplant/build.py:95-111`, `10-policies.sql:13-31`; `db/init-f3/snapshot/05-f3-cagg-agg.sql`, `10-f3-timescale-supplement.sql`; 31 files under `db/migrations/` |
| Manual cagg refresh after repairs | `db/backfill/merge-silver-hole.sql:28-34`, `replace-silver-equipment.sql:39-45`, `sandbox-mirror-silver-windows.sql:89-95`; `scripts/ops/backfill-silver-gap-from-legacy.sh:276`, `repair-line-scrap-and-unbacked.sh:141`; `dev/seed/extract.sh:176-184` |
| Compressed-chunk handling | `ops.sbx_mirror_silver_day` (compress/decompress), `db/backfill/sandbox-mirror-silver-windows.sql:26-59`, `services/stream-engine/internal/rollup/history.go:206`, edge-api teardown `SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0` (`src/data/DAO/teardown/teardown-dao.ts:136`, edge-api working copy) |
| Scheduler | `services/stream-engine/cmd/oeecloud-worker/main.go:150-170` (`start_background_workers` / `public.ensure_timescaledb_workers()`); `dev/seed/load.sh:35-47` (`alter_job`) |
| Retention | `ops.apply_retention` (calls `add_retention_policy`); `terraform/staging/user_data/db_init.sh:260-298` (`drop_chunks`) |
| Monitoring | `monitoring/postgres-exporter/queries.yaml:152-273`; `grafana/dashboards/library/16-database-dbm.json:227-245`; `.github/workflows/deploy-staging.yml:703-708`; `scripts/scalability-probe.sh:103-106`; `terraform/staging/scripts/restore-db.sh:122-124` |
| Superset RLS helper | `db/superset/02-tenant-rls.sql:160-221` (guarded by `to_regclass`, already works without Timescale) |

---

## 4. Workload facts

- **Ingest:** ~1.21 M bronze rows/day and ~0.64 M silver rows/day, ~4.7 k events/day, 33 k
  PLC-link minutes/day (bounded `count(*)` over the last 24 h, uncompressed chunks only).
- **DB statement time** (`pg_stat_statements`, 2026-09-24 11:23 → 10-14, 3,067,012 s total):

| Statements touching | Share |
|---|---|
| `silver.equipment_events` | 48.4 % |
| `gold.*` (plain, engine-written) | 32.0 % |
| `equipment_categorical_1min` (real-time cagg) | 29.7 % |
| `_timescaledb_*` internals | 11.3 % — of which the cagg-refresh window query 287,106 s (9.4 %; 78,649 calls ≈ one per refresh run, mean 3.65 s, dominated by jobs 1013/1014) and the exporter's chunk-size functions ≈ 60,000 s (≈ 2 %) |
| `silver.equipment_values` | 7.3 % |
| `ca_discrete_changes_1s` | 4.8 % |

  (Rows overlap: one statement can touch several objects.)
- **What compression saves:** hypertables 10,028 MB → 891 MB; caggs ≈ 12.4 GB → 467 MB.
  **≈ 21 GB saved**, so without compression the database would be ≈ 39 GB instead of 18 GB on a
  128 GB volume. 95 % of the cagg saving is the 1-second `ca_discrete_changes_1s`.
- **Compression is not on the biggest caggs:** `equipment_categorical_1min` (4.1 GB) and
  `equipment_metrics_1min` (2.0 GB) are uncompressed.

---

## 5. What keeping Timescale costs

### 5.1 Incidents and traps caused by Timescale behaviour

| Date | What happened | Timescale mechanism |
|---|---|---|
| 09-07 (#196) | CPACK OEE stale for a week; rollup hit its 300 s budget every tick | real-time cagg with no refresh policy → frozen watermark → every query re-aggregated all raw rows |
| 09-09 (bug-276) | a false "2.7× divergence" nearly blocked a repoint | stale materialization over since-corrected raw rows |
| 09-24 (T1–T5) | memory blow-up; a repair locked all 312 chunks | per-chunk partial aggregation over 1,599 chunks; generic plans cannot exclude chunks |
| 09-30 | CPACK operator 500s for ~20 min | `decompress_chunk` holds ACCESS EXCLUSIVE on the chunk |
| 10-01 / 10-09 | repairs silently updated 0 rows | DML on compressed chunks with `UPDATE … FROM` or a STABLE bound (`date + 1`, `now()`) |
| 10-14 (#1770) | shadow deriver upsert 1.3 s → 14 s, CPU-bound | the real-time watermark is constified only when planning a SELECT, not inside INSERT/DELETE (`events/cpac_deriver.go:447-458`) |
| standing | the scheduler does not restart itself after a DB restart | `start_background_workers()` is superuser-only → SECURITY DEFINER wrapper (`oeecloud-worker/main.go:150-170`) |
| 08-06 | staging DB swapped and OOM'd on a t4g.medium | cagg refresh memory (`terraform/staging/variables.tf:38`) |
| today | `ca_equipment_boxes_1s` burns 12 % of a vCPU and returns 0 rows; its watermark is −infinity, so any real-time read re-aggregates the whole raw table | the #196 time bomb in another cagg (root cause of the 108 s refresh **unverified**) |

Each of these produced runbook rules (never `decompress_chunk`, literal bounds, refresh oldest-first,
read back every repair). That is a real tax on every engineer who touches the data.

### 5.2 Upgrade friction

- Staging builds its image from **unpinned** `timescale/timescaledb:latest-pg15` (`db/Dockerfile:3`);
  a rebuild can silently change the Timescale version. The dev seed pins 2.27.0-pg15
  (`dev/seed/Dockerfile:6`), production pins **2.25.2-pg16** (`terraform/production/database.tf:132`).
  Three engines, two Timescale versions, two PostgreSQL majors. Whether the 2.27 behaviours above
  (stable-bound DML, watermark constification) are the same on 2.25.2 is **unverified**.
- Timescale stores catalog rows that `pg_dump` cannot restore across versions without
  `timescaledb_pre_restore()`/`post_restore()`, so the transplant rebuilds hypertables and caggs
  by script (`build.py`) instead of dumping them.

### 5.3 License and managed-service path

`timescaledb.license = timescale` (TSL, "Community"). Features in use that are **TSL-only**:
continuous aggregates, compression/columnstore, all policies (refresh, compression, retention) and
`add_job` user-defined actions. Apache-2 features: hypertables, `time_bucket`, `drop_chunks`,
`first`/`last`. The TSL allows self-hosted internal use; it forbids offering TimescaleDB itself as
a hosted database service, which Packiot does not do. AWS RDS and Aurora PostgreSQL do not offer
the `timescaledb` extension (**external fact, not checkable from this repo**). Timescale tiered
storage is Cloud-only (`docs/plans/unified-hot-cold-serving-grain-tiered-retention.md:88`).

---

## 6. Production promotion impact (#1653, transplant)

- **Target:** a self-hosted `timescale/timescaledb:2.25.2-pg16` container on a dedicated r7g EC2
  (`terraform/production/database.tf:1-20, 82-132`; `compose.production.yml:98-112`).
- **No RDS/Aurora plan.** `terraform/` has no `aws_db_instance` or `aws_rds_cluster`. The cost
  ledger states "DB self-hosted on EC2, not RDS" (~$100/mo saved, `docs/plans/new-stack-cost-ledger.md:92`);
  the roadmap only lists "consider RDS/Timescale Cloud" as LATER (`docs/adr/reference/production-buildout-roadmap.md:302`).
- **The transplant depends on Timescale:** it creates 5 hypertables and 7 caggs `WITH NO DATA`,
  then 11 policies, then refreshes every cagg (`docs/adr/reference/production-promotion-transplant-runbook.md:29-43`,
  `scripts/promotion/transplant/10-policies.sql`). The rehearsal passed with 0 catalog diffs.
- **Conclusion:** removing Timescale before promotion would invalidate a rehearsed cutover and
  move the OEE engine's inputs at the same time. Nothing in the promotion requires it.

---

## 7. Feature-by-feature: in use, replacement, cost

| Feature | In use? | By what | Plain PostgreSQL replacement | Cost to replace |
|---|---|---|---|---|
| Hypertables (5) | yes | all ingest + reads | declarative `PARTITION BY RANGE` (daily/weekly), partitions created ahead by pg_cron (pg_partman is not in the image; would need a build stage like `pg_cron`) | 3–5 d + rehearsal; keys already include time; rewrite the `time_bucket` expression index |
| Continuous aggregates (7) | yes, load-bearing | OEE rollup, deriver, read-api, serving, historian FDW | engine-maintained rollup tables, refreshed incrementally per tick with an **invalidation log** for late data and repairs (what Timescale does for us today); `pg_ivm` is not available and cannot do `GROUP BY time` windows well | **2–4 weeks** + parity soak; the riskiest part (live OEE) |
| Real-time cagg union | yes (all 7) | every reader | not needed if readers accept the materialized lag (1–2 min), or the engine reads its own tail | part of the above |
| Compression | yes, 21 GB saved | hypertables + 3 caggs | none in core. Accept ≈ +9 GB for 90-day raw and drop the 1-s cagg; cold data already goes to the Parquet historian | ≈ 0 effort, + disk (gp3 ≈ $0.08/GB-month → < $2/month) and slower wide scans (**unverified**) |
| Retention policies | yes | 13 policies + `ops.apply_retention` | `DROP TABLE` / `DETACH PARTITION` of old partitions from the pg_cron job | 1–2 d |
| `add_job` user actions (3) | yes | purge, downtime refresh, invariants | `pg_cron` `cron.schedule_in_database` (already preloaded) or a stream-engine ticker | 1 d |
| `time_bucket` | yes (definitions, 1 index, 2 adapters) | — | `date_bin` (PG14+) / `date_trunc` | < 1 d |
| `first`/`last` | yes (1 cagg) | `agg_equipment_values_1min` | `(array_agg(x ORDER BY ts DESC))[1]` or `DISTINCT ON` | < 1 d |
| gapfill / locf / interpolate / toolkit | **no** | — | `generate_series` joins if ever needed | 0 |
| Tooling | yes | transplant, dev seed, restore, exporter, Grafana, CI, edge-api teardown | rewrite against `pg_partitioned_table`/`pg_inherits` | 3–5 d |

**Full removal ≈ 5–8 engineer-weeks**, plus a new transplant rehearsal and a parity soak of gold
against the current numbers.

---

## 8. Decision and phased plan

### Phase A — fix inside Timescale (now, small, reversible)

1. **`ca_equipment_boxes_1s`:** prove its readers (`serving.report_shift`, `reports/sap13_body.sql:122`)
   get nothing today (0 rows), then remove its refresh policy (job 1014) and replace the read with
   the barcode source or drop the cagg. **Expected:** −12 % of one vCPU and roughly −6.7 % of DB statement time (estimate: ≈ 1,920 runs since 09-24 × 108 s ≈ 207,000 s of the 3.07 M s total).
   Rollback: `add_continuous_aggregate_policy` again.
2. **No real-time cagg reads inside DML.** Check which other engine paths read
   `equipment_categorical_1min` inside `INSERT … SELECT`/`UPDATE` (**unverified** how many) and apply the #1770 pattern (a separate SELECT), or set
   `materialized_only = true` on the caggs whose readers tolerate the 1–2 min lag. Measure: the
   `equipment_categorical_1min` share of `pg_stat_statements` (29.7 % today).
3. **Exporter:** run the Timescale size queries less often (they ran 543,735 times since 09-24, ≈ 2 % of DB time).
4. **Pin the staging image** to an explicit Timescale version and align it with production
   (2.25.2-pg16 vs 2.27.0-pg15) before promotion.
5. Turn on `timescaledb.enable_job_execution_logging` so job cost is visible per run.

### Phase B — keep through promotion

Promote with the rehearsed transplant. Do not change the engine's inputs in the same window.

### Phase C — only if a trigger fires (managed PostgreSQL, a Timescale upgrade that breaks, or the engine taking over minute rollups)

1. Engine writes `silver.equipment_minute` / `_hour` itself (incremental by tick + invalidation
   table fed by repairs and late data); run it **in parallel** with the caggs (shadow), compare
   per equipment-hour for 7 days (zero-diff gate, the method of bug-276).
2. Repoint readers one at a time (rollup, deriver, read-api, serving, FDW) behind a config flag.
3. Native partitioning for the 5 hypertables: new partitioned table, copy by day, rename-swap
   (the transplant's swap pattern); partitions managed by pg_cron.
4. Retention → partition drops; `add_job` actions → pg_cron.
5. `DROP EXTENSION timescaledb` last, after 30 days with no Timescale calls in `pg_stat_statements`.

**Rollback at every step:** the old path stays until its replacement has passed a zero-diff soak;
each repoint is a flag flip; the swap keeps the old table (as the transplant keeps the old DB).
**Measure:** gold zero-diff per equipment-hour, rollup tick time, DB CPU, disk growth, read-api p95.

---

## 9. Evidence files

Saved outside the repo (scratchpad `ts-evidence/`), produced by read-only sessions
(`SET default_transaction_read_only = on`):

| File | Content |
|---|---|
| `q1_inventory.txt` | version, extensions, settings, hypertables, approximate rows |
| `q2_caggs_jobs.txt` | caggs, cagg sources, compression settings and stats, jobs, job_stats |
| `q3_workload.txt` | job errors, recent chunks, last-24 h counts, DB and relation sizes |
| `q4_pgss_deps.txt` | `bgw_job_stat` cumulative durations, logging setting, statement totals |
| `q5_pgss_deps.txt` | statement share by object, top statements, view/function dependencies, grants |
| `q6_tsinternal.txt` | Timescale-internal statements, triggers, indexes, cagg definitions |
| `q7_boxes.txt` | `ca_equipment_boxes_1s` contents, watermarks, extension availability |
| `grep_*.txt` | repo greps behind §3 |

## 10. Consequences

- Timescale stays; the team keeps its runbook rules (§5.1) and should add "a cagg with a −infinity
  watermark is a defect" to the data invariants.
- Phase A removes most of Timescale's CPU cost without touching the promotion.
- If a managed PostgreSQL service is ever chosen, this ADR's §7–§8 is the starting estimate.
