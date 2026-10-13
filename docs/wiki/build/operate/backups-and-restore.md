---
title: Backups & restore
layer: guide
owner_area: analytics-db
last_verified: 2026-10-13
---
# Backups & restore

> **Build & operate · how-to.** What is backed up on staging, where it lands, how long it is kept,
> and how to prove a backup restores (drill) or put one back (emergency restore). For engineers and
> on call. Up: [Build & operate](../index.md)

**Goal:** know which copy of which database exists right now, and restore one safely: into a side
database first, verified, and swapped in only when it passes.

!!! note "Staging only"
    Everything on this page is the **staging** new stack (us-east-1). The
    production new stack has a backup bucket and an AWS Backup plan in Terraform, but no nightly
    `pg_dump` job is wired there (see [Production](#production)). The legacy production database
    (`packiot40`/tsp12) is not backed up by anything in this repository.

## What is backed up

```text
 DB box (packiot-staging-db)                    app box (packiot-staging-app)
 ┌──────────────────────────────┐               ┌──────────────────────────────────┐
 │ timescaledb container        │               │ hist-gateway container           │
 │  packiot_analytics  packiot  │               │  packiot_historian (catalog DB)  │
 │  superset   + cluster roles  │               │                                  │
 └──────────────┬───────────────┘               └───────────────┬──────────────────┘
   02:00 UTC    │ backup-db.sh                    04:30 UTC     │ backup-historian.sh
   (timer)      ▼                                 (timer)       ▼   (reuses backup-db.sh)
 s3://packiot-staging-db-backups-<acct>/        s3://packiot-staging-historian-<acct>/_backup/
                                                 (interim location, see "Known gaps")
 03:00 UTC  AWS Backup: EBS snapshots of BOTH EC2s → vault packiot-staging-ec2-snapshots (7 days)
```

| What | How | When | Where | Kept |
|---|---|---|---|---|
| `packiot_analytics` (the live system of record) | `pg_dump --format=custom`, gzip, owners and grants **kept** | 02:00 UTC daily (`packiot-db-backup.timer`, ±5 min jitter) | `s3://packiot-staging-db-backups-<acct>/packiot_analytics/` | 14 daily, 4 weekly (Sundays), 3 monthly (1st) |
| `superset` (Superset metadata) | same | same run | `…/superset/` | same |
| `packiot` (frozen legacy copy on the DB box) | same | same run | bucket root: `daily/ weekly/ monthly/ latest` | same |
| Cluster roles of the DB box | `pg_dumpall --roles-only --no-role-passwords` | same run | `…/globals/daily/`, `…/globals/latest.sql.gz` | 14 daily |
| Database-level settings (`ALTER DATABASE … SET search_path`, …) | SQL file per DB (not part of `pg_dump`) | same run | `…/<db>/db-settings/{YYYY-MM-DD,latest}.sql` | 14 daily |
| `packiot_historian` (hist-gateway catalog: union boundaries, tenant allow-list, watermarks, views) | `backup-db.sh` run by `backup-historian.sh` | 04:30 UTC daily (`packiot-historian-backup.timer`) | `s3://packiot-staging-historian-<acct>/_backup/packiot_historian/` (+ its own `globals/`) | 14 daily, 4 weekly, 3 monthly |
| Both EC2 instances (all attached EBS volumes, so also Docker volumes such as `mosquitto-data`) | AWS Backup plan `packiot-staging-ec2-daily` | 03:00 UTC daily | vault `packiot-staging-ec2-snapshots` | 7 days |
| Rows a data repair changed | `ops._bkp_*` / `ops._fix_*` tables in the analytics DB | by the repair script | inside `packiot_analytics` | until `scripts/ops/ops-backup-retention.sh` drops them (dated names older than 30 days; run by hand) |

Retention is enforced by the backup script's own prune step. On top of that the backup bucket
has a lifecycle cap: every object expires after 90 days, overwritten or deleted versions after
30 days (bucket **versioning is on**, so a bad prune or an overwrite of `latest` is recoverable
for 30 days).

Each dump is uploaded once per tier it belongs to, plus a stable `latest` key, so a restore does
not need to know the date. Dumps smaller than a floor (1 MB; superset 100 KB; historian catalog
10 KB) are treated as failed and not uploaded.

Sizes on 2026-10-13: `packiot_analytics` ~1.36 GB gzipped (about 18 GB restored), legacy
`packiot` ~82 MB, `superset` ~0.7 MB, historian catalog ~13 KB.

## Before you start

- AWS credentials for the staging account (read is enough to look; restoring by hand needs SSM
  Session Manager access to the hosts, see [Runbooks → SSM access](runbooks.md#ssm-access-to-a-host)).
- For the GitHub button: permission to run workflows in `packiot/packiot-stack-alpha`.
- Know which database you mean: **analytics** = `packiot_analytics`, **historian** =
  `packiot_historian`, **superset** = `superset`. The legacy `packiot` copy has no button; it
  restores only by hand.

## Check the backups are fresh

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
B=packiot-staging-db-backups-$ACCT
aws s3 ls s3://$B/packiot_analytics/daily/ | tail -3
aws s3 ls s3://$B/superset/daily/ | tail -3
aws s3 ls s3://packiot-staging-historian-$ACCT/_backup/packiot_historian/daily/ | tail -3
```

**What you should see:** a file named after today's UTC date (`2026-10-13.dump.gz`) in each.
`aws s3 ls` prints times in your local time zone, so a 02:10 UTC upload shows as 23:10 the day
before in BRT.

On the hosts the job logs are in the journal:

```bash
journalctl -u packiot-db-backup --since today          # DB box
journalctl -u packiot-historian-backup --since today   # app box
```

A good run ends with `All backups complete.` (historian: `Historian backup complete.`).

Prometheus alerts watch the same thing through the metrics each run writes to
`/var/lib/packiot-backup/metrics` (collected by `alloy-db` on the DB box, `node-exporter` on the
app box). Rules in `monitoring/prometheus/rules.yml`:

| Alert | Fires when |
|---|---|
| `BackupStale` (critical) | no successful backup of a DB for more than 26 h |
| `BackupShrank` | a dump is under half its 8-day maximum (wrong DB, dropped data, truncated dump) |
| `BackupMetricsMissing` | no metric at all for one of `packiot_analytics`, `superset`, `packiot_historian`, `historian_parquet` for 30 h |
| `BackupMirrorIncomplete` | historian Parquet objects are missing from the mirror |

`BackupMetricsMissing{db="historian_parquet"}` is **expected to fire today**: it is the honest
signal that the historian Parquet has no copy (see [Known gaps](#known-gaps)).

## Prove a backup restores (drill)

A drill restores into a side database `<db>__restoring`, runs the verify gate, and drops it. It
never touches the live database. Run one after changing the backup or restore scripts, and
monthly. The last recorded drills ran on 2026-09-30.

### With the GitHub button

1. GitHub → Actions → **"EMERGENCY – restore database (staging)"** → *Run workflow*, or:

    ```bash
    gh workflow run emergency-db-restore.yml -R packiot/packiot-stack-alpha --ref staging \
      -f database=analytics -f backup=latest -f mode=drill
    ```

2. Watch it: `gh run watch <run-id> -R packiot/packiot-stack-alpha`.

**What you should see:** the job summary table and a line
`SUMMARY: mode=drill … errors=0 gate=PASS result=DRILL_PASSED side_db=dropped`. `backup_age`
in that line is your RPO, `total` your restore time.

The job runs on the self-hosted runner on the app box. The historian is restored locally;
analytics and superset are driven on the DB box through SSM (`ssm:SendCommand`, granted to the
app role by `aws_iam_role_policy.app_backup_ops` in `terraform/staging/backups.tf`).

### By hand (DB box)

```bash
aws ssm start-session --target <instance-id of Name=packiot-staging-db>
sudo -i
set -a; . /etc/packiot/backup.env; set +a
/opt/packiot/scripts/restore-db.sh --db packiot_analytics latest                       # dry run
/opt/packiot/scripts/restore-db.sh --db packiot_analytics latest --yes-i-am-sure --drill
```

The first command changes nothing: it prints the backup it would use, its age, and the free disk
it needs (about 20× the gzipped size, on `/var/lib/packiot-backup`). Run `restore-db.sh` with no
key to list the last five backups of each tier.

## What the restore does (and the gate that protects you)

`terraform/staging/scripts/restore-db.sh` is the single restore path. The button and the manual
commands both call it.

1. Downloads the dump to disk (`/var/lib/packiot-backup`, not `/tmp`: on the DB box `/tmp` is
   RAM).
2. Creates `<db>__restoring`. If the dump contains TimescaleDB it wraps the restore in
   `timescaledb_pre_restore()` / `timescaledb_post_restore()`.
3. Applies the cluster roles file first ("already exists" is expected on a live cluster).
4. `pg_restore` in one stream, counting every error.
5. Copies the database-level settings onto the side DB: from the live DB if it exists, otherwise
   from the saved `db-settings/latest.sql`. Without this every bare-name query breaks
   (`search_path`).
6. `ANALYZE`.
7. **Verify gate.** It refuses to go on if:
    - `pg_restore` reported more errors than `MAX_RESTORE_ERRORS` (default 0);
    - the catalog differs from the live DB: RLS policies, RLS-enabled and forced-RLS tables,
      views owned by a non-superuser (the tenant fence), extensions, DB settings, object counts
      per schema, hypertables, continuous aggregates, Timescale jobs;
    - a key table is empty in the restore but has rows live (analytics: `core.enterprises`,
      `core.equipments`, `core.production_orders`, `identity.users`,
      `gold.equipment_oee_shift`, …).
    Row counts are printed side by side but not gated: the live DB has moved on since the dump.
8. Depending on the mode: `--drill` drops the side DB; `--no-swap` leaves it for inspection;
   the default (and `--swap-only` later) **renames** live → `<db>__pre_restore_<ts>` (or the
   `--old-name` you give) with connections disabled, and the side DB → `<db>`.

!!! danger "Why owners and grants must be in the dump"
    Until 2026-09-29 dumps were taken with `--no-owner --no-privileges`. Restored that way, every
    object is owned by the superuser, and `packiot_analytics`' RLS definer views owned by a
    superuser **bypass row-level security**: the tenant fence is silently gone. Dumps now keep
    owners and grants, and the catalog gate (non-superuser-owned views, forced-RLS tables,
    policies must equal live) refuses to swap in such a restore. Do not restore a pre-2026-09-29
    dump with `CATALOG_GATE=report` unless you re-own the views yourself.

## Emergency restore (swap a backup into live)

Use this only when a database is gone, corrupted or mass-overwritten and cannot be fixed forward.

| Situation | Do |
|---|---|
| A few rows are wrong | **Don't swap.** `--no-swap` restore, copy the rows out of `<db>__restoring` |
| A whole DB is damaged (bad migration, `DROP`, runaway `DELETE`) | Emergency restore below |
| The DB box's volume or host is dead | Restore the instance from its AWS Backup snapshot first (the restore script needs a running Postgres), then decide whether the snapshot is enough |

### Steps (GitHub button)

1. Pick the backup: `latest`, a date `YYYY-MM-DD` (= `daily/<date>.dump.gz`), or
   `daily|weekly|monthly/<name>.dump.gz`. Remember anything written after it is lost.
2. Run the workflow from the `staging` branch with `mode=restore` and
   `confirm` = exactly `RESTORE <database> ON STAGING` (for example `RESTORE analytics ON STAGING`):

    ```bash
    gh workflow run emergency-db-restore.yml -R packiot/packiot-stack-alpha --ref staging \
      -f database=analytics -f backup=latest -f mode=restore \
      -f confirm="RESTORE analytics ON STAGING"
    ```

    If the live DB itself is damaged (so its catalog *should* differ), add `-f catalog_gate=report`.
3. The workflow then:
    1. checks the `restore-db.sh` installed on the target host is byte-identical to the commit's
       (if not: re-run `install-backup-tooling.sh` on the DB box or
       `install-historian-backup.sh` on the app box);
    2. restores and verifies into `<db>__restoring` (`--no-swap`);
    3. stops the writers that would race the swap: analytics → `stream-engine`,
       `analytics-sync`, `legacy-replicator`, `legacy-replicator-sbx` (their input waits in
       RabbitMQ); superset → `superset`, `superset-worker`; historian → the append, integrity and
       backup timers;
    4. swaps (`--swap-only`), keeping the old DB as `<db>_pre_emergency_<UTC yyyymmddHHMM>`, and
       restarts the Postgres container so TimescaleDB and pg_cron workers bind to the new DB;
    5. starts the writers again, even if a step failed.

    APIs (edge-api, read-api, operator-gateway, barcode) are not stopped: they error for the few
    seconds of the swap and reconnect.

### Steps (by hand, when GitHub or the app box is down)

```bash
# DB box: analytics / superset / legacy packiot
set -a; . /etc/packiot/backup.env; set +a
/opt/packiot/scripts/restore-db.sh --db packiot_analytics latest --yes-i-am-sure --no-swap
#   app box: docker stop stream-engine analytics-sync legacy-replicator legacy-replicator-sbx
/opt/packiot/scripts/restore-db.sh --db packiot_analytics --swap-only --yes-i-am-sure \
    --old-name packiot_analytics_pre_emergency_$(date -u +%Y%m%d%H%M) --restart-container
#   app box: docker start stream-engine analytics-sync legacy-replicator legacy-replicator-sbx

# app box: historian catalog
set -a; . /etc/packiot/historian-backup.env; set +a
POSTGRES_CONTAINER=$GATEWAY_CONTAINER \
GLOBALS_KEY=${BACKUP_KEY_PREFIX}packiot_historian/globals/latest.sql.gz \
  /opt/packiot/scripts/restore-db.sh --db packiot_historian latest --yes-i-am-sure --no-swap
```

`--swap-only` refuses to run unless `<db>__restoring` carries the "verified by restore-db.sh"
marker that only a passed gate writes.

## Check it worked

- The run (or the script) ends with `result=SWAPPED displaced=<old name>`.
- The script prints a **post-restore checklist**; do all of it:
    1. Roles created from the globals file have **no passwords** (they are never stored in S3).
       If logins fail, set them again (`ALTER ROLE … PASSWORD`) from Secrets Manager or
       `/opt/packiot/.env` on the app box.
    2. Timescale DBs: `SELECT * FROM timescaledb_information.job_stats;` shows jobs running.
    3. stream-engine, edge-api and read-api logs show no reconnection errors.
- Data is flowing again: [Runbooks → Verify freshness](runbooks.md#verify-freshness).
- When you are sure, drop the displaced copy (it costs a whole DB of disk):
  `DROP DATABASE "<db>_pre_emergency_…";`

## If it went wrong

| Symptom | Cause | Fix |
|---|---|---|
| `GATE: … CATALOG MISMATCH` | The restore differs from live (missing objects, RLS/ownership lost) | Read the diff in `/var/lib/packiot-backup/restore-<db>.catalog.diff`. If live is the damaged side, re-run with `catalog_gate=report` |
| `GATE: N restore errors` | `pg_restore` errors | Full list in `/var/lib/packiot-backup/restore-<db>.err`; the side DB is left for inspection |
| `restore-db.sh on the target differs from this commit` | Installed script is older/newer than the workflow's commit | Re-run the installer on that host |
| `ssm:SendCommand to the DB box was refused` | The app role lost `app_backup_ops` | Use the manual commands; fix the Terraform |
| `could not rename <db>; nothing swapped, live DB re-opened` | A connection would not die within the rename's wait | Stop the remaining writers and retry `--swap-only` |
| `ERROR: … KB free < … needed` | Not enough disk for ~20× the gzipped dump | Free disk on the DB box before retrying |
| ANALYZE dies on a statement timeout | Old script: staging sets `statement_timeout=120s` | Fixed in the script (`statement_timeout=0`); re-install it |

To **undo a swap**, run the ROLLBACK block the script printed (it renames the restored DB to
`<db>__rolled_back` and the displaced one back), then `docker restart timescaledb` (historian:
`hist-gateway`).

## Production

| Item | State (verified 2026-10-13) |
|---|---|
| `terraform/production/backups.tf` | bucket `packiot-production-db-backups-<acct>`, 180-day lifecycle, versioning **disabled**. It currently holds seed-transfer files, no nightly dumps |
| `terraform/production/snapshots.tf` + `database.tf` | AWS Backup daily at 04:00 UTC, 30-day retention (`ec2_backup_retention_days`), app and DB EC2 |
| Nightly `pg_dump` on production | **Not wired**: no backup script or timer is installed by the production Terraform |
| Legacy production (`packiot40`/tsp12, Hasura, oeecloud) | Not managed from this repository |

## Known gaps

- **Historian Parquet (the cold store) has no copy.** It is the only home of raw data older than
  the 90-day hot window. The grant it needs (`app_backup_ops`) and versioning on the historian
  bucket are applied, but the app box still runs `backup-historian.sh` in its **interim**
  configuration: the catalog dump goes to the historian bucket's `_backup/` prefix and there is
  no Parquet mirror (`s3://packiot-staging-db-backups-<acct>/historian-parquet/` is empty).
  Switching needs `MODE=target BACKUP_BUCKET=packiot-staging-db-backups-<acct>
  HISTORIAN_BUCKET=… install-historian-backup.sh` on the app box. Versioning protects against
  overwrites and deletes in the meantime, for 30 days.
- **No point-in-time recovery.** There is no WAL archiving: the recovery point is the last
  nightly dump (up to 24 h). The pgBackRest proposal in `docs/guides/backup-restore-runbook.md`
  was not implemented.
- **One account, one region.** No copy survives an account compromise or a regional S3 outage.
- **Drills are manual.** Nothing schedules the drill; the last ones ran on 2026-09-30.

!!! warning "Unverified"
    Whether `BackupStale` and friends page anyone depends on the Alertmanager receiver
    configuration on the staging host (Slack webhook), which this page did not check.

## Next

- [DBA guide](dba-guide.md) — safe queries, repairs and the `ops._bkp_*` row backups.
- [Timescale jobs and retention](../../understand/components/timescale-jobs-and-retention.md) —
  what the database itself deletes, and when.
- [Historian](../../understand/subsystems/historian.md) — what the Parquet cold store holds.
- [Analytics DB](../../understand/subsystems/analytics-db.md) · [Terraform](../../understand/components/terraform.md)
- [Rotate secrets](secrets-rotation.md) — the passwords a restore does not bring back.

## Source map

| Path | What's there |
|---|---|
| `terraform/staging/scripts/backup-db.sh` | nightly dump, tiers, prune, roles, db-settings, metrics |
| `terraform/staging/scripts/restore-db.sh` | side-DB restore, verify gate, swap, rollback text |
| `terraform/staging/scripts/backup-historian.sh` | historian catalog dump + optional Parquet mirror |
| `terraform/staging/scripts/packiot-{db,historian}-backup.{service,timer}` | systemd schedule (02:00 / 04:30 UTC) |
| `terraform/staging/scripts/install-backup-tooling.sh`, `install-historian-backup.sh` | one-shot installers; write `/etc/packiot/backup.env`, `/etc/packiot/historian-backup.env` |
| `terraform/staging/backups.tf` | backup bucket, versioning, lifecycle, DB-box writer policy, `app_backup_ops` |
| `terraform/staging/snapshots.tf` | AWS Backup vault, plan and selections (app + DB EC2) |
| `terraform/staging/historian.tf` | historian bucket (versioning, noncurrent expiry) |
| `.github/workflows/emergency-db-restore.yml` | the GitHub button |
| `docs/runbooks/emergency-db-restore.md` | the original emergency runbook (RPO/RTO measured 2026-09-30) |
| `monitoring/prometheus/rules.yml` | `Backup*` alerts |
| `scripts/ops/ops-backup-retention.sh` | drops expired `ops._bkp_*` / `ops._fix_*` tables |
| `terraform/production/backups.tf`, `snapshots.tf`, `database.tf` | production bucket and snapshots |
