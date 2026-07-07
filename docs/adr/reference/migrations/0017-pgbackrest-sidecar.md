# 0017 — pgBackRest sidecar on the DB EC2 (prepared, NOT active)

- **Status**: PREPARED 2026-07-08 (groundwork PR). Activates at the flip
  deploy — the `archive_mode=on` postgres restart rides that deploy per
  [backup-restore-runbook §5](../../../guides/backup-restore-runbook.md).
- **Scope**: DB EC2 `i-064bb36d1c454d861` only. The `timescaledb`
  container there is launched by `terraform/staging/user_data/db_init.sh`
  via plain `docker run` — it is NOT in `compose.staging.yml`, which is
  why this doc carries the exact container commands instead of a compose
  service block.
- **What exists after the groundwork PR**: S3 repo bucket
  `packiot-db-backups-639178078294` (versioned, SSE-S3, INTELLIGENT_TIERING
  after 30d, public access blocked) + `configs/pgbackrest/pgbackrest.conf`
  (stanza `packiot`). Nothing on the instance changes.

## 1. Architecture recap (runbook §3)

Two containers share three things — the pgdata bind mount, the pgBackRest
config, and a unix-socket directory:

| Piece | timescaledb container | pgbackrest sidecar |
|---|---|---|
| Role | `archive_command` pushes each WAL segment to S3 | cron: weekly full, daily diff, weekly verify |
| pgdata | `/var/lib/postgresql/data` (existing bind mount) | same host dir, same in-container path (pgBackRest requires `pg1-path` == server `data_directory`) |
| Config | `/etc/pgbackrest/pgbackrest.conf` ro bind mount | same |
| Socket | postgres listens on `/var/run/postgresql` | libpq control connection via the shared dir (pgBackRest local mode does not use TCP) |

Both containers run the **same image** (`packiot-postgres:local`). That is
deliberate, not lazy: archive-push (inside postgres) and backup (sidecar)
touch the same repo, so a single image guarantees a single pgBackRest
version and the same `postgres` uid/gid (70 on Alpine) for pgdata reads.
No separate `alpine+pgbackrest` build to keep in sync.

## 2. Image change (flip day — do not merge into `db/Dockerfile` early)

`pgbackrest` is in the Alpine community repo, so the runtime stage of
`db/Dockerfile` gains one line:

```dockerfile
# Stage 2 — clean runtime image with pg_cron extension copied in.
FROM timescale/timescaledb:latest-pg15

RUN apk add --no-cache pgbackrest   # ← flip-day addition
```

Kept out of the groundwork PR on purpose: `db_init.sh` builds this image on
boot and future deploy tooling may rebuild + re-create the container; the
Dockerfile change must land in the same PR as the container flags below so
an image rebuild can never race ahead of the config.

## 3. Host prep (flip day, before the restart — all inert)

```bash
# Config from the repo → canonical host path
sudo mkdir -p /etc/pgbackrest
sudo cp /tmp/packiot-stack/configs/pgbackrest/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
sudo chown 70:70 /etc/pgbackrest/pgbackrest.conf && sudo chmod 640 /etc/pgbackrest/pgbackrest.conf

# Shared unix-socket dir (postgres uid/gid = 70 in the Alpine image)
sudo mkdir -p /var/run/packiot-pg && sudo chown 70:70 /var/run/packiot-pg

# Sidecar crontab (busybox crond runs /etc/crontabs/postgres AS user postgres)
sudo tee /etc/pgbackrest/crontab.postgres <<'EOF'
# min hour dom mon dow — container clock is UTC (runbook §3 cadence)
0 3 * * 0    pgbackrest --stanza=packiot --type=full backup
0 3 * * 1-6  pgbackrest --stanza=packiot --type=diff backup
0 5 * * 0    pgbackrest --stanza=packiot verify
EOF
```

