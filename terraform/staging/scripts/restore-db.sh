#!/bin/bash
# restore-db.sh — restore a staging PostgreSQL database from its S3 backup
#
# Restores into a SIDE database (<db>__restoring), VERIFIES it (error gate +
# catalog gate vs the live DB), and only then swaps it in by rename. The
# previous database is kept (renamed, connections disabled) until you drop it,
# so a failed or wrong restore never destroys the live data.
#
# This is the one restore path: the "EMERGENCY – restore database" GitHub
# workflow (.github/workflows/emergency-db-restore.yml) calls it, and the manual
# fallback in docs/runbooks/emergency-db-restore.md is the same command.
#
# Usage:
#   ./restore-db.sh [--db NAME] <s3-key|latest> [--yes-i-am-sure] [MODE] [--old-name NAME] [--restart-container]
#
#   MODE (default: full restore = side DB → verify → swap):
#     --drill      side DB → verify → DROP the side DB. Proves the backup restores;
#                  never touches the live DB (only reads its catalog to compare).
#     --no-swap    side DB → verify → leave <db>__restoring in place (inspect it).
#     --swap-only  skip the restore: swap in an already-VERIFIED <db>__restoring
#                  (left by --no-swap). Lets a caller stop writers only for the
#                  seconds the swap takes instead of the whole restore.
#   --db NAME          database (default: packiot). packiot backups live at the
#                      bucket root; every other DB under <db>/ (see backup-db.sh).
#   --old-name NAME    name for the displaced live DB (default <db>__pre_restore_<ts>).
#   --restart-container  after the swap, `docker restart` the Postgres container
#                      (TimescaleDB / pg_cron workers stay bound to the renamed DB
#                      otherwise) and re-check the restored DB.
#
# Env: BACKUP_BUCKET (required), POSTGRES_CONTAINER (timescaledb), POSTGRES_USER,
#      GLOBALS_KEY (globals/latest.sql.gz; the hist-gateway cluster has its own,
#      see /etc/packiot/historian-backup.env), BACKUP_KEY_PREFIX (""),
#      MAX_RESTORE_ERRORS (0),
#      VERIFY_TABLES (space-separated schema.table; per-DB defaults below),
#      CATALOG_GATE (strict = restored catalog must equal live, the default;
#      report = print the diff but do not block — for when the live DB itself is
#      the damaged thing you are restoring over, e.g. dropped tables).
#
# Examples:
#   ./restore-db.sh --db packiot_analytics latest                             # dry run
#   ./restore-db.sh --db packiot_analytics latest --yes-i-am-sure --drill
#   ./restore-db.sh --db packiot_analytics daily/2026-09-29.dump.gz --yes-i-am-sure \
#       --old-name packiot_analytics_pre_emergency_202609301200 --restart-container
#
# TimescaleDB: if the dump contains the timescaledb extension, the side DB is
# wrapped in timescaledb_pre_restore() / timescaledb_post_restore() (required,
# or hypertable catalog triggers fire during COPY and the restore breaks).
#
# Roles: owners + GRANTs are in the dump (since 2026-09-29) and reference the
# cluster roles in s3://$BACKUP_BUCKET/$GLOBALS_KEY, applied first ("already
# exists" is expected on a live cluster). Older --no-owner dumps restore
# superuser-owned: RLS definer views then BYPASS RLS — the catalog gate below
# (non-superuser-owned views, forced-RLS tables, policies must equal live)
# refuses to swap such a restore in.
set -euo pipefail

: "${POSTGRES_CONTAINER:=timescaledb}"
: "${POSTGRES_USER:=postgres}"
: "${BACKUP_BUCKET:?BACKUP_BUCKET env var required (try: source /etc/packiot/backup.env)}"
: "${AWS_REGION:=us-east-1}"
: "${GLOBALS_KEY:=globals/latest.sql.gz}"
# Disk, not /tmp: /tmp on the DB host is a 7.7 GB RAM tmpfs.
: "${DUMP_DIR:=/var/lib/packiot-backup}"
: "${CATALOG_GATE:=strict}"
# Must match the BACKUP_KEY_PREFIX the backup was written with (backup-db.sh).
: "${BACKUP_KEY_PREFIX:=}"

