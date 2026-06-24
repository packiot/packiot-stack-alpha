#!/bin/bash
# backup-db.sh — nightly PostgreSQL backup → S3
#
# Runs on the DB EC2 (closest to data, no VPC egress). Invoked by the
# packiot-db-backup.timer systemd unit at 02:00 UTC daily.
#
# Layout in S3 (under s3://$BACKUP_BUCKET/):
#   daily/YYYY-MM-DD.dump.gz           kept for 14 days
#   weekly/YYYY-Www.dump.gz            (Sundays) kept for 4 weeks
#   monthly/YYYY-MM.dump.gz            (1st of month) kept for 3 months
#   latest -> alias key updated each run to point at the freshest daily
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

# Every run produces a daily backup. The same dump is ALSO uploaded under
# weekly/ on Sundays, and monthly/ on the 1st. We don't dump three times —
# we upload the same gz to up-to-three keys.
DUMP_FILE="/tmp/packiot-${TODAY}.dump.gz"

log "Starting backup: db=$POSTGRES_DB container=$POSTGRES_CONTAINER bucket=$BACKUP_BUCKET"

# ── pg_dump → gzip → local file ──────────────────────────────────────────────
# --format=custom: portable, parallelizable on restore via pg_restore -j,
#   includes data only matching schema (so a structural drift on restore is
#   visible at pg_restore time, not lost as a SQL error mid-stream).
# --no-owner --no-privileges: makes the dump portable across PostgreSQL clusters
#   with different user/role setups.
# --compress=0: we gzip externally so we can pipe through `pv` if needed for
#   progress later, and so the .dump.gz extension is honest about compression.
docker exec -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" \
    pg_dump --format=custom --no-owner --no-privileges --compress=0 \
            --dbname="$POSTGRES_DB" \
  | gzip -6 > "$DUMP_FILE"

DUMP_BYTES=$(stat -c %s "$DUMP_FILE")
log "pg_dump complete: ${DUMP_BYTES} bytes (gzipped)"

if [ "$DUMP_BYTES" -lt 1048576 ]; then
    log "ERROR: dump suspiciously small (<1 MB); aborting upload"
    rm -f "$DUMP_FILE"
    exit 1
fi

# ── Upload to S3 (daily; also weekly on Sunday, monthly on 1st) ─────────────
upload() {
    local s3_key="$1"
    log "Uploading to s3://$BACKUP_BUCKET/$s3_key"
    aws s3 cp "$DUMP_FILE" "s3://$BACKUP_BUCKET/$s3_key" \
        --region "$AWS_REGION" \
        --no-progress \
        --metadata "db=$POSTGRES_DB,host=$(hostname)"
}

upload "daily/${TODAY}.dump.gz"

if [ "$DOW" = "7" ]; then
    upload "weekly/${WEEK}.dump.gz"
fi

if [ "$DOM" = "01" ]; then
    upload "monthly/${MONTH}.dump.gz"
fi

# Update the "latest" pointer (just a copy with a stable key). Restore scripts
# can use `aws s3 cp s3://$bucket/latest -` without knowing today's date.
aws s3 cp "$DUMP_FILE" "s3://$BACKUP_BUCKET/latest" \
    --region "$AWS_REGION" \
    --no-progress \
    --metadata "db=$POSTGRES_DB,host=$(hostname),source=daily/${TODAY}.dump.gz"

# ── Cleanup local dump ────────────────────────────────────────────────────────
rm -f "$DUMP_FILE"

# ── Prune old backups (enforce per-tier retention) ────────────────────────────
# S3 lifecycle handles the 90-day hard cap; this enforces the finer-grained
# per-tier policy. Idempotent — safe to re-run.
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

prune_prefix "daily/"   "$RETAIN_DAILY"
prune_prefix "weekly/"  "$RETAIN_WEEKLY"
prune_prefix "monthly/" "$RETAIN_MONTHLY"

log "Backup complete."
