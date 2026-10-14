---
title: Add a migration
layer: guide
owner_area: analytics-db
last_verified: 2026-10-13
---
# Add a migration

> **Build & operate · how-to.** Change the schema of the analytics DB (`packiot_analytics`) with a
> reviewed, reversible migration, apply it on staging by hand, and prove it worked. For engineers.
> Up: [Build & operate](../index.md)

**Goal:** a schema change that lives in `db/migrations/`, is applied and verified on staging
**before** its PR merges, and can be rolled back.

!!! danger "Nothing applies `db/migrations/` for you"
    There is **no migration runner** for the analytics DB on staging. `Deploy to Staging` does not
    run these files (see [Deploy → what the deploy does not do](../operate/deploy.md#what-the-deploy-does-not-do)).
    You apply each one by hand, and you merge only after it is applied, so that `staging` in git matches
    the live schema. The production promotion copies staging's **live** catalog, so a hand edit that is
    not in a migration ships to production unreviewed.

## Which kind of migration?

| You are changing | Where | How it is applied |
|---|---|---|
| Tables edge-api owns (its knex ledger `public.knex_migrations`) | `edge-api/migrations/<timestamp>_<name>.ts` (submodule) | **Automatically** at every staging deploy: the one-shot `db-migrate` service runs `knex migrate:latest` (`edge-api/Dockerfile`, target `migrate`; `compose.staging.yml` `db-migrate`) |
| Everything else in `packiot_analytics`: `core`, `silver`, `gold`, `serving`, `config`, `ops`, roles, RLS, Timescale jobs | `db/migrations/<folder>/` (this repo) | **By hand**, this page |

The rest of this page is about `db/migrations/`.

## Before you start

- A local dev stack with the seed: `make dev` (see [Local development](local-development.md)). The dev
  seed runs the same PostgreSQL 15.17 and TimescaleDB 2.27.0 as staging.
- Read the [DBA guide](../operate/dba-guide.md), especially
  [Timescale gotchas](../operate/dba-guide.md#timescale-gotchas) and
  [RLS and definer views](../operate/dba-guide.md#rls-and-definer-views).
- AWS access that can open an SSM session on the staging DB host (see
  [Runbooks → SSM access](../operate/runbooks.md#ssm-access-to-a-host)).

## Steps

### 1. Create the folder

New migrations use one folder named `t-<topic>` (for example `t-adr0062-p1-po-number-expand`) with
three files:

```text
db/migrations/t-<topic>/
  01-up.sql      the change
  verify.sql     read-only checks; one line per check
  rollback.sql   restores the previous state
```

Older folders use other shapes (`tNNN-…`, `NN_name.up.sql`/`.down.sql`); copy the current shape, not
those. A recent example to copy: `db/migrations/t-adr0062-p1-po-number-expand/`.

### 2. Write `01-up.sql`

The conventions every recent `01-up.sql` follows:

```sql
-- t-<topic> — what changes and why (the ADR or incident it comes from).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS core.example (...);         -- idempotent: IF [NOT] EXISTS, CREATE OR REPLACE
COMMENT ON TABLE core.example IS 'what it is for';     -- every new object gets a comment

COMMIT;
```

- **Idempotent.** Running it twice must be harmless (`IF NOT EXISTS`, `CREATE OR REPLACE`,
  `ON CONFLICT DO NOTHING`).
- **`lock_timeout`** so a busy table makes the migration fail fast instead of queueing every reader
  behind it.
- **Key data fixes by business attributes, not surrogate ids.** Ids differ between staging,
  production and the sandbox twin (the PO-number fix in `t-adr0062-p1-po-number-expand` matches on
  the PO's own number for this reason).
- **No new PackML wording.** The `packml ratchet` check fails on new `packml` references
  ([ADR-0061](../../reference/adr-index.md)).

### 3. Write `verify.sql`

Most `verify.sql` files print one row per check: a label that states the expected value, then the
actual value. You read the output and compare.

```sql
-- verify for t-<topic>. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
SELECT 'V1 rows without a number: 0', count(*) FROM core.production_orders WHERE id_order_text IS NULL;
SELECT 'V2 trigger present: t', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'production_orders_po_number');
```

If a check must write (a negative test, for example "this insert must fail"), do it inside
`BEGIN; … ROLLBACK;`, as `t-po-runtime-exclusion-not-null-fk/verify.sql` does. Heavy checks over
hypertables set a session `statement_timeout` and a literal time window.

### 4. Write `rollback.sql`

It restores the exact previous state (old function bodies, dropped constraints), in one transaction
with `lock_timeout`. If part of the change is deliberately kept on rollback (for example backfilled
data that is strictly better), say so in the header.

### 5. If you add a table: classify it for the dev seed

The dev seed is fail-closed: every base table of `packiot_analytics` must be listed in
`dev/seed/manifest.yml`, and every text/json/array column of a copied table must be classified in
`dev/seed/classification.yml`. Otherwise `dev/seed/validate.py` fails and the weekly seed build
(`.github/workflows/dev-seed-build.yml`, Sundays 05:00 UTC, checked against the **live** staging
schema) stops.

| New table is… | Manifest mode |
|---|---|
| plumbing, audit or backup (`ops.*`, `ops._bkp_*`, `ops._fix_*`) | `{mode: schema_only}` with a comment saying why |
| tenant data | `{mode: rows, where: "id_enterprise = :tenant …"}`, and classify its text columns |
| global reference data | `{mode: full}`, and classify its text columns |
| secrets or keys (never copied) | `{mode: replace}` plus a generator `dev/seed/generators/<schema>.<table>.sql` |

Add the table's columns to the schema snapshot `dev/seed/schema-columns.tsv` (tab-separated:
schema, table, kind, column, data_type), then run:

```bash
python3 dev/seed/validate.py
```

You should see `OK: <n> tables (<m> copied), <k> classified text columns`. See
[`dev/seed/README.md`](https://github.com/packiot/packiot-stack-alpha/blob/staging/dev/seed/README.md).

### 6. Test it on the dev seed

```bash
make dev
for f in 01-up.sql verify.sql rollback.sql 01-up.sql 01-up.sql verify.sql; do
  echo "== $f"
  docker exec -i packiot-dev-postgres-1 psql -U postgres -d packiot_analytics -v ON_ERROR_STOP=1 \
    < db/migrations/t-<topic>/$f || break
done
```

That runs up → verify → rollback → up twice (idempotency) → verify. Every verify line must show the
expected value. Then run the dev slice that reads what you changed (`make dev SVC="…"` and
`make dev-smoke SVC="…"`); the PR's `dev slices gate` check does the same.

!!! warning "Dev passing is not enough for DML on compressed chunks"
    The dev seed did not reproduce the compressed-chunk bug in the rules below (2026-10-09). If your
    migration updates or deletes hypertable rows, the read-back on staging is the real test.

### 7. Open the PR

Open it into `staging` ([Branches and merging](branches-and-merging.md)). Say in the body that the
migration still has to be applied, and how long `verify.sql` takes on staging if it is heavy.

### 8. Dry-run on staging

Open a shell on the staging DB host (instance tag `packiot-staging-db`):

```bash
aws ssm start-session --region us-east-1 --target "$DB"
sudo -i                                  # ssm-user is not in the docker group
```

The host has no checkout of your branch. Move the file as base64 (this is what
`scripts/ssm-psql.sh` encodes): on your laptop `base64 -w0 db/migrations/t-<topic>/01-up.sql`, then on
the host:

```bash
echo '<paste>' | base64 -d > /tmp/01-up.sql
sed 's/^COMMIT;$/ROLLBACK;/' /tmp/01-up.sql > /tmp/01-up.dry.sql      # same change, never committed
docker exec -i timescaledb psql -U postgres -d packiot_analytics -v ON_ERROR_STOP=1 < /tmp/01-up.dry.sql
```

You should see every statement succeed and a final `ROLLBACK`. A `lock_timeout` error means a busy
table: retry at a quiet time, do not raise the timeout.

### 9. Apply and verify

```bash
docker exec -i timescaledb psql -U postgres -d packiot_analytics -v ON_ERROR_STOP=1 < /tmp/01-up.sql
docker exec -i timescaledb psql -U postgres -d packiot_analytics -v ON_ERROR_STOP=1 < /tmp/verify.sql
```

Paste the verify output into the PR, then merge.

### 10. After the merge

If the change touches what a service reads or writes, check that service on staging after its deploy
(logs, the endpoint, the dashboard). If it changes a `serving.*` function or a dataset, check the
[API reference](../../reference/api/index.md) and the read-api goldens.

## TimescaleDB rules (from real incidents)

| Rule | Why |
|---|---|
| **Never call `decompress_chunk`** on the shared staging DB. Insert or update row-wise instead, one day per transaction | `decompress_chunk` holds an `ACCESS EXCLUSIVE` lock on the chunk for minutes. On 2026-09-30 a backfill doing this made CPACK's operator API time out (500s) |
| **UPDATE/DELETE on hypertables: literal timestamp bounds** (`ts_value < '2026-09-27'`), never `date '2026-09-26' + 1` or `now() - …` | On compressed chunks a stable bound silently matches **0 rows** (TimescaleDB 2.27, found 2026-10-09: `UPDATE 0` vs `UPDATE 7981` with a literal). SELECT with the same bound works, so only a read-back exposes it |
| **Read back** every data change and count it; never trust the statement's own row count alone | The same incident: snapshots filled, the updates did nothing |
| More than 100,000 compressed tuples in one statement: `SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0` | Otherwise "tuple decompression limit exceeded" ([DBA guide](../operate/dba-guide.md#timescale-gotchas)) |
| Refresh continuous aggregates in dependency order: `silver.equipment_categorical_1min` before `…_1hour`, same window, inside the last 90 days only; never `refresh_continuous_aggregate(…, NULL, NULL)` | The hour cagg is built on the minute cagg; refreshing over dropped raw **deletes** buckets |
| Re-flag gold (`recalc_needed = true`) only for the last 7 days | Re-flagging 30-day-old shifts stalled the shift rollup for every tenant for 22 minutes (2026-10-01) |
| A new hypertable or time-series table gets a row in `ops.retention_policy`, then `CALL ops.apply_retention()` | Retention is driven from that catalog, never set by hand ([retention catalog](../../understand/components/timescale-jobs-and-retention.md#the-retention-catalog)) |
| DDL on a continuous aggregate (`DROP MATERIALIZED VIEW`): quiesce `stream-engine` first | Every insert fires the invalidation trigger; the DDL times out otherwise |
| Recreating a `bi.*` view: `ALTER VIEW … OWNER TO bi_owner` and re-grant | Created as `postgres` it bypasses RLS ([DBA guide](../operate/dba-guide.md#rls-and-definer-views)) |

Data **repairs** (changing existing rows, not schema) are scripts in `scripts/ops/` with `ops._fix_*`
snapshots, not migrations: see [Branches and merging → data repairs](branches-and-merging.md#data-repairs).

## If it went wrong

| Symptom | Cause | Fix |
|---|---|---|
| `validate.py`: table not listed / column not classified | New table or column not in the seed manifest | Step 5 |
| `lock_timeout` during apply | A long query or job holds the table | Wait and retry; check `pg_stat_activity` ([Runbooks → Check DB health](../operate/runbooks.md#check-db-health)) |
| A verify line shows the wrong value after apply | The change did not do what you expected | Run `rollback.sql`, verify the old state, fix the migration in the PR |
| `UPDATE 0` where rows were expected | Stable time bound on compressed chunks | Use literal timestamps; read back |
| A service fails after apply | It depends on the old shape | `rollback.sql`, then ship the service change and the migration together |

## Next

- [Database reference](../../reference/database-reference.md) and
  [Analytics DB schemas](../../understand/components/analytics-db-schemas.md) — where things belong.
- [Backups & restore](../operate/backups-and-restore.md) — what to do if a change goes badly wrong.
- [Add a service](add-a-service.md) — if the migration comes with a new service.

Decision record: [ADR-0061](../../adr/0061-remove-packml-from-the-cloud.md).
