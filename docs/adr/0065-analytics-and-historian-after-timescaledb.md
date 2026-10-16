# ADR-0065 — Analytics database and historian after TimescaleDB

**Status:** Accepted, in progress (P0, P1, P3a, P5 live on staging; P2 merged, not yet applied to the running gateway) ·
**Date:** 2026-10-15, progress 2026-10-16 · **Scope:** `packiot_analytics` (hot) and the historian (cold Parquet +
`hist-gateway`) on the new stack. Staging first. **Production (changed 2026-10-16):** the Bispharma go-live builds the
new prod database from TimescaleDB-free staging, so it is born in this ADR's shape — no separate prod ADR-0063 Phase B/C
for the new database (see §6.1). **Supersedes:** nothing. **Builds on:** ADR-0063 (TimescaleDB removed on staging 2026-10-15), the
grain-tiered retention plan (`docs/plans/unified-hot-cold-serving-grain-tiered-retention.md`), ADR-0057 (historian
storage, Iceberg end state).

## 1. Decision in one paragraph

The **partition is the unit of the data lifecycle**. Every time-series table is range-partitioned. A partition is
born ahead of time, filled by ingest, **archived to Parquet** once closed, **verified** against the cold copy, and
only then **dropped** by retention. Compression, which TimescaleDB gave us in place, now lives in the cold tier
(Parquet/zstd). The hot window shrinks to what the engine and the UI read, and the historian becomes the long
memory for *every* tenant, written **from analytics**, not from legacy. The three overlapping minute rollups
collapse into one minute fact table, partitioned like the rest.

## 2. Where we are (staging, measured 2026-10-15 after the cutover)

| Thing | Now | Note |
|---|---|---|
| DB size | 18 GB | 91 GB free on the DB box |
| `silver.equipment_values` | 6.5 GB, 7-day partitions, ~406 k rows/day (Bispharma 168 k, CPACK 119 k, sandbox 119 k), **263 B/row** incl. indexes | was 381 MB compressed (17×) |
| `bronze.equipment_values_raw` | 4.8 GB, weekly partitions | was 274 MB compressed (11×) |
| Minute rollups | `equipment_categorical_1min` 1.3 GB, `agg_equipment_values_1min` 1.2 GB, `equipment_metrics_1min` 1.2 GB, **~98–99 k rows/day each** | plain tables, purged by `DELETE` |
| Hour rollups | `equipment_categorical_1hour`, `agg_equipment_values_1hour` | plain |
| `serving.downtime_events_resolved` | 679 MB | **no retention row** |
| gold | hourly 578 MB, shift 386 MB, …; kept long/forever | small, correct size for hot |
| Cold (S3 Parquet) | ~11 GB, tenant-month files, **fed from legacy only** | no backup/versioning |

