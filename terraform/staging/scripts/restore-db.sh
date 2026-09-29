#!/bin/bash
# restore-db.sh — restore a staging PostgreSQL database from its S3 backup
#
# Restores into a SIDE database (<db>__restoring), verifies it, and only then
# swaps it in by rename. The previous database is kept as <db>__pre_restore_<ts>
# until you drop it, so a failed or wrong restore never destroys the live data.
# (The old version ran `pg_restore --clean` over the live DB: a mid-restore
# failure left neither the old nor the new data, and its `--jobs=4` over a pipe
# is rejected by pg_restore — it could never have worked.)
#
# Usage:
#   ./restore-db.sh [--db NAME] <s3-key|latest> [--yes-i-am-sure] [--no-swap]
#
#   --db NAME   database to restore (default: packiot). packiot backups live at
#               the bucket root; every other DB under <db>/ (see backup-db.sh).
#   --no-swap   restore + verify into <db>__restoring and stop (restore drill,
#               or inspect before swapping). Re-running without it restores again.
#
# Examples:
#   ./restore-db.sh --db packiot_analytics latest                       # dry run
#   ./restore-db.sh --db packiot_analytics latest --yes-i-am-sure --no-swap
#   ./restore-db.sh --db packiot_analytics daily/2026-09-29.dump.gz --yes-i-am-sure
#   ./restore-db.sh latest --yes-i-am-sure                              # legacy packiot
#
# TimescaleDB: if the dump contains the timescaledb extension, the side DB is
# wrapped in timescaledb_pre_restore() / timescaledb_post_restore() (required,
# or hypertable catalog triggers fire during COPY and the restore breaks).
#
# Roles: owners + GRANTs are in the dump (since 2026-09-29) and reference the
# cluster roles in s3://$BACKUP_BUCKET/globals/latest.sql.gz, applied first here
# ("already exists" errors are expected and ignored on a live cluster). Older
# --no-owner dumps restore superuser-owned with no grants: RLS definer views then
# BYPASS RLS — re-own them before exposing the DB (drill 2026-09-29: 5307→2 grants).
set -euo pipefail

: "${POSTGRES_CONTAINER:=timescaledb}"
: "${POSTGRES_USER:=postgres}"
: "${BACKUP_BUCKET:?BACKUP_BUCKET env var required (try: source /etc/packiot/backup.env)}"
: "${AWS_REGION:=us-east-1}"
# Disk, not /tmp: /tmp on the DB host is a 7.7 GB RAM tmpfs.
: "${DUMP_DIR:=/var/lib/packiot-backup}"

DB=packiot; KEY=""; CONFIRM=""; SWAP=1
while [ $# -gt 0 ]; do
    case "$1" in
        --db) DB="$2"; shift 2 ;;
        --yes-i-am-sure) CONFIRM=1; shift ;;
        --no-swap) SWAP=0; shift ;;
        -*) echo "unknown flag: $1"; exit 2 ;;
        *) KEY="$1"; shift ;;
    esac
done

PREFIX=""; [ "$DB" != "packiot" ] && PREFIX="$DB/"
SIDE="${DB}__restoring"
log() { echo "[$(date -u +%FT%TZ)] $*"; }
psql_c() { docker exec -i -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 -At "$@"; }

if [ -z "$KEY" ]; then
    echo "usage: $0 [--db NAME] <s3-key|latest> [--yes-i-am-sure] [--no-swap]"
    echo; echo "Backups of '$DB' in s3://$BACKUP_BUCKET/$PREFIX:"
    for tier in daily weekly monthly; do
        aws s3 ls "s3://$BACKUP_BUCKET/${PREFIX}$tier/" --region "$AWS_REGION" 2>/dev/null | tail -5 \
          | awk -v t="$tier" '{print "  "t"/"$NF, "("$1, $3" bytes)"}'
    done
    exit 1
fi

# Keys are given relative to the DB's prefix ("latest", "daily/<date>.dump.gz").
case "$KEY" in "$PREFIX"*) ;; *) KEY="${PREFIX}${KEY}" ;; esac
S3_URI="s3://$BACKUP_BUCKET/$KEY"

BACKUP_BYTES=$(aws s3api head-object --bucket "$BACKUP_BUCKET" --key "$KEY" --region "$AWS_REGION" \
    --query ContentLength --output text 2>/dev/null) || { echo "ERROR: backup not found at $S3_URI"; exit 1; }
log "Backup found: $S3_URI ($BACKUP_BYTES bytes)"

if [ -z "$CONFIRM" ]; then
    cat <<EOF

DRY RUN — no changes made.

Would restore '$DB' on container '$POSTGRES_CONTAINER' from $S3_URI
into side database '$SIDE', verify it, then $( [ $SWAP = 1 ] && echo "swap it in by rename (current '$DB' kept as ${DB}__pre_restore_<ts>)" || echo "STOP (--no-swap)" ).

Needs roughly $((BACKUP_BYTES * 15 / 1073741824 + 1)) GB free on the DB volume. Re-run with --yes-i-am-sure to proceed.
EOF
    exit 0
fi

mkdir -p "$DUMP_DIR"
LOCAL_DUMP="$DUMP_DIR/restore-${DB}-$(date +%s).dump.gz"
trap 'rm -f "$LOCAL_DUMP"' EXIT
log "Downloading $S3_URI → $LOCAL_DUMP"
aws s3 cp "$S3_URI" "$LOCAL_DUMP" --region "$AWS_REGION" --no-progress
gzip -t "$LOCAL_DUMP" || { log "ERROR: dump is not a valid gzip"; exit 1; }