DB=packiot; KEY=""; CONFIRM=""; MODE=full; OLD=""; RESTART=0
while [ $# -gt 0 ]; do
    case "$1" in
        --db) DB="$2"; shift 2 ;;
        --yes-i-am-sure) CONFIRM=1; shift ;;
        --no-swap) MODE=noswap; shift ;;
        --drill) MODE=drill; shift ;;
        --swap-only) MODE=swaponly; shift ;;
        --old-name) OLD="$2"; shift 2 ;;
        --restart-container) RESTART=1; shift ;;
        -*) echo "unknown flag: $1"; exit 2 ;;
        *) KEY="$1"; shift ;;
    esac
done
case "$DB" in *[!a-z0-9_]*|"") echo "invalid --db '$DB'"; exit 2 ;; esac
case "$OLD" in *[!a-z0-9_]*) echo "invalid --old-name '$OLD'"; exit 2 ;; esac

if [ -z "${VERIFY_TABLES+x}" ]; then
    case "$DB" in
        packiot_analytics) VERIFY_TABLES="core.enterprises core.sites core.areas core.equipments core.packml_register core.shifts core.production_orders identity.users config.production_targets gold.equipment_oee_shift" ;;
        packiot_historian) VERIFY_TABLES="cold.promoted_enterprise cold.ev_union_boundary cold.ee_union_boundary cold.po_union_boundary cold.cold_append_watermark cold.ev_daily_watermark" ;;
        superset)          VERIFY_TABLES="public.ab_user public.dashboards public.slices public.tables public.dbs" ;;
        *)                 VERIFY_TABLES="" ;;
    esac
fi

