# Production DB (tsp12 / packiot40) — Bug Catalog — 2026-07-11

**Scope:** defects found in the **production client-facing** database during the read-only DBA audit (see [prod-tsp12-dba-audit-2026-07-11.md](prod-tsp12-dba-audit-2026-07-11.md)). These are **legacy** issues in the client's live DB — most predate and are independent of the `packiot_shadow` refactor.
**Access:** all findings gathered **read-only** (`BEGIN READ ONLY`, `awslambda` role). **No changes were made to prod.**
**Fix ownership:** items marked *Client* require action on tsp12 by the client/ops; items marked *Refactor* are already handled (or planned) on the staging/refactor side and reach the client only via the migration.

Format per bug: **Symptom → Root cause → Impact → Fix → Rule.**

---

## BUG-01 🔴🔴 — Unbounded custom invalidation log (122 GB, ~37% of the DB)

- **Symptom:** `agg_equipment_values_1min_t_invalidation` is 75 GB (+30 GB PK +17 GB an index that is never read) and holds **485,623,584 rows**. Disk pressure; slow 1-minute-aggregate refreshes; every write pays an insert tax.
- **Root cause:** trigger `piot_feed_invalidation_log` on `equipment_values` appends a row for every insert of data >9 min late, and **nothing ever deletes from the table** (verified: no function/procedure issues a `DELETE` against it). The consumer that should drain it either never deletes or was removed. It grows forever.
- **Impact:** ~1/3 of the 333 GB database is a never-drained queue; write amplification on the hottest table; the 17 GB `id_equipment` index (`idx_scan=0`) is pure overhead.
- **Fix:** *Client* — prune the table (bounded, oldest-first batched `DELETE`), fix or remove the consumer, and ultimately drop the trigger. *Refactor* — **already shed**: staging has no such trigger (only a 16 KB empty shell in `packiot.public`).
- **Rule:** a queue/log table fed by a per-row trigger MUST have an owned, monitored drainer; an un-pruned trigger-fed table is a time bomb.

## BUG-02 🔴 — OEE compute statements averaging 25–82 s/call

