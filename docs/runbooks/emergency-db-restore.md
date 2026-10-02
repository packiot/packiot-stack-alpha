# Emergency database restore (staging)

**Button:** GitHub → Actions → **"EMERGENCY – restore database (staging)"** → *Run workflow*
(`.github/workflows/emergency-db-restore.yml`). One path underneath:
`terraform/staging/scripts/restore-db.sh`, the same script the manual fallback below uses.

## When to press it

| Situation | Press? | Mode |
|---|---|---|
| "Are our backups any good?" / after changing backup or restore scripts / monthly | yes | `drill` |
| A DB is gone, corrupted, or mass-deleted/overwritten (bad migration, `DROP`, runaway `DELETE`) and cannot be fixed forward | yes | `restore` |
| A few rows are wrong | **no** — do a `drill`-style `--no-swap` restore and copy the rows out of `<db>__restoring` | — |
| The DB box's volume/host is dead | not first — restore the host from the AWS Backup EBS snapshot once `aws_backup_selection.db_ec2` is applied; this button needs a running Postgres | — |

## What it does

Inputs: `database` (analytics = `packiot_analytics`, historian = `packiot_historian` on hist-gateway,
superset), `backup` (`latest` | `YYYY-MM-DD` | `daily|weekly|monthly/<name>.dump.gz`), `mode`,
`confirm`, `catalog_gate`.

1. Validates the inputs (whitelist), and for `restore`: `confirm` must equal
   `RESTORE <database> ON STAGING` and the run must be on the `staging` branch.
2. Preflight: the `restore-db.sh` installed on the target host must be byte-identical to the
   commit's (otherwise re-run the installer).
3. Restores the backup into a **side DB** `<db>__restoring` (never over the live DB): cluster
   roles first, TimescaleDB pre/post-restore, single-stream `pg_restore`, copies the
   database-level settings (`search_path`! — not part of `pg_dump`), `ANALYZE`.
4. **Verify gate** — refuses to continue on any of: a `pg_restore` error; a catalog difference vs
   the live DB (RLS policies, forced-RLS tables, non-superuser-owned views = the tenant fence,
   extensions, DB settings, object counts per schema, hypertables, caggs, Timescale jobs);
   a key table that is empty in the restore but not live. Row counts of key tables are printed
   (the live DB has moved on since the backup, so they are reported, not gated).
5. `drill`: drops the side DB. Done — nothing live was touched.
6. `restore`: stops the writers that would race the swap (analytics: `stream-engine`,
   `analytics-sync`, `legacy-replicator`, `legacy-replicator-sbx` — their input waits in RabbitMQ;
   historian: the append/integrity/backup timers; superset: `superset`, `superset-worker`),
   renames live → **`<db>_pre_emergency_<UTC yyyymmddHHMM>`** (connections disabled, **kept**),
   renames `<db>__restoring` → `<db>`, restarts the Postgres container (TimescaleDB/pg_cron
   workers bind to the old DB otherwise), starts the writers again, prints a summary + the
   rollback SQL.

APIs (edge-api, read-api, operator-gateway, barcode) are not stopped: they error for the few
seconds of the swap/restart and reconnect.

## RPO / RTO (measured 2026-09-30)

| DB | Backup | RPO | Restore (RTO of the restore step) |
|---|---|---|---|
| packiot_analytics | nightly 02:00 UTC pg_dump, ~1.0 GB gz → 18 GB | ≤ 24 h (+ dump duration ~10 min) | ~15 min restore+ANALYZE (isolated drill, 1 CPU); plus swap + container restart ~1 min |
| packiot_historian (catalog) | nightly 04:30 UTC pg_dump, ~13 KB | ≤ 24 h | seconds |
| historian Parquet (cold store, S3) | **none yet** — see "Gaps" | — | — |
| superset | nightly 02:00 UTC with the DB box run | ≤ 24 h | < 1 min |

Anything written after the backup was taken is **not** in the restored DB. If the displaced
`<db>_pre_emergency_*` is still readable, copy the missing rows from it.

## Rollback of a swap