PREFIX="$BACKUP_KEY_PREFIX"; [ "$DB" != "packiot" ] && PREFIX="$BACKUP_KEY_PREFIX$DB/"
SIDE="${DB}__restoring"
T_START=$(date +%s)
log() { echo "[$(date -u +%FT%TZ)] $*"; }
psql_c() { docker exec -i -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 -At "$@"; }
db_exists() { [ "$(psql_c -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$1'")" = 1 ]; }

# catalog <db>: the invariants a faithful restore must reproduce exactly
# (key|value lines). Row counts are reported separately, not gated: the live DB
# keeps moving after the dump.
catalog() {
    local q="
SELECT 'policies|'||count(*) FROM pg_policies;
SELECT 'rls_enabled_tables|'||count(*) FROM pg_class WHERE relrowsecurity;
SELECT 'rls_forced_tables|'||count(*) FROM pg_class WHERE relforcerowsecurity;
SELECT 'nonsuperuser_owned_views|'||count(*) FROM pg_class c JOIN pg_roles r ON r.oid=c.relowner WHERE c.relkind='v' AND NOT r.rolsuper;
SELECT 'extensions|'||string_agg(extname, ',' ORDER BY extname) FROM pg_extension;
SELECT 'db_settings|'||coalesce(string_agg(coalesce(r.rolname,'*')||':'||c, ';' ORDER BY r.rolname NULLS FIRST, c), '')
  FROM pg_db_role_setting s LEFT JOIN pg_roles r ON r.oid=s.setrole, unnest(s.setconfig) c
 WHERE s.setdatabase=(SELECT oid FROM pg_database WHERE datname=current_database());
SELECT 'objects.'||n.nspname||'.'||c.relkind::text||'|'||count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname !~ '^(pg_|_timescaledb|timescaledb_|information_schema)' AND c.relkind IN ('r','p','v','m','f')
 GROUP BY n.nspname, c.relkind ORDER BY 1;"
    if [ "$(psql_c -d "$1" -c "SELECT count(*) FROM pg_extension WHERE extname='timescaledb'")" = 1 ]; then
        q="$q
SELECT 'hypertables|'||count(*) FROM timescaledb_information.hypertables;
SELECT 'continuous_aggregates|'||count(*) FROM timescaledb_information.continuous_aggregates;
SELECT 'timescale_jobs|'||count(*) FROM timescaledb_information.jobs;"
    fi
    psql_c -d "$1" -c "$q"
}
rowcount() { psql_c -d "$1" -c "SELECT count(*) FROM $2" 2>/dev/null || echo "n/a"; }

# ── swap (shared by full restore and --swap-only) ────────────────────────────
do_swap() {
    [ -n "$OLD" ] || OLD="${DB}__pre_restore_$(date -u +%Y%m%d%H%M)"
    db_exists "$OLD" && { log "ERROR: $OLD already exists; pick another --old-name"; exit 1; }
    log "Swapping: $DB → $OLD, $SIDE → $DB"
    # ALLOW_CONNECTIONS false BEFORE terminating, on both sides: otherwise a pooled
    # client (or the TimescaleDB scheduler on the side DB) reconnects between the
    # terminate and the RENAME, and the rename fails with "being accessed by other users".
    psql_c -d postgres -c "ALTER DATABASE \"$SIDE\" WITH ALLOW_CONNECTIONS false"
    if db_exists "$DB"; then
        if ! psql_c -d postgres <<SQL
ALTER DATABASE "$DB" WITH ALLOW_CONNECTIONS false;
SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname IN ('$DB', '$SIDE') AND pid <> pg_backend_pid();
ALTER DATABASE "$DB" RENAME TO "$OLD";
SQL
        then
            # Rename failed (a backend would not die within RENAME's 5 s wait): undo the
            # connection lock so the live DB keeps serving, and stop.
            psql_c -d postgres -c "ALTER DATABASE \"$DB\" WITH ALLOW_CONNECTIONS true" || true
            log "ERROR: could not rename $DB; nothing swapped, live DB re-opened. Retry with --swap-only."
            exit 1
        fi
        # The displaced DB stays connection-disabled: nothing may keep writing to it.
    else
        psql_c -d postgres -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname='$SIDE' AND pid <> pg_backend_pid()"
        OLD="(none — $DB did not exist)"
    fi
    psql_c -d postgres -c "ALTER DATABASE \"$SIDE\" RENAME TO \"$DB\"" \
                       -c "ALTER DATABASE \"$DB\" WITH ALLOW_CONNECTIONS true" \
                       -c "COMMENT ON DATABASE \"$DB\" IS NULL"
    log "Swap done. Previous database kept as $OLD (ALLOW_CONNECTIONS false)."
    if [ "$RESTART" = 1 ]; then
        log "Restarting container $POSTGRES_CONTAINER (rebinds TimescaleDB/pg_cron workers)"
        docker restart "$POSTGRES_CONTAINER" >/dev/null
        for _ in $(seq 90); do
            [ "$(psql_c -d "$DB" -c 'SELECT 1' 2>/dev/null)" = 1 ] && break; sleep 2
        done
        psql_c -d "$DB" -c "SELECT 'post-restart: connected to '||current_database()||', size '||pg_size_pretty(pg_database_size(current_database()))"
    fi
    cat <<EOF

ROLLBACK (put the displaced DB back):
  docker exec -i $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d postgres <<'SQL'
  ALTER DATABASE "$DB" WITH ALLOW_CONNECTIONS false;
  SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB';
  ALTER DATABASE "$DB" RENAME TO "${DB}__rolled_back";
  ALTER DATABASE "$OLD" WITH ALLOW_CONNECTIONS true;
  ALTER DATABASE "$OLD" RENAME TO "$DB";
SQL
  then: docker restart $POSTGRES_CONTAINER
POST-RESTORE CHECKLIST:
  1. Roles created fresh by the globals file have NO passwords (not stored in S3):
     ALTER ROLE <login role> PASSWORD '...' from Secrets Manager / compose .env.
  2. $( [ "$RESTART" = 1 ] && echo "Container restarted." || echo "RESTART the container: docker restart $POSTGRES_CONTAINER" )
     Then: SELECT * FROM timescaledb_information.job_stats;  (Timescale DBs)
  3. Watch stream-engine / edge-api / read-api logs for reconnection errors.
  4. Data written after the backup was taken is NOT in the restored DB; if the
     displaced DB is readable, recover it from $OLD. When satisfied: DROP DATABASE "$OLD";
EOF
}

if [ "$MODE" = swaponly ]; then
    [ -n "$CONFIRM" ] || { echo "--swap-only needs --yes-i-am-sure"; exit 2; }
    db_exists "$SIDE" || { log "ERROR: $SIDE does not exist — run with --no-swap first"; exit 1; }
    marker=$(psql_c -d postgres -c "SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname='$SIDE'")
    case "$marker" in verified*) log "$SIDE carries marker: $marker" ;;
        *) log "ERROR: $SIDE was not verified by restore-db.sh (comment='$marker'); refusing to swap"; exit 1 ;; esac
    do_swap
    log "SUMMARY: mode=swap-only db=$DB swapped_in=$SIDE displaced=$OLD wall=$(( $(date +%s) - T_START ))s"
    exit 0
