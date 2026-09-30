---
title: DBA guide
layer: 4
owner_area: analytics-db
last_verified: 2026-09-28
---
# DBA guide

> **Layer 4 · Operations** — how to query, check, repair and back up the analytics DB and the
> historian without hurting the live stack. Replaces the older numbered page
> `13-dba-guide.md`; every command here was checked against the staging catalog and repo on
> 2026-09-28. Up: [Analytics DB](../subsystems/analytics-db.md)

## Golden rules

1. **One application database**, `packiot_analytics`, separated by schema (ADR-0056). The
   `packiot` database on the same staging cluster is the frozen F1 schema; do not write it.
2. **The shared DB is production-like.** Ingest writes every second, rollups run every
   minute, and one runaway query can OOM the whole cluster. Every manual session sets
   `statement_timeout` and `lock_timeout`.
3. **Read before you write.** Count the rows a repair will touch, back them up to `ops`,
   run the change inside `BEGIN … ROLLBACK` first, then for real, then verify the count.
4. **Never change retention by hand.** Edit `ops.retention_policy` and
   `CALL ops.apply_retention()` ([Timescale jobs & retention](../components/timescale-jobs-and-retention.md#the-retention-catalog)).
5. **Test as the application role**, not as `postgres`. Superuser bypasses RLS and hides
   the plan the app actually gets.
6. **Approval is for the state you asked about.** If time has passed, re-check before acting
   (the 2026-09-25 reboot of an already-recovered host).

## Read-only access

| Path | Identity | Sees | Use for |
|---|---|---|---|
| CloudBeaver, `db.staging.packiot.app` (Cognito cs-admin gate), connection "packiot_analytics" | `cloudbeaver_ro` (SELECT-only, BYPASSRLS) | all tenants, read-only | browsing, ad-hoc SELECTs |
| CloudBeaver, connection "historian gateway (read-only)" | `cloudbeaver_histro` | hot `live.*` and boundary tables; **cannot** run `read_parquet` | checking boundaries, hot rows |
| SSM → DB host → `docker exec -i timescaledb psql -U postgres -d packiot_analytics` | superuser | everything | DDL, repairs, anything CloudBeaver cannot do |
| SSM → app host → `docker exec -i hist-gateway psql -U postgres -d packiot_historian` | gateway superuser | hot + cold | cold queries, boundary refresh |
| `pgweb-analytics` container (port 8082, unrouted fallback) | `postgres` superuser | everything | avoid: superuser in a browser |

`scripts/ssm-psql.sh` encodes the stdin-safe way to run a SQL file through SSM
(`docker exec -i`, base64 transport). Instance ids: DB host `i-064bb36d1c454d861`, app host
`i-06c9547a2c7091ab7`.

Start every manual session with:

```sql
SET statement_timeout = '30s';
SET lock_timeout      = '3s';
SET application_name  = 'dba-<your-name>';
```

Reproduce exactly what an app role sees:

```sql
-- read-api
BEGIN;
SET LOCAL ROLE readapi_ro;
SELECT set_config('app.tenant_id', '3', true);
SELECT * FROM serving.downtime_by_category(...);   -- the call under test
ROLLBACK;
```

```sh
# Superset (bi views): connect as superset_ro with the GUC stamped like the mutator does
psql "host=10.10.10.89 dbname=packiot_analytics user=superset_ro options='-c app.tenant_id=5'"
```

A superuser selecting through a `bi.*` view sees **0 rows**, because the view runs as
`bi_owner` with FORCE RLS and no GUC. That is not "empty data".

## Health checks

Is ingest fresh?

```sql
SELECT id_enterprise, max(ts_value), now() - max(ts_value) AS lag
  FROM silver.equipment_values
 WHERE ts_value > '2026-09-28 00:00+00'          -- literal bound: chunk exclusion
 GROUP BY 1 ORDER BY 1;
```

Is OEE fresh for a tenant? (dashboards look stale)

```sql
SELECT max(s.computed_at), now() - max(s.computed_at) AS lag
  FROM gold.equipment_oee_shift s
  JOIN core.equipments e USING (id_equipment)
 WHERE e.id_enterprise = 3
   AND s.ts_value > now() - interval '2 days';
```

Real recalc backlog (child sub-meters, `id_parentequipment IS NOT NULL`, never compute OEE and
stay flagged; they are noise):

```sql
SELECT count(*)
  FROM gold.equipment_oee_shift s
  JOIN core.equipments e USING (id_equipment)
 WHERE e.id_enterprise = 3 AND s.recalc_needed AND e.id_parentequipment IS NULL;
```

Mission Control all zeros but hourly fresh: look for the current shift row with
`computed_at IS NULL AND recalc_needed` — the shift rollup is rolling back (2026-09-22).

Timescale jobs, cagg watermarks, retention:

```sql
SELECT job_id, last_run_status, last_successful_finish, total_failures
  FROM timescaledb_information.job_stats ORDER BY job_id;

SELECT user_view_schema || '.' || user_view_name AS cagg,
       _timescaledb_functions.to_timestamp(_timescaledb_functions.cagg_watermark(mat_hypertable_id)) AS watermark
  FROM _timescaledb_catalog.continuous_agg ORDER BY 1;

SELECT * FROM ops.retention_drift;                                   -- want 0 rows
SELECT * FROM ops.retention_run WHERE error IS NOT NULL ORDER BY ran_at DESC LIMIT 20;
```

Connections and what is running:

```sql
SELECT usename, application_name, state, count(*)
  FROM pg_stat_activity WHERE datname = 'packiot_analytics'
 GROUP BY 1, 2, 3 ORDER BY 4 DESC;                                    -- max_connections = 200

SELECT pid, now() - xact_start AS xact_age, state, left(query, 120)
  FROM pg_stat_activity
 WHERE datname = 'packiot_analytics' AND xact_start < now() - interval '5 minutes';
```

An `idle in transaction` session older than a few minutes holding locks blocks the rollups
(seen 2026-09-25); `pg_terminate_backend(pid)` it after confirming what it is.

Slow queries: `pg_stat_statements` (`mean_exec_time`, `calls`) and the `auto_explain` output in
the Postgres log.

Replication dead letters: `SELECT count(*) FROM ops.mirror_replay_dlq;`.

Historian: run `/opt/packiot/historian/historian-integrity-monitor.sh` on the app host, or
check the `historian-integrity-monitor` systemd unit.

## Safe query patterns

- **Bound every hypertable query with a literal time range.** Chunk exclusion happens at plan
  time only for constants. In PL/pgSQL, variables become parameters, the generic plan cannot
  exclude chunks, and a one-month query scans (and locks) all of them; build the statement with
  `EXECUTE format('… %L …', bound)` instead (2026-09-24, 60 s → seconds).
- **Filter by tenant early.** `silver.equipment_values` and `silver.equipment_events` have no
  RLS; always add `id_enterprise = <n>` (or join `core.equipments`).
- **Use equality on NOT NULL columns in joins.** `IS NOT DISTINCT FROM` cannot use a B-tree
  index; a 322k-row merge ran more than 13 minutes because of it.
- **Aggregate over few chunks.** Memory grows with the number of chunks touched: a
  whole-history `GROUP BY` on `silver.equipment_events` (1,599 chunks at the time) built
  thousands of hash nodes and got the backend OOM-killed, resetting every session
  (2026-09-24). For wide ad-hoc aggregates use narrow windows and
  `SET timescaledb.enable_chunkwise_aggregation = off`.
- **`work_mem` is per node, not per query** (64 MB × `hash_mem_multiplier` 2 here), and
  `statement_timeout` does not help when memory runs out first.
- **`min()`/`max()` on an indexed time column with other filters** can make the planner walk
  the index backwards over hundreds of thousands of rows. Materialize the filtered set first.
- **Never bound a historian `live.*` query with `now()`**; see
  [Historian gateway](../components/historian-gateway.md#query-patterns).

## Timescale gotchas

| Gotcha | What happens | What to do |
|---|---|---|
| DML decompression cap | `UPDATE`/`DELETE` over compressed chunks fails "tuple decompression limit exceeded" past 100,000 tuples (the stale-event closer died on every tick until 2026-09-06) | inside the repair transaction: `SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0` |
| Self-join on a compressed hypertable | an `UPDATE … FROM` the same compressed hypertable matched 0 rows (2026-09-27) | materialize the source rows into a temp table first, then update from it |
| `ON CONFLICT` as a diff engine | when every row conflicts, each uniqueness check decompresses a batch (~35 s per month) | pre-filter with `NOT EXISTS` against the key, or skip when counts already match |
| Refresh over dropped raw | refreshing a cagg over a range whose raw is gone **deletes** the buckets | refresh only inside the last 90 days; never `refresh_continuous_aggregate(…, NULL, NULL)` |
| Hierarchical cagg order | `equipment_categorical_1hour` is built on `_1min` | refresh `_1min` first, then `_1hour`, same window |
| Cagg DDL vs ingest | `DROP MATERIALIZED VIEW` on a cagg times out even with jobs paused: every insert fires the invalidation trigger on the source | quiesce `stream-engine` (RabbitMQ buffers), then DDL, then restart |
| Cagg with no refresh policy | frozen watermark; real-time reads re-aggregate all raw until they hit the timeout (CPACK #196) | check the watermark first; every cagg must have a policy |
| Moving a hypertable | `ALTER TABLE … SET SCHEMA` is catalog-only; chunks, caggs and policies follow by OID | take it under `lock_timeout` in its own transaction |
| `merge_chunks` | merges only time-adjacent chunks | group by runs where `range_start = lag(range_end)` (`scripts/consolidate-event-chunks.sh`) |
| `compress_chunk_time_interval` | not visible in `reloptions` | read `_timescaledb_catalog.dimension.compress_interval_length` |
| Sequences after a schema move | `pg_get_serial_sequence()` returns NULL when the sequence is not `OWNED BY` the column; `nextval(NULL)` inserts NULL ids | name the sequence from the column default |

## RLS and definer views

- Tenant policies: `(SELECT is_all_tenant()) OR id_enterprise = (SELECT current_tenant())`
  (gold tables use `id_equipment = ANY (ARRAY(SELECT … FROM equipments WHERE id_enterprise = …))`).
  Keep the helpers wrapped in `(SELECT …)` so they run once per query; a correlated
  `EXISTS` per row made one endpoint 61 s for `readapi_ro` vs 1.9 s as superuser (2026-09-24).
- Under RLS, only **leakproof** operators can be index conditions. B-tree comparisons on one
  type are leakproof; range operators (`<@`, `&&`) and cross-type comparisons (a `date`
  column against a `timestamptz` bound) are not. Add a redundant, same-typed "twin"
  predicate (for example `ts_value_production >= (bound)::date - 1`) or pre-filter in a
  `MATERIALIZED` CTE. Check `pg_operator.oprcode` → `pg_proc.proleakproof`.
- `DROP POLICY` / `CREATE POLICY` take an `ACCESS EXCLUSIVE` lock on a hot table: one policy
  per small transaction with `lock_timeout` and retry, and never inside a transaction that
  already holds read locks (a dry run deadlocked with live traffic).
- **`bi.*` views are definer views owned by `bi_owner`.** Recreating one as `postgres` makes
  `postgres` (BYPASSRLS) the owner and removes the fence. After any `CREATE [OR REPLACE] VIEW`
  in `bi`, run `ALTER VIEW bi.<name> OWNER TO bi_owner` and re-grant `SELECT` to
  `superset_ro`.
- **`CREATE OR REPLACE VIEW` cannot insert or reorder columns** — only append at the end. To add
  a column in the middle, `DROP VIEW` + `CREATE VIEW`, re-grant, re-own. `DROP … CASCADE`
  (including `DROP FOREIGN TABLE … CASCADE` on the gateway) silently drops dependent views:
  list them first with `pg_depend` and recreate them.
- `serving.*` views are `security_invoker = on` and serving functions are `SECURITY INVOKER`,
  so the caller's RLS applies inside them.
- Composite return types (`serving.*` has 30) do not follow a column widening: `ALTER TYPE`
  them too.

## Repair and recompute safely

The pattern used for every 2026-09 data repair:

1. **Scope.** Count exactly what will change, per tenant, with the true key
   (`(id_equipment, ts_value)`, `(id_equipment, ts_event)`), never a non-unique id such as
   `id_equipment_event` (shared between CPACK and its sandbox twin; 2026-09-21 cross-tenant write).
2. **Back up** the affected rows:

    ```sql
    CREATE TABLE ops._bkp_<what>_<yyyymmdd> AS
    SELECT * FROM silver.equipment_events
     WHERE id_equipment = ANY ('{53,54}') AND ts_event >= '2026-09-01' AND ts_event < '2026-09-08';
    ```

3. **Dry run** in a transaction and read the counts:

    ```sql
    BEGIN;
    SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0;  -- if compressed
    UPDATE … ;            -- or DELETE / INSERT … ON CONFLICT
    SELECT count(*) …;    -- verify the after-state
    ROLLBACK;
    ```

    An `INSERT` that "succeeds" can still insert 0 rows (an empty merge key once turned the guard
    into `WHERE NOT EXISTS (… WHERE true)`); always read the row counts.
4. **Apply** the same statement with `COMMIT`, in daily windows for large ranges.
5. **Re-derive downstream.** Raw change → refresh the caggs over that window
   (`_1min` then `_1hour`) → set `recalc_needed = true` on the affected gold rows (hourly, shift,
   daily, PO runtimes) so `stream-engine` recomputes them on its next ticks. Do not recompute
   gold by hand in SQL. For bulk history the 2026-09-28 runner rendered the real
   `stream-engine` backfill statements with a date filter, one transaction per day and the same
   advisory key as the backfill (~100 s per day for one line, ~10 min per day for all 40 lines).
   CPACK silver starts at its F3 cutover (2026-07-23); older CPACK gold cannot be re-derived from
   raw.
6. **Check every consumer** of what you changed (DQ scanners, alerts, `serving.*`, `bi.*`),
   not only the table: the 2026-09-24 history backfill broke the rollup's DQ side-read
   because legacy months had NULL counters.
7. **Keep the backup** until the user confirms, then drop it.

Rollup-side changes (fixing a formula) are deployed in `stream-engine` and applied to history by
re-flagging, as above. See
[stream-engine rollup internals](../components/stream-engine-rollup-internals.md).

## Backups

| Layer | What | Where / schedule | Retention |
|---|---|---|---|
| Row backups before repairs | `ops._bkp_*` tables | in the analytics DB, by hand | until dropped by hand |
| Nightly logical dump (DB box) | `pg_dump --format=custom` (owners + grants kept) → gzip → S3, plus cluster roles and each DB's `ALTER DATABASE … SET` settings | `terraform/staging/scripts/backup-db.sh`, `packiot-db-backup.timer` 02:00 UTC; DBs `packiot packiot_analytics superset` (`/etc/packiot/backup.env`); bucket `packiot-staging-db-backups-<account>` | 14 daily, 4 weekly, 3 monthly; S3 lifecycle hard cap 90 days |
| Nightly historian backup (app box) | hist-gateway catalog DB `packiot_historian` dump (same script) | `backup-historian.sh`, `packiot-historian-backup.timer` 04:30 UTC; interim target `s3://packiot-staging-historian-<account>/_backup/` | 14 daily, 4 weekly, 3 monthly |
| EBS snapshots | before risky operations, by hand (for example `snap-0f535e3c42d4e2ae0` before the 2026-09-23 resize) | AWS console / CLI | manual |
| AWS Backup plan | daily snapshots, 7-day retention | app host (covers the hist-gateway volume); DB host selection is in `snapshots.tf` but **not applied** | 7 days |
| Historian archive | Parquet on S3 (the only copy of raw data older than 90 days) | versioning **off**; no copy until `app_backup_ops` (backups.tf) is applied and the app box runs `MODE=target` | the archive itself |

Verified 2026-09-30 (restore drills in isolated `--network none` containers): analytics
0 `pg_restore` errors, RLS policies / forced-RLS tables / non-superuser view owners identical to
live, ~15 min to restore on one CPU; historian catalog 0 errors, all state tables byte-identical.
Restore = `docs/runbooks/emergency-db-restore.md` (GitHub button
"EMERGENCY – restore database" or `restore-db.sh` by hand). **A plain `pg_dump` does not carry
`ALTER DATABASE … SET search_path`** — `backup-db.sh` saves it to `<db>/db-settings/` and
`restore-db.sh` re-applies it.

`ops._bkp_*` tables present on 2026-09-28 (about 280 MB together): `_bkp_closer_rebind_20260928`,
`_bkp_po_header_reflag_20260928`, `_bkp_po_runtime_gross0_20260928`,
`_bkp_l5_injector_20260925` (83 MB), `_bkp_sbx_l5_injector_20260927` (101 MB),
`_bkp_texa_injector_20260927`, `_bkp_spike_guard_clamp_20260927`,
`_bkp_june_event_fragments(_sbx)`, `_bkp_orphan_open_stops`, `_bkp_closer_stop_repair`,
`_bkp_hour_linelead_repair`, and small tenant-config backups. Restore a backup by deleting the
repaired rows in the same scope and re-inserting from the `_bkp_` table in one transaction.

Schema changes are code: `db/migrations/<task>/01-up.sql` with a paired `rollback.sql`.
For anything a live consumer reads, use expand → repoint readers → contract, each its own
deploy.

## Retention and history questions

- "How long do we keep X?" → `SELECT relation, keep, cold_copy FROM ops.retention_policy`.
- "Why is a 2024 chart empty?" → raw is 90 days hot; gold/POs/events are long only for tenants
  whose history was backfilled (CPACK). Deep raw lives in the historian
  ([Historian](../subsystems/historian.md)).
- read-api reports truncation with `X-Data-Hot-Floor` / `Warning: 299` headers instead of
  silently returning short answers.

## Integer-as-time traps (shift SQL)

- `core.shift_hours.begin_time` / `end_time` are **integer seconds from `week_begin`**, not
  clock times.
- `core.{enterprises,sites,areas}.week_begin` is a **signed** offset from Monday 00:00; CPACK's
  `-3000` means the week starts Sunday 23:10.
- `core.shifts.begin_time` / `end_time` are clock times.
- Shift and hour rows are UTC `timestamptz`; factory time is America/Sao_Paulo. Read the
  `COMMENT ON COLUMN` (`\d+ core.shift_hours`) before touching shift math.

## Dropping things

Never drop an object because it "looks empty": a table can carry a function's return type, a
flag-gated writer (bronze), or a Superset dataset. Before any `DROP`: grep every service for
readers and writers under both the bare and the qualified name, check for an enable flag,
watch `pg_stat_user_tables` write counters for longer than the slowest job tick, then
`DROP … RESTRICT` in a reversible migration.

## Related

- [Analytics DB](../subsystems/analytics-db.md) · [Analytics DB schemas](../components/analytics-db-schemas.md)
- [Timescale jobs & retention](../components/timescale-jobs-and-retention.md)
- [Historian gateway](../components/historian-gateway.md) · [Superset](../components/superset.md)
- [Database reference](../reference/database-reference.md)
- [Tenancy & security](../architecture/tenancy-and-security.md)