```sql
-- on the same Postgres (DB box: docker exec -i timescaledb psql -U postgres -d postgres;
-- historian: docker exec -i hist-gateway psql -U postgres -d postgres on the app box)
ALTER DATABASE "packiot_analytics" WITH ALLOW_CONNECTIONS false;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'packiot_analytics';
ALTER DATABASE "packiot_analytics" RENAME TO "packiot_analytics__rolled_back";
ALTER DATABASE "packiot_analytics_pre_emergency_202609301200" WITH ALLOW_CONNECTIONS true;
ALTER DATABASE "packiot_analytics_pre_emergency_202609301200" RENAME TO "packiot_analytics";
```
then `docker restart timescaledb` (or `hist-gateway`). When satisfied either way:
`DROP DATABASE "<the one you don't want>";` — the pre-emergency copy costs a full DB of disk.

## Manual fallback (GitHub or the app box down)

Same script, on the host that runs the Postgres. From a laptop with AWS creds:
`aws ssm start-session --target <instance>` (DB box = tag `Name=packiot-staging-db`,
app box = `packiot-staging-app`), then `sudo -i`.

```bash
# analytics / superset / legacy packiot — DB box
set -a; . /etc/packiot/backup.env; set +a
/opt/packiot/scripts/restore-db.sh --db packiot_analytics latest                    # dry run: shows key, age, disk need
/opt/packiot/scripts/restore-db.sh --db packiot_analytics latest --yes-i-am-sure --drill
/opt/packiot/scripts/restore-db.sh --db packiot_analytics latest --yes-i-am-sure --no-swap
#   stop writers on the app box:  docker stop stream-engine analytics-sync legacy-replicator legacy-replicator-sbx
/opt/packiot/scripts/restore-db.sh --db packiot_analytics --swap-only --yes-i-am-sure \
    --old-name packiot_analytics_pre_emergency_$(date -u +%Y%m%d%H%M) --restart-container
#   start writers again:            docker start stream-engine analytics-sync legacy-replicator legacy-replicator-sbx

# historian catalog — app box
set -a; . /etc/packiot/historian-backup.env; set +a
POSTGRES_CONTAINER=$GATEWAY_CONTAINER GLOBALS_KEY=${BACKUP_KEY_PREFIX}packiot_historian/globals/latest.sql.gz \
  /opt/packiot/scripts/restore-db.sh --db packiot_historian latest --yes-i-am-sure --drill
```

Live DB damaged so the catalog *should* differ? Add `CATALOG_GATE=report` (button: `catalog_gate=report`).
Live DB gone entirely? The gate skips the comparisons and the settings come from the saved
`<db>/db-settings/latest.sql`. After any restore: roles created from the globals file have **no
passwords** — `ALTER ROLE … PASSWORD` from Secrets Manager / `/opt/packiot/.env` if logins fail.

## Where the backups are

| What | Where |
|---|---|
| analytics | `s3://packiot-staging-db-backups-639178078294/packiot_analytics/{daily,weekly,monthly,latest,db-settings}` |
| superset | `…/superset/…` (same layout) |
| legacy packiot | bucket root `daily/ weekly/ monthly/ latest db-settings/` |
| DB-box roles | `…/globals/{daily,latest.sql.gz}` |
| historian catalog | `s3://packiot-staging-historian-639178078294/_backup/packiot_historian/…` (interim; moves to the backup bucket when `app_backup_ops` is applied) |

Jobs: `packiot-db-backup.timer` (DB box, 02:00 UTC), `packiot-historian-backup.timer` (app box,
04:30 UTC). Alerts: `BackupStale`, `BackupShrank`, `BackupMetricsMissing`, `BackupMirrorIncomplete`
(`monitoring/prometheus/rules.yml`).

## Gaps (not done — need a decision / `terraform apply`)

- **Button for analytics/superset needs `aws_iam_role_policy.app_backup_ops`** (terraform/staging/backups.tf):
  the runner's role cannot `ssm:SendCommand` to the DB box yet. Until applied, only `historian`
  runs from the button; the others use the manual fallback.
- **Historian Parquet has no copy** until the same grant is applied and the app box is switched to
  `MODE=target` (`install-historian-backup.sh`), and **bucket versioning** (historian.tf) is applied.
- Backup bucket versioning, DB-box EBS snapshots (snapshots.tf) — in terraform, not applied.
- No PITR (WAL archiving): RPO is a day, not minutes. Single account + region: no copy survives
  an account compromise or a regional S3 outage.