IAM (separate terraform change at flip, NOT this repo's groundwork PR):
attach to role `packiot-staging-db` — `s3:ListBucket` on
`arn:aws:s3:::packiot-db-backups-639178078294` and `s3:GetObject`,
`s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload` on
`arn:aws:s3:::packiot-db-backups-639178078294/*`. Credentials reach the
containers via IMDSv2 — already satisfied: the instance has
`HttpPutResponseHopLimit=2` (verified 2026-07-08), which is what lets a
bridge-networked container hop to `169.254.169.254`.

## 4. The postgres container, re-created (THE one restart — rides the flip deploy)

This is the `db_init.sh` `docker run` with three new mounts/flags. Diff
against the current invocation: `+` lines only.

```bash
docker stop timescaledb && docker rm timescaledb   # data survives: pgdata is a host bind mount

docker run -d \
  --name timescaledb \
  --restart unless-stopped \
  --platform linux/arm64 \
  -p 0.0.0.0:5432:5432 \
  -e POSTGRES_PASSWORD="$DB_PASS" \
  -e POSTGRES_DB=packiot \
  -e POSTGRES_USER=postgres \
  -e TIMESCALEDB_TELEMETRY=off \
  -v /var/lib/postgresql/data:/var/lib/postgresql/data \
  -v /etc/pgbackrest/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro \
  -v /var/run/packiot-pg:/var/run/postgresql \
  packiot-postgres:local \
  -c "shared_preload_libraries=timescaledb,pg_cron" \
  -c "cron.database_name=packiot" \
  -c "archive_mode=on" \
  -c "archive_command=pgbackrest --stanza=packiot archive-push %p" \
  -c "archive_timeout=300"
```

Notes:
- `wal_level` needs no flag — PG15 default is already `replica`, which is
  all `archive_mode=on` requires.
- `archive_timeout=300` forces a segment switch every 5 min on a quiet
  system — this is what makes the runbook's RPO ≤5 min true even when
  ingest pauses, at the cost of a few 16MB segments/day of S3 churn.
- If the S3 repo is unreachable, `archive_command` fails and postgres
  **retains WAL locally until it succeeds** — watch pgdata disk (42% used
  at prep time) if archiving is ever broken for hours.

## 5. Sidecar container (flip day, after §4)

```bash
docker run -d \
  --name pgbackrest \
  --restart unless-stopped \
  --platform linux/arm64 \
  -v /var/lib/postgresql/data:/var/lib/postgresql/data \
  -v /etc/pgbackrest/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro \
  -v /etc/pgbackrest/crontab.postgres:/etc/crontabs/postgres:ro \
  -v /var/run/packiot-pg:/var/run/postgresql \
  --entrypoint crond \
  packiot-postgres:local \
  -f -l 6 -L /dev/stdout
```

crond runs as root (busybox requirement) but executes the
`/etc/crontabs/postgres` table **as user postgres** (uid 70) — matching
pgdata file ownership so backups never need root reads.

## 6. Activation checklist (flip day, in order)

```bash
# 0. Preconditions: IAM policy attached to packiot-staging-db; image
#    rebuilt with pgbackrest; host prep (§3) done.

# 1. Re-create postgres with archive flags (§4) — the ONE restart.
docker exec timescaledb pg_isready -U postgres        # wait until ready

# 2. Initialize the repo (writes stanza metadata to S3).
docker exec -u postgres timescaledb pgbackrest --stanza=packiot stanza-create

# 3. End-to-end archiving check: forces a WAL switch and confirms the
#    segment lands in S3 via archive_command. MUST pass before step 4.
docker exec -u postgres timescaledb pgbackrest --stanza=packiot check

# 4. First full backup (baseline for all diffs + PITR).
docker exec -u postgres timescaledb pgbackrest --stanza=packiot --type=full backup

# 5. Verify repo integrity (runbook: scheduled verification is the point).
docker exec -u postgres timescaledb pgbackrest --stanza=packiot verify

# 6. Start the cron sidecar (§5), then confirm schedule + repo state:
docker exec -u postgres timescaledb pgbackrest --stanza=packiot info
#    expect: 1 full backup, wal archive min/max present.

# 7. Within 24h: confirm the first diff appeared (pgbackrest info) and
#    postgres logs show no archive_command failures:
docker logs timescaledb 2>&1 | grep -i "archive" | tail
```

Exit criterion stays the runbook's: the first **restore drill**
(runbook §4) on a scratch instance, not a green backup log. An untested
backup is a hope, not a backup.