IS_TSDB=0
gunzip -c "$LOCAL_DUMP" | docker exec -i "$POSTGRES_CONTAINER" pg_restore --list 2>/dev/null \
    | grep -q 'EXTENSION - timescaledb' && IS_TSDB=1
log "TimescaleDB dump: $IS_TSDB"

log "Creating side database $SIDE"
psql_c -d postgres -c "DROP DATABASE IF EXISTS \"$SIDE\" WITH (FORCE)"
psql_c -d postgres -c "CREATE DATABASE \"$SIDE\""
if [ "$IS_TSDB" = 1 ]; then
    psql_c -d "$SIDE" -c "CREATE EXTENSION IF NOT EXISTS timescaledb" -c "SELECT timescaledb_pre_restore()"
fi

log "Applying cluster roles from s3://$BACKUP_BUCKET/globals/latest.sql.gz"
aws s3 cp "s3://$BACKUP_BUCKET/globals/latest.sql.gz" - --region "$AWS_REGION" --no-progress | gunzip \
    | docker exec -i -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" psql -q -d postgres 2>&1 \
    | grep -v 'already exists' || true

# Single-threaded: pg_restore can only parallelise (-j) from a seekable file,
# not from stdin. Drill 2026-09-29: 983 MB gz analytics dump → 18 GB in 9.5 min
# on 1 CPU. Not --exit-on-error: every error is counted and gated before the swap
# (MAX_RESTORE_ERRORS, default 0), and you get the whole list, not just the first.
log "pg_restore into $SIDE (single stream)"
ERR_LOG="$DUMP_DIR/restore-${DB}.err"
set +e
gunzip -c "$LOCAL_DUMP" | docker exec -i -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" \
    pg_restore --dbname="$SIDE" 2> "$ERR_LOG"
set -e
ERRS=$(grep -c '^pg_restore: error' "$ERR_LOG" || true)
log "pg_restore finished with $ERRS error(s) — full log: $ERR_LOG"
grep '^pg_restore: error' "$ERR_LOG" | head -10 || true

[ "$IS_TSDB" = 1 ] && psql_c -d "$SIDE" -c "SELECT timescaledb_post_restore()"
log "ANALYZE $SIDE"
psql_c -d "$SIDE" -c "ANALYZE"

log "Verifying $SIDE vs current $DB (table counts per schema)"
VERIFY="SELECT n.nspname, count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE c.relkind IN ('r','p','v','m') AND n.nspname !~ '^(pg_|_timescaledb|timescaledb_|information_schema)'
        GROUP BY 1 ORDER BY 1"
diff <(psql_c -d "$DB" -c "$VERIFY" 2>/dev/null || true) <(psql_c -d "$SIDE" -c "$VERIFY") \
    && log "schema object counts identical" || log "WARNING: schema object counts differ (<current >restored)"
psql_c -d "$SIDE" -c "SELECT 'restored size', pg_size_pretty(pg_database_size(current_database()))"

if [ "$ERRS" -gt "${MAX_RESTORE_ERRORS:-0}" ]; then
    log "ERROR: $ERRS restore errors > MAX_RESTORE_ERRORS=${MAX_RESTORE_ERRORS:-0}; NOT swapping. Inspect $ERR_LOG and $SIDE."
    exit 1
fi
if [ "$SWAP" = 0 ]; then
    log "--no-swap: $SIDE left in place. Swap: re-run without --no-swap, or drop: DROP DATABASE \"$SIDE\";"
    exit 0
fi

OLD="${DB}__pre_restore_$(date -u +%Y%m%d%H%M)"
log "Swapping: $DB → $OLD, $SIDE → $DB (clients reconnect to the restored DB)"
# ALLOW_CONNECTIONS false first: otherwise pooled clients reconnect between the
# terminate and the RENAME and it fails with "being accessed by other users".
if [ "$(psql_c -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$DB'")" = 1 ]; then
    psql_c -d postgres <<SQL
ALTER DATABASE "$DB" WITH ALLOW_CONNECTIONS false;
SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname IN ('$DB', '$SIDE') AND pid <> pg_backend_pid();
ALTER DATABASE "$DB" RENAME TO "$OLD";
SQL
else
    OLD="(none — $DB did not exist)"
fi
psql_c -d postgres -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname='$SIDE' AND pid <> pg_backend_pid()" \
       -c "ALTER DATABASE \"$SIDE\" RENAME TO \"$DB\""

log "Restore complete. Previous database kept as $OLD."
cat <<EOF

POST-RESTORE CHECKLIST:
  1. Roles created fresh by the globals file have NO passwords (not stored in S3):
     ALTER ROLE <login role> PASSWORD '...' from Secrets Manager / compose .env.
     Check the RLS fence: views owned by a non-superuser should be > 0:
       SELECT count(*) FROM pg_class c JOIN pg_roles r ON r.oid=c.relowner
        WHERE c.relkind='v' AND NOT r.rolsuper;
  2. pg_cron: SELECT * FROM cron.job;  (restart the container if jobs don't fire)
  3. Watch stream-engine / edge-api / read-api logs for reconnection errors.
  4. When satisfied: DROP DATABASE "$OLD";
EOF