fi

if [ -z "$KEY" ]; then
    echo "usage: $0 [--db NAME] <s3-key|latest> [--yes-i-am-sure] [--drill|--no-swap|--swap-only] [--old-name NAME] [--restart-container]"
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

read -r BACKUP_BYTES BACKUP_MTIME < <(aws s3api head-object --bucket "$BACKUP_BUCKET" --key "$KEY" --region "$AWS_REGION" \
    --query '[ContentLength,LastModified]' --output text 2>/dev/null) || { echo "ERROR: backup not found at $S3_URI"; exit 1; }
BACKUP_AGE_H=$(( ( $(date +%s) - $(date -d "$BACKUP_MTIME" +%s) ) / 3600 ))
log "Backup found: $S3_URI ($BACKUP_BYTES bytes, uploaded $BACKUP_MTIME = ${BACKUP_AGE_H}h ago)"

if [ -z "$CONFIRM" ]; then
    cat <<EOF

DRY RUN — no changes made.

Would restore '$DB' on container '$POSTGRES_CONTAINER' from $S3_URI
into side database '$SIDE', verify it, then $(case $MODE in
  full) echo "swap it in by rename (current '$DB' kept as ${OLD:-${DB}__pre_restore_<ts>})" ;;
  drill) echo "DROP the side database (drill)" ;;
  noswap) echo "STOP (--no-swap)" ;; esac).

Needs roughly $((BACKUP_BYTES * 20 / 1073741824 + 1)) GB free on the DB volume. Re-run with --yes-i-am-sure to proceed.
EOF
    exit 0
fi

mkdir -p "$DUMP_DIR"
LOCAL_DUMP="$DUMP_DIR/restore-${DB}-$(date +%s).dump.gz"
TOC="$DUMP_DIR/restore-${DB}.toc"
trap 'rm -f "$LOCAL_DUMP" "$TOC"' EXIT
NEED_KB=$(( BACKUP_BYTES * 20 / 1024 ))
AVAIL_KB=$(df -Pk "$DUMP_DIR" | awk 'NR==2 {print $4}')
[ "$AVAIL_KB" -gt "$NEED_KB" ] || { log "ERROR: ${AVAIL_KB} KB free < ~${NEED_KB} KB needed (20x the gz)"; exit 1; }

log "Downloading $S3_URI → $LOCAL_DUMP"
aws s3 cp "$S3_URI" "$LOCAL_DUMP" --region "$AWS_REGION" --no-progress
gzip -t "$LOCAL_DUMP" || { log "ERROR: dump is not a valid gzip"; exit 1; }

# SIGPIPE traps (both hit in the 2026-09-29 drill): `pg_restore --list` reads only
# the TOC at the head of the dump and exits, and `grep -q` exits at the first match;
# either way gunzip upstream dies of SIGPIPE and, under pipefail, the pipeline
# "fails". So: the upstream gunzip is allowed to die, the TOC must be non-empty,
# and the grep reads a file.
{ gunzip -c "$LOCAL_DUMP" 2>/dev/null || true; } | docker exec -i "$POSTGRES_CONTAINER" pg_restore --list > "$TOC"
[ -s "$TOC" ] || { log "ERROR: could not read the dump's table of contents"; exit 1; }
IS_TSDB=0
grep -q 'EXTENSION - timescaledb' "$TOC" && IS_TSDB=1
log "TimescaleDB dump: $IS_TSDB"