Hardproof results the same night: rollups match raw silver exactly (18:00–21:00, 115 equipments, all four
rollups), invariants 75 checks / 4 failing (all failing the day before), read-api 64/65 datasets 200 per tenant
(the one 500 fixed in #1826), historian hot via FDW 52 ms with literal bounds, union continuous across the cutover,
integrity monitor R1/R4/R5 PASS.

## 3. Problems this ADR solves

1. **Silent data loss is scheduled.** `ops.partition_maintain()` drops raw partitions past retention (90 d) without
   any cold-copy check. CPACK and Incoplast are safe only because the historian copies **legacy**. **Bispharma has
   no legacy: its first raw partition (data from 2026-09-02) becomes droppable ≈ 2026-12-01** with no cold copy.
   And the legacy copy itself ends at the legacy cutover (#225).
2. **Storage without compression.** Raw grows ~107 MB/day on staging (all tenants) uncompressed. At production
   scale (ADR-0063 §3: ~2 M rows/day) that is ~0.5 GB/day → ~47 GB per 90 days of raw. Compression has no in-place
   replacement.
3. **Rollup duplication.** Three minute-grain tables with the same row count (≈ 98 k/day) carry overlapping content
   (ADR-0063 §13 "B5"); they are unpartitioned and purged by `DELETE` (bloat, vacuum churn).
4. **Historian is one-directional and fragile.** Cold is written from legacy (`historian-legacy-copy.sh`); the
   analytics writer (`historian-append.sh`) is unscheduled and writes a file glob the cold views never read; the
   cold `gold.equipment_oee_shift` view is hand-made; the Parquet archive has no backup or versioning.
5. **Observability lost its TimescaleDB metrics** (`pg_timescaledb_*` exporter queries, DBM dashboard panels) with
   nothing measuring partitions, exports, or rollups in their place.

## 4. Target architecture

```
ingest ─▶ bronze.*_raw  (weekly partitions, hot 14 d) ──export▶ s3://…/bronze/<table>/enterprise=/year=/month=/
            │
            ▼
        silver.equipment_values / equipment_events / plc_link_minutes  (partitioned, hot 35 d raw)
            │                         └──export (daily, closed days)──▶ s3://…/silver/<table>/enterprise=/year=/month=/day=/
            ▼                                                                  │
        silver.equipment_minute  (ONE minute fact, monthly partitions, hot 13 months)       │  verify (counts + Σ measures)
        silver.equipment_categorical_1hour (hour fact, monthly partitions, hot forever)     ▼
            │                                                          ops.cold_export (manifest) ──gate──▶ partition_maintain DROP
            ▼
        gold.*  (engine OEE: hour 13 months, shift/day/week/month forever — unchanged)
            │
            ▼
   read-api / Superset / front4 ── hot ──┐
                                         ├── hist-gateway (pg_duckdb): union = hot (FDW, literal bounds) + cold (Parquet)
   historian series / deep dives ────────┘
```

## 5. Decisions

**D1 — Partition everything that grows with time.** Rollups get the same tooling as raw (`ops.pc_*`):
`equipment_minute` and `equipment_categorical_1hour` monthly; `serving.downtime_events_resolved` monthly with a
retention row (it is a rebuildable cache: keep = the read-api event window). Retention becomes `DROP PARTITION`
everywhere; `purge_analytics_plain` shrinks to the genuinely plain tables (`ops.*` logs).

**D2 — Archive-before-drop is a contract, enforced in the database.** New `ops.cold_export` manifest:
`(relation, partition, id_enterprise, period, file uri, rows, Σnet, Σgross, min/max ts, exported_at, verified_at)`.
`ops.partition_maintain()` drops a partition only if **every tenant-period it covers has a verified export**, or
the relation's catalog row says `cold_copy = 'none'` (rebuildable caches, the sandbox twin). Otherwise it keeps the
partition and records `blocked` — never a silent loss. *Phase 0 ships this gate in "block everything without a
verified export" mode, before 2026-12-01.*

**D3 — The cold writer reads analytics.** A nightly exporter on the app box (DuckDB `postgres` scanner → Parquet
zstd, the same toolchain the gateway uses) writes **closed** periods: raw silver per tenant-**day** (small,
immutable files once the day is closed and the engine's late-data window has passed — 48 h), events per
tenant-day, bronze per tenant-day. It then verifies by reading the file back through DuckDB and comparing rows and
Σ measures with the partition slice, and writes `ops.cold_export`. It replaces `historian-legacy-copy.sh` for
every tenant at the legacy cutover; until then legacy-copied history stays as the pre-F3 archive (file suffix
`-legacy`) and the views read both suffixes.

**D4 — One minute fact.** `silver.equipment_minute` = the categorical minute grain (the superset: per minute ×
equipment × context dims, Σ incr, Σ/count speed, max counters, **plus `max_speed` and `ideal_production_speed`**
so `equipment_metrics_1min` is a pure projection). `equipment_metrics_1min`, `agg_equipment_values_1min` become
**views** over it (readers unchanged; ADR-0063 §13 B5 readers list), then readers move and the views go. Saves
~2.4 GB on staging and two thirds of the minute-rollup write work. `agg_equipment_values_1hour` likewise becomes
a view over the hour fact.

**D5 — Hot windows (after D2/D3 are live and verified for 14 days):**

| Data | Hot | Cold |
|---|---|---|
| bronze raw | 14 d | years (Parquet) |
| silver raw values / plc link | 35 d (covers the engine's 25-day shift windows + slack) | years |
| silver events | 13 months (small; front4 downtime screens) | years |
| minute fact | 13 months? → **decide after B5 reads are measured** (default 90 d) | years |
| hour fact, gold | as today (hour 13 months; shift/day/week/month forever) | gold is not archived (it is recomputable and small) |

Projected raw hot size: 35 d × 107 MB ≈ 3.7 GB on staging today (vs 9.6 GB at 90 d); production ≈ 18 GB.

**D6 — Historian layout and gateway.** Cold paths become `s3://…/<layer>/<table>/enterprise=E/year=Y/month=M/
day=D/<source>.parquet` (`source` = `f3` | `legacy`); DuckDB prunes on tenant + date. The union boundary becomes
**manifest-driven**: cold owns every period with a verified `ops.cold_export` row, hot owns the rest — no more
`max(cold ts)` guesswork (EV) vs `min(hot ts)` (EE). The cold `gold.equipment_oee_shift` view is codified in the
init script (or dropped if unused). Hot FDW reads keep the literal-bounds rule (postgres_fdw never ships `now()`;
a probe with `now()` scanned the whole table) — add it to read-api's historian query builder tests.

**D7 — Protect the archive.** S3 versioning + a lifecycle rule (non-current versions 30 d) on the historian bucket;
the exporter never deletes, only writes new day files. Optional cross-region replication for production.

**D8 — Observability replaces the TimescaleDB panels.** Exporter queries (and Grafana DBM panels) for: partitions
ahead per table (min days of coverage), rows in catch-alls, oldest hot partition vs retention, **export lag**
(newest closed period without a verified export), **gate blocks**, rollup tick duration + invalidation backlog,
dead tuples on remaining plain tables. Alert on export lag > 2 days and on any gate block older than 7 days.

**Rejected:** a columnar extension in Postgres (Hydra/citus-columnar) — re-creates exactly the extension coupling
ADR-0063 removed; TimescaleDB again — same; routing every read through DuckDB — the engine and `serving.*` are
PL/pgSQL on Postgres (the grain-tiered plan rejected it for the same reason); Iceberg now — ADR-0057's end state,
but the manifest in D2 is designed to map onto Iceberg snapshots later (one row ≈ one data file), so adopting it is
a storage-format change, not a redesign.

## 6. Phases

| Phase | What | Gate to the next |
|---|---|---|
| **P0 — stop silent loss** (now, before 2026-12-01) | `ops.cold_export` + the drop gate in `partition_maintain` (block mode); `cold_copy` values in the catalog (`none` for the sandbox twin and caches); `serving.downtime_events_resolved` retention row | `partition_maintain` reports blocked partitions instead of dropping; invariant added |
| **P1 — analytics exporter** | nightly DuckDB exporter per closed tenant-day (silver values/events, bronze), verify + manifest; backfill every tenant's existing raw history (90 d) | 14 nights: every closed day of every tenant exported + verified; drift = 0 |
| **P2 — gateway on the manifest** | new cold paths + `source` column; union boundary from `ops.cold_export`; codify/drop the cold shift view; S3 versioning (D7) | historian integrity monitor + a read-api parity check (hot vs cold for an overlapping week) green |
| **P3 — one minute fact (B5)** | `silver.equipment_minute` (partitioned) + compatibility views; move readers; drop the two duplicates | rollup parity (the hardproof query) = 0 mismatches for 7 days; tick time not worse |
| **P4 — shorten the hot window** | D5 windows via the retention catalog; drops now pass the gate | disk curve flat; no read-api 422 surprises (T2 honest windows) |
| **P5 — observability** (can run alongside P1) | D8 metrics, panels, alerts | panels live; alert fired once in a drill |
| **P6 — production** | after the Bispharma go-live and prod's own ADR-0063 B/C | per prod promotion plan |

### 6.1 Progress (2026-10-16)

| Phase | State | Where |
|---|---|---|
| P0 | **Live on staging** — gate in `ops.partition_maintain()`, manifest, exempt list, blocked report | #1827, `db/migrations/t-adr0065-p0-cold-export-gate` (test 16/16) |
| P1 | **Live on staging** — `scripts/historian-cold-export.sh`, systemd timer 01:30 UTC (installed by every staging deploy). First run: 144 values + 1,667 events tenant-days verified, 0 mismatched **Production (2026-10-16):** `scripts/ops/install-cold-export.sh production` (run by every prod deploy) — first run 41 values + 37 events tenant-days (Bispharma 09-02 → 10-13) verified, 0 mismatched, 0 closed days missing; 78 objects / 85 MB in `s3://packiot-production-historian-…/silver/`. Prod still drops nothing (retention keep NULL) until P4 is decided there | #1831 (test 10/10) |
| P2 | **Applied on staging's running `hist-gateway`** — three-branch union (hot ≥ F3 boundary, legacy cold below `ev_union_boundary`, F3 cold between); boundary refreshed by `refresh-f3-cutover.sql` after each export. Verified 2026-10-16: a Bispharma tenant-day dropped from hot reads back from F3 cold = manifest exactly (274,196 rows / 3,159,561 net); CPACK and ent 4 below their legacy boundary are served by the legacy copy, by design | #1833 (test 13/13) |
| P3 | **P3a live:** `silver.equipment_metrics_1min` is a view over `equipment_categorical_1min` (+ `max_speed`); parity 6,659,020 rows / 0 differing; read-api 65/65. `equipment_metrics_1min__old` (1.5 GB) dropped on staging 2026-10-16. Open question 1 answered by measurement (pg_stat_statements since 09-24): categorical_1min 107,669 calls (28 % of DB time) vs metrics_1min 274, agg_1min 876, agg_1hour 6,074 — so the remaining two duplicates (agg_1min/1hour) are small readers; folding them needs box/line columns on the fact | #1834 |
| P4 | **Live on staging (2026-10-16)** — D5 windows via `db/migrations/t-adr0065-p4-hot-windows` (bronze 14 d, silver values + plc link 35 d); first `partition_maintain`: 8 silver + 3 bronze partitions dropped, gate blocked 0; silver+bronze 17 → 11 GB. Production waits for P1 there (prod raw retention is off) | this PR |
| P5 | **Live on staging** — 6 exporter queries, 6 alerts, DBM "Data lifecycle" row; hardproof 52/52 | #1832 |
| P6 | **Folded into the go-live** (release #1836): the transplant produces a TimescaleDB-free DB (native partitions + `ops.pc_state`, staging's retention catalog), prod housekeeping runs from systemd timers (no pg_cron on the prod image), and raw retention is **off** on prod (`PROD_RAW_RETENTION=off`: prod has no cold tier until P1 runs there) | `docs/runbooks/go-live-bispharma.md` D8–D10 |

## 7. Consequences

- **Good:** no partition is ever dropped without a verified cold copy; storage is bounded by the hot window, not by
  history; one lifecycle mechanism (partitions) instead of three (chunks, caggs, row purges); the historian covers
  every tenant and survives the legacy cutover.
- **Costs:** a new nightly job with a manifest to operate; S3 grows with history (cheap: Parquet/zstd ≈ 10–20× smaller
  than hot rows); the minute-fact migration touches stream-engine and read-api readers (P3).
- **Risks:** late data after a day is exported (mitigated by the 48 h close window and re-export on late
  invalidations — the exporter re-writes a day when `silver.rollup_invalidation` touched it); DuckDB/Postgres type
  drift in the exporter (pin versions; verify step catches it).

## 8. Open questions

1. Minute fact hot window: 90 d or 13 months? Needs a week of read measurements per reader (B5's original plan).
2. Should gold also go cold (for a full analytics-DB rebuild without the engine)? Today: no — it is recomputable.
3. Sandbox twin: exclude from cold entirely (`cold_copy = 'none'`) — it mirrors CPACK.
