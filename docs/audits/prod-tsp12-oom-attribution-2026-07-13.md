# Production DB (tsp12 / packiot40) — RAM Thrash / OOM Attribution — 2026-07-13

**Scope:** read-only forensic attribution of the client-reported "prod DB thrashing and restarting, mostly due to RAM." Answers one question: *are our periodic SELECTs (the tsp12 comparator + `deploy-staging.yml` audit query bank + `mirror-worker-go` reads) the cause of the OOM — root cause, contributor, trigger, or irrelevant — and if not us, what is?*
**Constraints:** tsp12 accessed **strictly read-only** (`BEGIN READ ONLY`, `awslambda` role, SELECT-only, every query in `... ROLLBACK`). **No changes were made to prod.** All fixes below are recommendations for the client / devops; nothing was applied.
**Relationship to prior audit:** complements [`prod-tsp12-dba-audit-2026-07-11.md`](./prod-tsp12-dba-audit-2026-07-11.md) (general health audit). That audit's finding #11 (`max_background_workers`) and #5 (autovacuum) touch memory; this audit is the focused **OOM root-cause + attribution**.

**Instance snapshot:** PostgreSQL **12.11** · TimescaleDB 2.11.0 · EC2 `i-03b5bf835eebae341` = **r6i.4xlarge = 128 GiB RAM / 16 vCPU** (us-east-2). NOTE: this is **prod**, a different box from the **staging** DB (`10.10.10.89` / `i-064bb36d1c454d861`) resized in session 84 — do not conflate.

---

## TL;DR — verdict + findings ranked

**Are our SELECTs the cause? NO. Root cause: no · Contributor: no · Trigger: no · Verdict: IRRELEVANT** (`awslambda` role = **0 bytes temp spilled, 0.7 min cumulative exec over 373,381 calls, ≤3 connections** of which 2 idle). Not a rounding error against the continuous tenants.

| # | Severity | Finding | Evidence | Fix (client / devops) |
|---|----------|---------|----------|-----------------------|
| 1 | 🔴🔴 | **`shared_buffers` = 49.6 GB = 38.7% of 128 GB** (norm 25%) | `pg_settings`; leaves only 78.4 GB for OS + page cache + all backends + autovacuum (≤20 GB) + parallel DSM | Lower to **32 GB** (25%); frees ~17 GB headroom. Restart required |
| 2 | 🔴 | **PG12 non-spilling `HashAggregate`** — the OOM *trigger* | PG12 hashagg ignores `work_mem`, builds full hash table in RAM until OOM (fixed PG13, commit `1f39bce02`). Leaves **no temp trace** | Bound `max_parallel_workers_per_gather` 8→2–4; **permanent fix: upgrade off PG12** |
| 3 | 🔴 | **`postgres` role = 161 GB temp spilled** (one stmt 146 GB) | `pg_stat_statements`, 28-day cumulative; pg_cron + OEE stored procs | Go rollup migration (already in progress) removes these |
| 4 | 🟠 | **Autovacuum ≤ 20 GB peak** — `10 workers × 2 GB` | `autovacuum_max_workers=10`, `autovacuum_work_mem=-1`→inherits `maintenance_work_mem=2 GB` | Pin `autovacuum_work_mem` 512 MB–1 GB; workers 10→4 |
| 5 | 🟠 | **`max_connections=350`, no pooler, no per-role connlimit** | 954k Hasura + 3.56M oeecloud short calls churn backends | **pgbouncer** (txn pooling) for hasura/oeecloud/edgeapi/awslambda |
| 6 | 🟡 | **`temp_file_limit=-1`** (uncapped) | `pg_settings` | Set a sane cap (runaway-query disk-fill guard; not a RAM cause) |
| 7 | 🟡 | **`effective_cache_size=92.9 GB`** incoherent with #1 | 49.6 + 92.9 > 128 GB — planner told more cache exists than can | Recompute to ~50–75% RAM *after* fixing shared_buffers |
| — | ⚪ | **OPEN: OOM victim/signal + containerization unconfirmable from SQL** | `logging_collector=off`, `awslambda` not superuser, no host shell | devops: `journalctl`/`docker logs` on `i-03b5bf835eebae341`; check if PG is an **unbounded container** (the staging root cause) |

---

## 1 — The over-commit math (the smoking gun)

| Setting | Value | Note |
|---|---|---|
| Host RAM | **128 GiB** | r6i.4xlarge |
| `shared_buffers` | **49.6 GB** | **38.7% of RAM** — norm is 25% (~32 GB) |
| `effective_cache_size` | 92.9 GB | planner hint only; 49.6 + 92.9 > 128 → incoherent |
| `work_mem` | 19.8 MB | **per sort/hash node, per parallel worker** |
| `max_parallel_workers_per_gather` | **8** | one query = leader + 8 = **9× the work_mem multiplier** |
| `maintenance_work_mem` | 2.0 GB | `autovacuum_work_mem = -1` → inherits 2 GB |
| `autovacuum_max_workers` | **10** | worst case 10 × 2 GB = **20 GB** |
| `max_connections` | 350 | no per-role limit, no pooler |
| `temp_file_limit` | -1 | uncapped |
| `hash_mem_multiplier` | *absent* | **this is PG12** — see §2 |

Headroom after `shared_buffers`: `128 − 49.6 = 78.4 GB` must cover OS + page cache + every backend's work_mem + autovacuum (≤20 GB) + parallel-worker DSM (`/dev/shm`) + WAL/temp buffers.

**The naive bound is NOT the problem:** `max_connections × work_mem = 350 × 19.8 MB = 6.8 GB`. Ruling this out matters — it redirects to the real vector: **parallel analytic queries multiplied by 9 (leader + 8) across multiple hash/sort nodes, stacking with 2 GB autovacuum allocations, on a box whose cache already ate 49.6 GB.**