T_RESTORE=$(date +%s)
log "Creating side database $SIDE"
psql_c -d postgres -c "DROP DATABASE IF EXISTS \"$SIDE\" WITH (FORCE)"
psql_c -d postgres -c "CREATE DATABASE \"$SIDE\""
if [ "$IS_TSDB" = 1 ]; then
    psql_c -d "$SIDE" -c "CREATE EXTENSION IF NOT EXISTS timescaledb" -c "SELECT timescaledb_pre_restore()" >/dev/null
fi

log "Applying cluster roles from s3://$BACKUP_BUCKET/$GLOBALS_KEY"
aws s3 cp "s3://$BACKUP_BUCKET/$GLOBALS_KEY" - --region "$AWS_REGION" --no-progress | gunzip \
    | docker exec -i -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" psql -q -d postgres 2>&1 \
    | grep -v 'already exists' || true

# Single-threaded: pg_restore can only parallelise (-j) from a seekable file,
# not from stdin. Not --exit-on-error: every error is counted and gated before
# the swap (MAX_RESTORE_ERRORS, default 0), and you get the whole list.
log "pg_restore into $SIDE (single stream)"
ERR_LOG="$DUMP_DIR/restore-${DB}.err"
set +e
gunzip -c "$LOCAL_DUMP" | docker exec -i -e "PGUSER=$POSTGRES_USER" "$POSTGRES_CONTAINER" \
    pg_restore --dbname="$SIDE" 2> "$ERR_LOG"
set -e
ERRS=$(grep -c '^pg_restore: error' "$ERR_LOG" || true)
log "pg_restore finished with $ERRS error(s) — full log: $ERR_LOG"
grep -A1 '^pg_restore: error' "$ERR_LOG" | head -20 || true

[ "$IS_TSDB" = 1 ] && psql_c -d "$SIDE" -c "SELECT timescaledb_post_restore()" >/dev/null
# Database-level settings (search_path!) are not in pg_dump: they sit in
# pg_db_role_setting keyed by DB OID, so neither the restore nor the rename swap
# carries them. Copy them from the live DB when it exists (current truth), else
# from the settings file backup-db.sh saved next to the dump.
SETTINGS_SQL="$DUMP_DIR/restore-${DB}.settings.sql"
if db_exists "$DB"; then
    SETTINGS_SRC="live $DB"
    psql_c -d postgres -v db="$DB" > "$SETTINGS_SQL" <<'SQL'
SELECT CASE WHEN s.setrole = 0 THEN 'ALTER DATABASE __TARGET_DB__ SET '
            ELSE format('ALTER ROLE %I IN DATABASE __TARGET_DB__ SET ', r.rolname) END
    || quote_ident(split_part(c, '=', 1)) || ' TO '
    || CASE WHEN split_part(c, '=', 1) IN ('search_path', 'temp_tablespaces', 'session_preload_libraries',
                                           'local_preload_libraries', 'shared_preload_libraries')
            THEN substr(c, strpos(c, '=') + 1) ELSE quote_literal(substr(c, strpos(c, '=') + 1)) END || ';'
FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase
LEFT JOIN pg_roles r ON r.oid = s.setrole, unnest(s.setconfig) AS c
WHERE d.datname = :'db' ORDER BY 1;
SQL
else
    SETTINGS_SRC="s3://$BACKUP_BUCKET/${PREFIX}db-settings/latest.sql"
    aws s3 cp "$SETTINGS_SRC" "$SETTINGS_SQL" --region "$AWS_REGION" --no-progress \
        || { log "WARNING: no saved db-level settings at $SETTINGS_SRC — set search_path etc. by hand"; : > "$SETTINGS_SQL"; }