- **Symptom:** `pg_stat_statements` top cost center: **82,569 ms avg × 104,354 calls = 2,394 cumulative hours**; several more at 25–55 s avg. To the client this reads as "the tables aren't processing / dashboards are stale."
- **Root cause:** the legacy OEE stored functions. Concretely, `piot_get_shift_hour_begin_by_equipment` takes ~45 ms/call because ~10 correlated `timezone`/`week_begin` subqueries are re-evaluated **per output row** (internal scan is 0.2 ms); the provision loop calls it ~12,395×/run. (Full analysis in task #58.)
- **Impact:** provision/rollup runs take 12–30 min holding a serialization lock; OEE lags.
- **Fix:** *Refactor* — the Go rollup engine replaces the stored-proc compute; the helper function itself was optimized (~45→16 ms, byte-identical) in `edge-node-red#21`, applied live to staging.
- **Rule:** hoist per-call-constant subqueries out of row-level expressions; a function whose scan is 0.2 ms but runtime is 45 ms is doing redundant work per row.

## BUG-03 🔴 — `user_logs` missing index (69 billion rows scanned)

- **Symptom:** `user_logs` (466 MB) shows **144,552 sequential scans reading 69,130,150,318 cumulative rows** — it carries only its primary key.
- **Root cause:** queries filter `user_logs` by `ts_event`/`id_enterprise` (mirror-worker, reports) but there is no supporting secondary index → full scans.
- **Impact:** sustained wasted I/O; slows every consumer that reads `user_logs`.
- **Fix:** *Client + Refactor* — add a composite index matching the hot predicate (likely `(id_enterprise, ts_event)`).
- **Rule:** a table with only a PK but heavy non-PK filtering is a guaranteed seq-scan hotspot — check `pg_stat_user_tables.seq_tup_read`.

## BUG-04 🔴 — Compression policy failing 47% of runs

- **Symptom:** `policy_compression` on `equipment_values`: **319 failures / 682 runs**.
- **Root cause:** not fully determined read-only; likely repeated attempts on chunks that are locked or already in a state the policy errors on. Bulk is compressed (1332/1404 chunks), so it's noisy waste rather than total failure.
- **Impact:** wasted background-worker cycles; real failures hidden in the noise; some chunks may stay uncompressed longer than intended.
- **Fix:** *Client* — inspect the job's error detail (`timescaledb_information.job_errors`), tune the compression policy's chunk selection.
- **Rule:** a background job with a ~50% failure rate is a monitoring gap, not "mostly working."

## BUG-05 🟠 — Autovacuum starvation on large tables

- **Symptom:** `cron.job_run_details` last autovacuumed **7 weeks ago** (1.15M un-analyzed mods); `area_runtime_1hour` **3 weeks**; big runtime tables carry 10–16 % dead tuples.
- **Root cause:** `autovacuum_vacuum_scale_factor = 0.2` (the default) means a 16 M-row table waits for **3.3 M dead rows** before autovacuum triggers — far too lax at this scale. High-churn tables also outrun the naptime.
- **Impact:** table + index bloat; stale planner statistics → worse query plans (compounds BUG-02).
- **Fix:** *Client + Refactor* — per-table `autovacuum_vacuum_scale_factor = 0.02` + a threshold floor on the hot tables (already applied to 24 tables on staging).
- **Rule:** the global `0.2` scale factor does not scale to multi-million-row tables — set per-table overrides on hot tables.

## BUG-06 🟠 — Unbounded pg_cron history

- **Symptom:** `cron.job_run_details` is 8.3 GB with 11.9 M rows and **~5 GB of unused indexes** on it, with no retention.
- **Root cause:** pg_cron records every job run forever; nothing prunes the history table.
- **Impact:** wasted storage, autovacuum load (feeds BUG-05), slow cron introspection.
- **Fix:** *Client + Refactor* — scheduled retention (`DELETE end_time < now() - interval '7 days'`) + drop the two unused indexes.
- **Rule:** any append-only operational log needs a retention policy from day one.

## BUG-07 🟠 — ~25 GB+ of unused indexes

- **Symptom:** multiple `idx_scan = 0` indexes: the 17 GB invalidation index (BUG-01), ~5 GB on `job_run_details`, dashboard-table PKs (2.5 GB + 696 MB), and a heavily over-indexed continuous aggregate (`_materialized_hypertable_158` with several 440–496 MB unused indexes).
- **Root cause:** indexes added for queries that no longer run, or never ran.
- **Impact:** write amplification (every insert maintains them) + wasted storage.
- **Fix:** *Client* — confirm genuinely unused over a full workload cycle, then drop.
- **Rule:** audit `pg_stat_user_indexes.idx_scan` periodically; a 0-scan multi-GB index is dead weight — but confirm across a full cycle (counters reset on restart).

## BUG-08 🟠 — `max_wal_size = 1 GB` on a 333 GB write-heavy DB

- **Symptom:** checkpoints fire far too frequently → periodic I/O storms.
- **Root cause:** default-ish WAL sizing never raised for the write volume.
- **Fix:** *Client + Refactor* — raise to 4–8 GB (staging already at 4 GB).
- **Rule:** size `max_wal_size` to the write rate, not the default; frequent checkpoints are an invisible I/O tax.

## BUG-09 🟡 — Tables without a primary key

- **Symptom:** `monitoramento_execucao_functions` (2.1 GB) and several `report_*` tables have no PK.
- **Root cause:** append/audit tables created without a key.
- **Impact:** replication hazards, no natural dedup, risky `UPDATE`/`DELETE`.
- **Fix:** *Refactor* — add PK/unique keys after a dedup check (staging equivalents: `uns_metrics`, `production_orders_runtime`).
- **Rule:** every table gets a primary key unless there is a deliberate, documented reason.

## BUG-10 🟡 — Enterprise-hardcoded mega-functions + inconsistent naming

- **Symptom:** the largest function bodies are per-enterprise-hardcoded — `piot4_13_get_production_po` (46k chars), `h_piot_oee_score_full_3/4`, `get_report_shift_enterprsie_06*`, `update_piot_table_..._enterprise_06*`. Note the **misspelling `enterprsie`** baked into object names.
- **Root cause:** features shipped per-client by cloning + hardcoding the enterprise id into a new function, rather than parameterizing.
- **Impact:** unmaintainable duplication; every new client multiplies the surface; typos become permanent identifiers.
- **Fix:** *Refactor* — parameterize by enterprise; consolidate the clones; adopt a consistent human-readable naming convention (tracked in #61, the rename map).
- **Rule:** never encode a tenant id or a typo into an object name; parameterize instead.

---

## Summary

| Bug | Severity | Fix owner | Refactor status |
|-----|----------|-----------|-----------------|
| 01 invalidation log 122 GB | 🔴🔴 | Client | Shed |
| 02 slow OEE functions | 🔴 | Refactor | Fixed (#58, Go engine) |
| 03 user_logs missing index | 🔴 | Both | Planned |
| 04 compression 47% fail | 🔴 | Client | — |
| 05 autovacuum starvation | 🟠 | Both | Done (staging) |
| 06 pg_cron unbounded | 🟠 | Both | Planned |
| 07 unused indexes | 🟠 | Client | Planned |
| 08 max_wal_size 1 GB | 🟠 | Both | Done (staging) |
| 09 no-PK tables | 🟡 | Refactor | Planned |
| 10 hardcoded/typo names | 🟡 | Refactor | Rename map (#61) |

**The two client-critical, refactor-independent bugs are #01 (122 GB log) and #03 (missing index)** — either alone explains "the tables aren't processing." These are recommendations for the client's own DB; the staging/refactor side is already addressed or planned. Tracked in tasks #57–#61.