## 2 — PG12 non-spilling HashAggregate (the trigger)

Before PG13, `HashAggregate` did **not** spill to disk when it exceeded `work_mem` (memory-bounded hashagg landed in PG13, commit `1f39bce02`). On PG12 a `GROUP BY` that under-estimates cardinality builds the **entire** hash table in RAM, **ignoring `work_mem`** → an unbounded multi-GB allocation with no ceiling. One bad plan on a big cagg/table + 8 parallel workers = OOM.

**Diagnostic consequence:** the dangerous queries show **no temp spill** (hashaggs don't spill on PG12 — only *sorts* do). They eat RAM silently until the OOM killer fires. So `pg_stat_statements.temp_blks_written` under-counts the true memory hogs — **absence of temp ≠ innocence.**

## 3 — Attribution (pg_stat_statements, 28-day cumulative)

**Temp spilled (work_mem overflow) by role** — sorts only, see §2 caveat:
`postgres` **161 GB** (dominant; one stmt 146 GB / mean 11.3 s / 576 calls) · `packiotapi` 11 GB · `powerbi` 1.1 GB · `hasuraqueries` 307 MB · **`awslambda` (us) 0 bytes.**

**Total exec time by role:** postgres 1389 min · hasuraqueries 670 min (954k calls) · oeecloud 312 min (3.56M calls) · bigquerysync 216 min · edgeapi 140 min · powerbi 88 min · datadog 63 min · **`awslambda` (us) 0.7 min / 373,381 calls.**

**Live connections (81 of 350):** oeecloud 28 · hasuraqueries 18 · `eduardow` JDBC 12 · powerbi 5 · packiotapi 3 · **awslambda 3** (2 idle mirror-worker + 1 audit psql).

**Our footprint:** 0 bytes temp, 0.7 min exec, ≤3 conns (2 idle). Comparator's heavy reads run single-connection, `statement_timeout` 10 min, periodically. **~0.05% of total exec, 0% of temp pressure.** No per-role `work_mem` override exists (`pg_db_role_setting` empty) — nobody is bumped to a giant work_mem.

## 4 — The restart classified: backend OOM, not host reboot

`pg_postmaster_start_time()` = 2026-06-15 → **uptime 28 days.** The *postmaster* has not restarted. When the Linux OOM killer SIGKILLs a **child backend**, the postmaster detects the crash, terminates all other backends, runs automatic crash-recovery, and continues — **same PID, same start-time.** Users experience "restart" (every connection drops at once), but `pg_postmaster_start_time` stays put. A host reboot or postmaster kill would reset uptime to minutes.

→ Evidence points to **recurring backend-level OOM kills with postmaster survival** — exactly what over-sized `shared_buffers` + an unbounded parallel hashagg produces. A host reboot would look different (uptime reset).

## 5 — What could NOT be determined (needs host access)

`logging_collector=off`, `log_destination=stderr`, `awslambda` `is_superuser=off` (no `pg_read_file`), no SSM/SSH to `i-03b5bf835eebae341`. Therefore:

- **Cannot confirm the exact OOM victim/signal** from SQL — need `journalctl -k` / `docker logs` for `out of memory`, `terminated by signal 9`, `crash of another server process`.
- **Cannot confirm containerization.** `shared_memory_type=mmap` is native-style but not conclusive. **If prod PG runs in an unbounded docker container** (the exact staging incident root cause), this is a cgroup-v2 OOM; if bare systemd, host OOM by `oom_score`. The over-commit root is identical either way, but the fix surface differs.

**→ devops action item:** pull host logs + confirm containerization / `mem_limit`.

## Fix hierarchy (propose only — nothing changed)

1. **`shared_buffers` 49.6 → 32 GB** (25%). Biggest single lever; frees ~17 GB. Restart window — hand to devops.
2. **Bound parallelism** `max_parallel_workers_per_gather` 8 → 2–4 DB-wide, per-session bump for OEE procs. **Durable: upgrade off PG12** (memory-bounded hashagg) — cross-service ADR (Hasura / pg-promise / TimescaleDB 2.11 compat) → tech-lead.
3. **Cap autovacuum memory** `autovacuum_work_mem` 512 MB–1 GB; `autovacuum_max_workers` 10 → 4.
4. **pgbouncer** (txn pooling) for chatty consumers → collapses backend count + connection-storm risk.
5. `temp_file_limit` cap + a few GB **swap as shock-absorber only** (band-aid; a swapping DB is slow).

## Owners
- **devops-platform:** shared_buffers / autovacuum / parallelism GUC changes + restart window; pgbouncer rollout; **confirm OOM victim/signal + containerization on the prod host** (the one gap SQL couldn't close).
- **tech-lead:** PG12→13+ upgrade decision (only permanent kill for the non-spilling-hashagg OOM class).
- **Our side:** no app/DAO change — the `awslambda` read path is not implicated. Comparator/audit reads stay as-is.

## Method / reproducibility
Read-only wrapper: `BEGIN READ ONLY; ... ; ROLLBACK` via `awslambda` role (same path as `scripts/powerbi-evidence-prod-read.sh` and `services/mirror-worker-go/internal/db/prod.go`). Key queries: `pg_settings` (memory GUCs), `pg_postmaster_start_time()`, `pg_stat_statements` grouped by role (temp_blks_written, total_exec_time), `pg_stat_activity` by usename/application_name, `pg_db_role_setting` (per-role overrides).

## Study note
Generalized lesson captured at `~/notes/systems/postgresql-oom-shared-buffers-hashagg.md` (read-only ≠ resource-safe · the PG memory model · PG12 hashagg · the `pg_postmaster_start_time` forensic).
