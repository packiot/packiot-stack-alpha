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
# Since 2026-09-30 also `superset` (Superset metadata). The historian (app box)
# is backed up by backup-historian.sh, which reuses this script.
#
# Layout in S3 (under s3://$BACKUP_BUCKET/). `packiot` keeps the original
# root layout (restore-db.sh and existing tooling read it); every other DB
# lives under its own `<db>/` prefix with the same tiers:
#   [<db>/]daily/YYYY-MM-DD.dump.gz    kept for 14 days
#   weekly/YYYY-Www.dump.gz            (Sundays) kept for 4 weeks
#   monthly/YYYY-MM.dump.gz            (1st of month) kept for 3 months
#   [<db>/]latest -> alias key updated each run to point at the freshest daily
#   [<db>/]db-settings/{YYYY-MM-DD,latest}.sql  ALTER DATABASE … SET (not in pg_dump)
#   globals/daily/YYYY-MM-DD.sql.gz, globals/latest.sql.gz   roles (no passwords)
#     (GLOBALS_PREFIX; the hist-gateway cluster uses packiot_historian/globals/)
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

# Prometheus textfile collector dir, read by the alloy-db agent
# (monitoring/alloy/db-agent.alloy) and alerted on in monitoring/prometheus/rules.yml
# (BackupStale / BackupShrank). Empty = don't write metrics.
: "${METRICS_DIR:=/var/lib/packiot-backup/metrics}"

# Where the cluster-roles file goes. The DB box's timescaledb cluster keeps the
# historical `globals/`; a second cluster (the app box's hist-gateway, see
# backup-historian.sh) sets its own prefix so the two never overwrite each other.
: "${GLOBALS_PREFIX:=globals/}"
# PRUNE=0: skip the retention prune (needs s3:DeleteObject). The app box's
# historian job runs with a put-only IAM grant on purpose — a compromised app box
# must not be able to delete backups — and relies on the bucket's 90-day
# lifecycle cap instead.
: "${PRUNE:=1}"
# Dumps under this size are treated as a failed/empty dump and not uploaded.
# 1 MB suits the DB box; the hist-gateway catalog is mostly views (~tens of KB).
: "${MIN_DUMP_BYTES:=1048576}"
# Optional key prefix inside the bucket (e.g. "_backup/" when the target bucket
# also holds other data — see backup-historian.sh). Default: bucket root.
: "${BACKUP_KEY_PREFIX:=}"

# stdout only: under systemd it lands in the journal once (journalctl -u
# packiot-db-backup). `logger -s` used to write it twice (syslog + stderr).
log() { echo "[$(date -u +%FT%TZ)] $*"; }

# write_metrics <db> <bytes>: atomic rename so the collector never reads a
# half-written file. One file per DB; last_success only moves on success.
write_metrics() {
    [ -n "$METRICS_DIR" ] || return 0
    mkdir -p "$METRICS_DIR"
    local f="$METRICS_DIR/backup_$1.prom"
    cat > "$f.tmp" <<PROM
# HELP packiot_backup_last_success_timestamp_seconds Unix time of the last successful upload.
# TYPE packiot_backup_last_success_timestamp_seconds gauge
packiot_backup_last_success_timestamp_seconds{db="$1"} $(date +%s)
# HELP packiot_backup_size_bytes Size of the last uploaded dump (gzipped).
# TYPE packiot_backup_size_bytes gauge
packiot_backup_size_bytes{db="$1"} $2
PROM
    mv "$f.tmp" "$f"
}

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
    [ "$PRUNE" = 1 ] || { log "PRUNE=0: not pruning $prefix (bucket lifecycle caps age)"; return 0; }
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
    local prefix="$BACKUP_KEY_PREFIX"
    [ "$db" != "packiot" ] && prefix="$BACKUP_KEY_PREFIX$db/"
    local dump_file="$DUMP_DIR/${db}-${TODAY}.dump.gz"

    log "Starting backup: db=$db container=$POSTGRES_CONTAINER bucket=$BACKUP_BUCKET prefix=${prefix:-<root>}"

    # --format=custom: portable, parallelizable on restore via pg_restore -j.
    # Owners + GRANTs are KEPT (restore the globals/ roles file first). Until
    # 2026-09-29 this used --no-owner --no-privileges: a restore then made every
    # object superuser-owned with no grants — and packiot_analytics' RLS definer
    # views owned by a superuser BYPASS RLS (tenant fence silently gone).
    # --compress=0: gzip externally so the .dump.gz extension is honest.
    docker exec -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" \
        pg_dump --format=custom --compress=0 \
                --dbname="$db" \
      | gzip -6 > "$dump_file"

    local dump_bytes
    dump_bytes=$(stat -c %s "$dump_file")
    log "pg_dump complete: db=$db ${dump_bytes} bytes (gzipped)"
    if [ "$dump_bytes" -lt "$MIN_DUMP_BYTES" ]; then
        log "ERROR: dump of $db suspiciously small (<$MIN_DUMP_BYTES bytes); aborting its upload"
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

    # Database-level settings (ALTER DATABASE … SET, ALTER ROLE … IN DATABASE … SET)
    # live in the cluster catalog pg_db_role_setting, keyed by database OID: a
    # plain pg_dump does NOT carry them and pg_dumpall --roles-only neither. The
    # 2026-09-30 drill found packiot_analytics' search_path (gold, silver, identity,
    # config, …) and packiot_historian's (cold, public) there — a restored DB
    # without them breaks every bare-name query. Saved as SQL with a
    # __TARGET_DB__ placeholder; restore-db.sh applies it to the side DB.
    local settings_file="$DUMP_DIR/${db}-settings.sql"
    docker exec -i -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" psql -d postgres -At -v ON_ERROR_STOP=1 -v db="$db" \
        > "$settings_file" <<'SQL'
