#!/bin/bash
# backup-db.sh — nightly PostgreSQL backup → S3
#
# Runs on the DB EC2 (closest to data, no VPC egress). Invoked by the
# packiot-db-backup.timer systemd unit at 02:00 UTC daily.
#
# Databases: POSTGRES_DBS (space-separated; default = POSTGRES_DB, then
# "packiot"). Since 2026-09-28 staging backs up BOTH the frozen legacy
# `packiot` and the live new-stack `packiot_analytics` — until then only
# `packiot` was dumped and the live system of record had no logical backup.
#
# Layout in S3 (under s3://$BACKUP_BUCKET/). `packiot` keeps the original
# root layout (restore-db.sh and existing tooling read it); every other DB
# lives under its own `<db>/` prefix with the same tiers:
#   [<db>/]daily/YYYY-MM-DD.dump.gz    kept for 14 days
#   weekly/YYYY-Www.dump.gz            (Sundays) kept for 4 weeks
#   monthly/YYYY-MM.dump.gz            (1st of month) kept for 3 months
#   [<db>/]latest -> alias key updated each run to point at the freshest daily
#
# Restoring a TimescaleDB database (packiot_analytics): run
#   SELECT timescaledb_pre_restore();  before pg_restore and
#   SELECT timescaledb_post_restore(); after it, in the target database.
#
# Retention is enforced by this script's prune step. S3 lifecycle (in
# backups.tf) is a separate 90-day belt-and-braces cap.
#
# Failure modes:
#   - pg_dump errors → exit nonzero, systemd records Failed status
#   - S3 upload errors → exit nonzero, systemd retries on next scheduled run
#   - SET +e then explicit check pattern is intentional: we want to log all
#     individual step failures rather than abort at first one
set -euo pipefail

# ── Config (overridable via env, defaults match staging) ──────────────────────
: "${POSTGRES_CONTAINER:=timescaledb}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=packiot}"
: "${POSTGRES_DBS:=$POSTGRES_DB}"
# Stage dumps on DISK: /tmp on the DB host is a RAM-backed tmpfs (7.7 GB), and
# a packiot_analytics dump there would eat the database server's memory.
: "${DUMP_DIR:=/var/lib/packiot-backup}"
: "${BACKUP_BUCKET:?BACKUP_BUCKET env var required}"
: "${AWS_REGION:=us-east-1}"
: "${RETAIN_DAILY:=14}"
: "${RETAIN_WEEKLY:=4}"
: "${RETAIN_MONTHLY:=3}"

LOG_TAG="packiot-db-backup"

log() { echo "[$(date -u +%FT%TZ)] $*" | logger -t "$LOG_TAG" -s 2>&1; }

# ── Compute today's classification ────────────────────────────────────────────
TODAY=$(date -u +%F)                       # YYYY-MM-DD
WEEK=$(date -u +%G-W%V)                    # ISO 8601 week (e.g. 2026-W25)
MONTH=$(date -u +%Y-%m)                    # YYYY-MM
DOW=$(date -u +%u)                         # 1=Mon..7=Sun
DOM=$(date -u +%d)                         # 01..31

# Every run produces a daily backup per DB. The same dump is ALSO uploaded under
# weekly/ on Sundays, and monthly/ on the 1st. We don't dump three times —
# we upload the same gz to up-to-three keys.
mkdir -p "$DUMP_DIR"

prune_prefix() {
    local prefix="$1"
    local keep="$2"
    log "Pruning $prefix: keep most recent $keep"

    # JMESPath's sort_by() raises when Contents is null (empty prefix), and
    # `set -e` would kill the whole script over that. Wrap in `|| echo ''` so
    # an empty prefix becomes an empty string instead of a non-zero exit.
    # Keys (YYYY-MM-DD, YYYY-Www, YYYY-MM) sort lexicographically = chronologically.
    local keys
    keys=$(aws s3api list-objects-v2 \
        --bucket "$BACKUP_BUCKET" \
        --prefix "$prefix" \
        --region "$AWS_REGION" \
        --query 'reverse(sort_by(Contents, &Key))[*].Key' \
        --output text 2>/dev/null || echo '')

    # 'None' is what AWS prints for null query results — treat as empty.
    [ -z "$keys" ] || [ "$keys" = "None" ] && { log "  no objects to prune"; return 0; }

    echo "$keys" | tr '\t' '\n' | tail -n +$((keep + 1)) | while read -r old_key; do
        [ -z "$old_key" ] && continue
        log "  deleting old: $old_key"
        aws s3 rm "s3://$BACKUP_BUCKET/$old_key" --region "$AWS_REGION" --quiet
    done
}

# backup_one <db>: dump → gzip → S3 (daily/weekly/monthly/latest) → prune.
backup_one() {
    local db="$1"
    local prefix=""
    [ "$db" != "packiot" ] && prefix="$db/"
    local dump_file="$DUMP_DIR/${db}-${TODAY}.dump.gz"

    log "Starting backup: db=$db container=$POSTGRES_CONTAINER bucket=$BACKUP_BUCKET prefix=${prefix:-<root>}"

    # --format=custom: portable, parallelizable on restore via pg_restore -j.
    # --no-owner --no-privileges: portable across clusters with different roles.
    # --compress=0: gzip externally so the .dump.gz extension is honest.
    docker exec -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" \
        pg_dump --format=custom --no-owner --no-privileges --compress=0 \
                --dbname="$db" \
      | gzip -6 > "$dump_file"

    local dump_bytes
    dump_bytes=$(stat -c %s "$dump_file")
    log "pg_dump complete: db=$db ${dump_bytes} bytes (gzipped)"
    if [ "$dump_bytes" -lt 1048576 ]; then
        log "ERROR: dump of $db suspiciously small (<1 MB); aborting its upload"
        rm -f "$dump_file"
        return 1
    fi

    upload() {
        local s3_key="$1"
        log "Uploading to s3://$BACKUP_BUCKET/$s3_key"
        aws s3 cp "$dump_file" "s3://$BACKUP_BUCKET/$s3_key" \
            --region "$AWS_REGION" \
            --no-progress \
            --metadata "db=$db,host=$(hostname)"
    }
    upload "${prefix}daily/${TODAY}.dump.gz"
    [ "$DOW" = "7" ] && upload "${prefix}weekly/${WEEK}.dump.gz"
    [ "$DOM" = "01" ] && upload "${prefix}monthly/${MONTH}.dump.gz"

    # Stable "latest" key so restores need not know today's date.
    aws s3 cp "$dump_file" "s3://$BACKUP_BUCKET/${prefix}latest" \
        --region "$AWS_REGION" \
        --no-progress \
        --metadata "db=$db,host=$(hostname),source=${prefix}daily/${TODAY}.dump.gz"

    rm -f "$dump_file"

    prune_prefix "${prefix}daily/"   "$RETAIN_DAILY"
    prune_prefix "${prefix}weekly/"  "$RETAIN_WEEKLY"
    prune_prefix "${prefix}monthly/" "$RETAIN_MONTHLY"
    log "Backup complete: db=$db"
}

# One DB failing must not skip the others, but the run still exits non-zero so
# systemd records the failure.
failed=0
for db in $POSTGRES_DBS; do
    if ! ( set -euo pipefail; backup_one "$db" ); then
        log "ERROR: backup of $db failed"
        failed=1
    fi
done
[ "$failed" = 0 ] && log "All backups complete." || { log "Backup run finished WITH FAILURES."; exit 1; }
