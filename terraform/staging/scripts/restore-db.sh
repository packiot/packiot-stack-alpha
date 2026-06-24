#!/bin/bash
# restore-db.sh — restore staging PostgreSQL from S3 backup
#
# DESTRUCTIVE: drops all data in the target database and replaces with the
# backup's contents. Requires explicit --yes-i-am-sure to run.
#
# Usage:
#   ./restore-db.sh <s3-key|latest> [--yes-i-am-sure]
#
# Examples:
#   ./restore-db.sh latest                        # dry run
#   ./restore-db.sh latest --yes-i-am-sure        # restore from newest daily
#   ./restore-db.sh daily/2026-06-15.dump.gz --yes-i-am-sure
#   ./restore-db.sh weekly/2026-W24.dump.gz --yes-i-am-sure
#
# Failure modes:
#   - S3 download error → exit nonzero before touching DB
#   - pg_restore error on schema → DB is in inconsistent state; recovery is
#     to re-run with a known-good backup (or run the bootstrap from scratch)
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
: "${POSTGRES_CONTAINER:=timescaledb}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=packiot}"
: "${BACKUP_BUCKET:?BACKUP_BUCKET env var required (try: source /etc/packiot/backup.env)}"
: "${AWS_REGION:=us-east-1}"

S3_KEY="${1:-}"
CONFIRM="${2:-}"

if [ -z "$S3_KEY" ]; then
    echo "usage: $0 <s3-key|latest> [--yes-i-am-sure]"
    echo
    echo "Available backups in s3://$BACKUP_BUCKET/:"
    aws s3 ls "s3://$BACKUP_BUCKET/daily/"   --region "$AWS_REGION" 2>/dev/null | tail -7  | awk '{print "  daily/"$NF, "("$1, $3" bytes)"}'
    aws s3 ls "s3://$BACKUP_BUCKET/weekly/"  --region "$AWS_REGION" 2>/dev/null | tail -4  | awk '{print "  weekly/"$NF, "("$1, $3" bytes)"}'
    aws s3 ls "s3://$BACKUP_BUCKET/monthly/" --region "$AWS_REGION" 2>/dev/null | tail -3  | awk '{print "  monthly/"$NF, "("$1, $3" bytes)"}'
    exit 1
fi

# ── Resolve 'latest' alias ────────────────────────────────────────────────────
if [ "$S3_KEY" = "latest" ]; then
    S3_KEY="latest"
fi

S3_URI="s3://$BACKUP_BUCKET/$S3_KEY"

# ── Pre-flight: verify backup exists ──────────────────────────────────────────
if ! aws s3 ls "$S3_URI" --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "ERROR: backup not found at $S3_URI"
    exit 1
fi

BACKUP_BYTES=$(aws s3api head-object --bucket "$BACKUP_BUCKET" --key "$S3_KEY" --region "$AWS_REGION" --query ContentLength --output text)
echo "Backup found: $S3_URI ($BACKUP_BYTES bytes)"

# ── Confirmation gate ────────────────────────────────────────────────────────
if [ "$CONFIRM" != "--yes-i-am-sure" ]; then
    cat <<EOF

DRY RUN — no changes made.

Would restore database '$POSTGRES_DB' on container '$POSTGRES_CONTAINER'
from $S3_URI ($BACKUP_BYTES bytes).

This is DESTRUCTIVE — all current data in '$POSTGRES_DB' will be REPLACED
with the backup's contents.

To proceed, re-run with --yes-i-am-sure:
  $0 $S3_KEY --yes-i-am-sure

EOF
    exit 0
fi

# ── Download backup ─────────────────────────────────────────────────────────
LOCAL_DUMP="/tmp/restore-$(date +%s).dump.gz"
echo "[$(date -u +%FT%TZ)] Downloading $S3_URI → $LOCAL_DUMP"
aws s3 cp "$S3_URI" "$LOCAL_DUMP" --region "$AWS_REGION" --no-progress

LOCAL_BYTES=$(stat -c %s "$LOCAL_DUMP")
if [ "$LOCAL_BYTES" -lt 1048576 ]; then
    echo "ERROR: downloaded dump suspiciously small ($LOCAL_BYTES bytes)"
    rm -f "$LOCAL_DUMP"
    exit 1
fi

# ── Terminate active connections to the target DB ────────────────────────────
# pg_restore --clean needs exclusive access — connections from oeecloud,
# edge-api, the engine cron, etc would block DROP TABLE.
echo "[$(date -u +%FT%TZ)] Terminating active connections to $POSTGRES_DB"
docker exec -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" \
    psql -d postgres -v ON_ERROR_STOP=1 -c "
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE datname = '$POSTGRES_DB' AND pid <> pg_backend_pid();
    "

# ── Restore ─────────────────────────────────────────────────────────────────
# --clean --if-exists drops existing objects before recreating. With a custom-
# format dump this is atomic per-object. --no-owner --no-privileges matches the
# dump-time flags so role mismatches don't fail the restore.
# -j 4: parallel restore; safe for staging's small dataset.
echo "[$(date -u +%FT%TZ)] Restoring (this may take several minutes)..."
gunzip -c "$LOCAL_DUMP" | docker exec -i -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" \
    pg_restore --clean --if-exists --no-owner --no-privileges \
               --dbname="$POSTGRES_DB" \
               --jobs=4 \
               --exit-on-error

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -f "$LOCAL_DUMP"

# ── Post-flight sanity ──────────────────────────────────────────────────────
echo "[$(date -u +%FT%TZ)] Verifying restored database..."
docker exec -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" \
    psql -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "
        SELECT
          (SELECT COUNT(*) FROM pg_tables WHERE schemaname='public')     AS tables,
          (SELECT COUNT(*) FROM pg_proc   WHERE pronamespace='public'::regnamespace) AS functions,
          (SELECT COUNT(*) FROM enterprises)                              AS enterprises,
          (SELECT COUNT(*) FROM equipments)                               AS equipments,
          (SELECT pg_size_pretty(pg_database_size('$POSTGRES_DB')))       AS db_size;
    "

echo "[$(date -u +%FT%TZ)] Restore complete."
echo
echo "POST-RESTORE CHECKLIST:"
echo "  1. Verify pg_cron jobs survived: SELECT * FROM cron.job;"
echo "  2. Watch oeecloud / edge-api logs for reconnection errors"
echo "  3. Confirm equipment_values ingest resumed: SELECT MAX(ts_value) FROM equipment_values;"
