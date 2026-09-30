#!/bin/bash
# backup-historian.sh — nightly backup of the HISTORIAN (runs on the APP box)
#
# The historian has two halves and neither was backed up before 2026-09-30:
#
#   1. The hist-gateway catalog DB `packiot_historian` (container hist-gateway,
#      pg_duckdb). Small (~8 MB) but hand-built state: the hot/cold union
#      boundary tables (cold.ev_union_boundary …), cold.promoted_enterprise (the
#      tenant allow-list that stops cross-tenant leaks), the append watermarks,
#      the FDW server + DuckDB S3 secret, and every view read-api/Superset query.
#      → pg_dump via backup-db.sh (same format + metrics as the DB box) into
#        s3://$BACKUP_BUCKET/${BACKUP_KEY_PREFIX}packiot_historian/{daily,weekly,monthly,latest}
#        and its cluster roles into ${BACKUP_KEY_PREFIX}packiot_historian/globals/.
#
#   2. The cold store: Parquet in s3://$HISTORIAN_BUCKET (~11 GB). Raw telemetry
#      older than the analytics 90-day hot window lives ONLY here, the bucket has
#      no versioning, and our own jobs rewrite/prune it (historian-append,
#      historian-prune-by-data-age.sh). → when MIRROR_TO is set: server-side
#      `aws s3 sync` WITHOUT --delete, so an object deleted from the historian
#      survives in the mirror. An OVERWRITTEN object is overwritten in the mirror
#      at the next run — only bucket versioning protects against a bad rewrite.
#
# TWO CONFIGURATIONS (/etc/packiot/historian-backup.env):
#   interim (live since 2026-09-30): the app box's role can write only the
#     historian bucket, so the catalog dump goes to
#     BACKUP_BUCKET=<historian bucket> BACKUP_KEY_PREFIX=_backup/ PRUNE=1, and
#     MIRROR_TO is empty (no principal may write the Parquet copy elsewhere yet).
#   target (after `terraform apply` of aws_iam_role_policy.app_backup_ops in
#     backups.tf — put/get-only on the backup bucket's two prefixes):
#     BACKUP_BUCKET=<db backup bucket> BACKUP_KEY_PREFIX= PRUNE=0
#     MIRROR_TO=s3://<db backup bucket>/historian-parquet/
#
# Metrics (textfile collector of the app box's node-exporter):
#   packiot_backup_last_success_timestamp_seconds{db="packiot_historian"|"historian_parquet"}
#   packiot_backup_size_bytes{...}, packiot_backup_mirror_missing_objects{db="historian_parquet"}
#   (no mirror configured → no historian_parquet series → BackupMetricsMissing fires:
#   that alert is the truthful "the cold store has no copy" signal.)
set -uo pipefail

: "${BACKUP_BUCKET:?BACKUP_BUCKET required}"
: "${HISTORIAN_BUCKET:?HISTORIAN_BUCKET required}"
: "${AWS_REGION:=us-east-1}"
: "${METRICS_DIR:=/var/lib/packiot-backup/metrics}"
: "${GATEWAY_CONTAINER:=hist-gateway}"
: "${SCRIPTS_DIR:=/opt/packiot/scripts}"
: "${BACKUP_KEY_PREFIX:=}"
: "${PRUNE:=0}"
: "${MIRROR_TO:=}"
export BACKUP_BUCKET AWS_REGION METRICS_DIR BACKUP_KEY_PREFIX PRUNE

log() { echo "[$(date -u +%FT%TZ)] $*"; }
failed=0

# ── 1. gateway catalog DB ────────────────────────────────────────────────────
if ! POSTGRES_CONTAINER="$GATEWAY_CONTAINER" POSTGRES_USER=postgres \
     POSTGRES_DBS=packiot_historian GLOBALS_PREFIX="${BACKUP_KEY_PREFIX}packiot_historian/globals/" \
     MIN_DUMP_BYTES=10240 DUMP_DIR=/var/lib/packiot-backup \
     "$SCRIPTS_DIR/backup-db.sh"; then
    log "ERROR: packiot_historian dump failed"; failed=1
fi

# ── 2. cold-store Parquet mirror ─────────────────────────────────────────────
if [ -z "$MIRROR_TO" ]; then
    log "WARNING: MIRROR_TO unset — the historian Parquet cold store is NOT copied anywhere (see header)."
else
DEST="${MIRROR_TO%/}/"
dst_bucket=${DEST#s3://}; dst_prefix=${dst_bucket#*/}; dst_bucket=${dst_bucket%%/*}
log "Mirroring s3://$HISTORIAN_BUCKET/ → $DEST (no --delete)"
# athena-results/ is disposable query spill; _backup/ holds the interim catalog dumps.
if aws s3 sync "s3://$HISTORIAN_BUCKET/" "$DEST" --region "$AWS_REGION" \
       --exclude 'athena-results/*' --exclude '_backup/*' --only-show-errors --no-progress; then
    # Prove coverage instead of trusting sync's exit code: every source key must
    # exist in the mirror with the same size.
    src=$(mktemp); dst=$(mktemp)
    aws s3api list-objects-v2 --bucket "$HISTORIAN_BUCKET" --region "$AWS_REGION" \
        --query 'Contents[].[Key,Size]' --output text | grep -v -e '^athena-results/' -e '^_backup/' | sort > "$src"
    aws s3api list-objects-v2 --bucket "$dst_bucket" --prefix "$dst_prefix" --region "$AWS_REGION" \
        --query 'Contents[].[Key,Size]' --output text | sed "s#^$dst_prefix##" | sort > "$dst"
    missing=$(comm -23 "$src" "$dst" | wc -l)
    src_n=$(wc -l < "$src"); bytes=$(awk '{s+=$2} END {print s+0}' "$src")
    rm -f "$src" "$dst"
    log "mirror: $src_n source objects, $bytes bytes, $missing missing/size-mismatched in mirror"
    if [ "$missing" -eq 0 ] && [ "$src_n" -gt 0 ]; then
        mkdir -p "$METRICS_DIR"
        f="$METRICS_DIR/backup_historian_parquet.prom"
        cat > "$f.tmp" <<PROM
# HELP packiot_backup_last_success_timestamp_seconds Unix time of the last successful upload.
# TYPE packiot_backup_last_success_timestamp_seconds gauge
packiot_backup_last_success_timestamp_seconds{db="historian_parquet"} $(date +%s)
# HELP packiot_backup_size_bytes Size of the last uploaded dump (gzipped).
# TYPE packiot_backup_size_bytes gauge
packiot_backup_size_bytes{db="historian_parquet"} $bytes
# HELP packiot_backup_mirror_missing_objects Source objects absent from (or size-mismatched in) the mirror.
# TYPE packiot_backup_mirror_missing_objects gauge
packiot_backup_mirror_missing_objects{db="historian_parquet"} $missing
PROM
        mv "$f.tmp" "$f"
    else
        log "ERROR: mirror incomplete ($missing missing of $src_n)"; failed=1
    fi
else
    log "ERROR: aws s3 sync failed"; failed=1
fi
fi

[ "$failed" = 0 ] && log "Historian backup complete." || { log "Historian backup finished WITH FAILURES."; exit 1; }