SELECT CASE WHEN s.setrole = 0 THEN 'ALTER DATABASE __TARGET_DB__ SET '
            ELSE format('ALTER ROLE %I IN DATABASE __TARGET_DB__ SET ', r.rolname) END
    || quote_ident(split_part(c, '=', 1)) || ' TO '
    -- list GUCs (pg_dump's variable_is_guc_list_quote) keep their raw list syntax
    || CASE WHEN split_part(c, '=', 1) IN ('search_path', 'temp_tablespaces', 'session_preload_libraries',
                                           'local_preload_libraries', 'shared_preload_libraries')
            THEN substr(c, strpos(c, '=') + 1) ELSE quote_literal(substr(c, strpos(c, '=') + 1)) END || ';'
FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase
LEFT JOIN pg_roles r ON r.oid = s.setrole, unnest(s.setconfig) AS c
WHERE d.datname = :'db' ORDER BY 1;
SQL
    log "db-level settings of $db: $(wc -l < "$settings_file") statement(s)"
    aws s3 cp "$settings_file" "s3://$BACKUP_BUCKET/${prefix}db-settings/${TODAY}.sql" --region "$AWS_REGION" --no-progress
    aws s3 cp "$settings_file" "s3://$BACKUP_BUCKET/${prefix}db-settings/latest.sql" --region "$AWS_REGION" --no-progress
    rm -f "$settings_file"

    prune_prefix "${prefix}daily/"   "$RETAIN_DAILY"
    prune_prefix "${prefix}db-settings/2" "$RETAIN_DAILY"
    prune_prefix "${prefix}weekly/"  "$RETAIN_WEEKLY"
    prune_prefix "${prefix}monthly/" "$RETAIN_MONTHLY"
    write_metrics "$db" "$dump_bytes"
    log "Backup complete: db=$db"
}

# backup_roles: cluster-wide roles (pg_dumpall --roles-only). Owners and grants
# inside the per-DB dumps reference these; restore-db.sh applies it first.
# --no-role-passwords: no hashes in S3 — after a disaster restore, reset LOGIN
# passwords from Secrets Manager / the compose .env.
backup_roles() {
    local f="$DUMP_DIR/globals-${TODAY}.sql.gz"
    docker exec -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" \
        pg_dumpall --roles-only --no-role-passwords | gzip -6 > "$f"
    log "roles dump: $(zcat "$f" | grep -c '^CREATE ROLE') roles"
    aws s3 cp "$f" "s3://$BACKUP_BUCKET/${GLOBALS_PREFIX}daily/${TODAY}.sql.gz" --region "$AWS_REGION" --no-progress
    aws s3 cp "$f" "s3://$BACKUP_BUCKET/${GLOBALS_PREFIX}latest.sql.gz" --region "$AWS_REGION" --no-progress
    rm -f "$f"
    prune_prefix "${GLOBALS_PREFIX}daily/" "$RETAIN_DAILY"
}

# One DB failing must not skip the others, but the run still exits non-zero so
# systemd records the failure.
failed=0
if ! ( set -euo pipefail; backup_roles ); then
    log "ERROR: roles backup failed"
    failed=1
fi
for db in $POSTGRES_DBS; do
    if ! ( set -euo pipefail; backup_one "$db" ); then
        log "ERROR: backup of $db failed"
        failed=1
    fi
done
[ "$failed" = 0 ] && log "All backups complete." || { log "Backup run finished WITH FAILURES."; exit 1; }