fi
log "Applying $(grep -c . "$SETTINGS_SQL" || true) db-level setting(s) from $SETTINGS_SRC to $SIDE"
sed "s/__TARGET_DB__/\"$SIDE\"/g" "$SETTINGS_SQL" | psql_c -d postgres
rm -f "$SETTINGS_SQL"

log "ANALYZE $SIDE"
psql_c -d "$SIDE" -c "ANALYZE"
RESTORE_S=$(( $(date +%s) - T_RESTORE ))
SIDE_SIZE=$(psql_c -d "$SIDE" -c "SELECT pg_size_pretty(pg_database_size(current_database()))")
log "Restored $SIDE: $SIDE_SIZE in ${RESTORE_S}s"

# ── Verify gate ──────────────────────────────────────────────────────────────
GATE=0
if db_exists "$DB"; then
    log "Catalog gate: $SIDE vs live $DB (must be identical)"
    if diff <(catalog "$DB") <(catalog "$SIDE") > "$DUMP_DIR/restore-${DB}.catalog.diff"; then
        log "  catalog identical ($(catalog "$SIDE" | wc -l) invariants: RLS policies/forced tables, view owners, extensions, objects per schema$( [ "$IS_TSDB" = 1 ] && echo ', hypertables, caggs, jobs'))"
    else
        log "  CATALOG MISMATCH (<live >restored):"; sed 's/^/    /' "$DUMP_DIR/restore-${DB}.catalog.diff"
        if [ "$CATALOG_GATE" = report ]; then log "  CATALOG_GATE=report: not blocking"; else GATE=1; fi
    fi
else
    log "Live $DB does not exist — no catalog comparison possible; restored catalog:"
    catalog "$SIDE" | grep -v '^objects\.' | sed 's/^/    /'
fi
if [ -n "$VERIFY_TABLES" ]; then
    log "Key tables (restored vs live; live has moved on since the backup):"
    printf '    %-40s %14s %14s\n' table restored live
    for t in $VERIFY_TABLES; do
        r=$(rowcount "$SIDE" "$t"); l="-"; db_exists "$DB" && l=$(rowcount "$DB" "$t")
        printf '    %-40s %14s %14s\n' "$t" "$r" "$l"
        # An empty or missing key table the live DB has rows in = a broken restore.
        if [ "$l" != "-" ] && [ "$l" != "n/a" ] && [ "$l" -gt 0 ] && { [ "$r" = "n/a" ] || [ "$r" -eq 0 ]; }; then
            log "  GATE: $t is empty/missing in the restore but has $l rows live"; GATE=1
        fi
    done
fi
[ "$ERRS" -gt "${MAX_RESTORE_ERRORS:-0}" ] && { log "GATE: $ERRS restore errors > MAX_RESTORE_ERRORS=${MAX_RESTORE_ERRORS:-0}"; GATE=1; }

summary() {
    log "SUMMARY: mode=$MODE db=$DB backup=$S3_URI backup_age=${BACKUP_AGE_H}h (RPO) restore=${RESTORE_S}s total=$(( $(date +%s) - T_START ))s (RTO) size=$SIDE_SIZE errors=$ERRS gate=$([ "$GATE" = 0 ] && echo PASS || echo FAIL) $*"
}

if [ "$GATE" != 0 ]; then
    summary "result=NOT_SWAPPED"
    log "ERROR: verify gate failed; $SIDE left in place for inspection (it is dropped by the next run)."
    exit 1
fi
psql_c -d postgres -c "COMMENT ON DATABASE \"$SIDE\" IS 'verified by restore-db.sh $(date -u +%FT%TZ) from $KEY'"

case "$MODE" in
    drill)
        psql_c -d postgres -c "DROP DATABASE \"$SIDE\" WITH (FORCE)"
        summary "result=DRILL_PASSED side_db=dropped"; exit 0 ;;
    noswap)
        summary "result=VERIFIED_NOT_SWAPPED side_db=$SIDE"
        log "Swap it in with: $0 --db $DB --swap-only --yes-i-am-sure [--old-name NAME] [--restart-container]"
        exit 0 ;;
esac
do_swap
summary "result=SWAPPED displaced=$OLD"
