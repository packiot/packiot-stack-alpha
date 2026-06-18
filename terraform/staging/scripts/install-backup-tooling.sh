#!/bin/bash
# install-backup-tooling.sh — one-shot install of nightly DB backup infrastructure
#
# Runs on the DB EC2 (NOT inside the container). Installs:
#   - /opt/packiot/scripts/backup-db.sh
#   - /opt/packiot/scripts/restore-db.sh
#   - /etc/systemd/system/packiot-db-backup.service
#   - /etc/systemd/system/packiot-db-backup.timer
#   - /etc/packiot/backup.env  (consumed by both scripts via EnvironmentFile)
# Then enables and starts the timer.
#
# Why this isn't in db_init.sh: EC2 user_data has a 16 KB hard limit and
# db_init.sh is already near that ceiling. Keeping this as a separate one-shot
# also means we can re-run it safely after a script change without rebooting.
#
# Required env (pass via SSM parameters or set on the calling shell):
#   BACKUP_BUCKET    e.g. packiot-staging-db-backups-639178078294
#   AWS_REGION       e.g. us-east-1
#   DB_NAME          e.g. packiot
#   DB_USER          e.g. postgres
#   GITHUB_PAT       (only needed if fetching scripts from GitHub; if running
#                    after db_init.sh which already cloned to /tmp, we re-use that)
#
# Idempotent — safe to re-run after script updates.
set -euo pipefail

: "${BACKUP_BUCKET:?BACKUP_BUCKET required (e.g. packiot-staging-db-backups-639178078294)}"
: "${AWS_REGION:=us-east-1}"
: "${DB_NAME:=packiot}"
: "${DB_USER:=postgres}"
: "${REPO_PATH:=/opt/packiot/stack/terraform/staging/scripts}"

LOG_TAG="packiot-backup-install"
log() { echo "[$(date -u +%FT%TZ)] $*" | logger -t "$LOG_TAG" -s 2>&1; }

# ── Fetch scripts (either from already-cloned repo or fresh clone) ────────────
if [ -d "$REPO_PATH" ]; then
    log "Using already-cloned repo at $REPO_PATH"
elif [ -n "${GITHUB_PAT:-}" ]; then
    log "Cloning repo with PAT"
    GITHUB_REPO="${GITHUB_REPO:-packiot/packiot-stack-alpha}"
    REPO_URL="https://x-access-token:$GITHUB_PAT@github.com/$GITHUB_REPO.git"
    git clone --depth 1 --no-recurse-submodules "$REPO_URL" /tmp/packiot-stack-bkp
    REPO_PATH="/tmp/packiot-stack-bkp/terraform/staging/scripts"
else
    log "ERROR: no repo at $REPO_PATH and no GITHUB_PAT to clone with"
    exit 1
fi

# ── Install scripts and systemd units ────────────────────────────────────────
mkdir -p /opt/packiot/scripts /etc/packiot
install -m 0755 "$REPO_PATH/backup-db.sh"               /opt/packiot/scripts/
install -m 0755 "$REPO_PATH/restore-db.sh"              /opt/packiot/scripts/
install -m 0644 "$REPO_PATH/packiot-db-backup.service"  /etc/systemd/system/
install -m 0644 "$REPO_PATH/packiot-db-backup.timer"    /etc/systemd/system/
log "Installed backup scripts to /opt/packiot/scripts/ and systemd units to /etc/systemd/system/"

# ── Write env file (consumed by both scripts and the .service EnvironmentFile) ──
cat > /etc/packiot/backup.env <<ENV
BACKUP_BUCKET=$BACKUP_BUCKET
AWS_REGION=$AWS_REGION
POSTGRES_CONTAINER=timescaledb
POSTGRES_USER=$DB_USER
POSTGRES_DB=$DB_NAME
RETAIN_DAILY=14
RETAIN_WEEKLY=4
RETAIN_MONTHLY=3
ENV
chmod 0644 /etc/packiot/backup.env
log "Wrote /etc/packiot/backup.env (bucket=$BACKUP_BUCKET)"

# ── Enable + start timer ────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now packiot-db-backup.timer
log "packiot-db-backup.timer enabled (next: $(systemctl show -p NextElapseUSecRealtime --value packiot-db-backup.timer))"

# ── Apply refined retention SQL (per-table tiers + VACUUM job) ───────────────
# db_init.sh ships with a baseline 90-day retention on equipment_values/events/uns.
# This installer refines that to per-table tiers and adds VACUUM after cleanup.
# Idempotent — cron.schedule() with same job name replaces the existing entry.
log "Applying retention SQL upgrade (30d/90d tiers + VACUUM job)..."
docker exec -i timescaledb psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'RETENTION_SQL'
CREATE OR REPLACE FUNCTION public.cleanup_old_staging_data()
RETURNS void LANGUAGE plpgsql AS $BODY$
DECLARE
    deleted_count int;
    cutoff_ev    TIMESTAMPTZ := NOW() - INTERVAL '30 days';
    cutoff_evt   TIMESTAMPTZ := NOW() - INTERVAL '90 days';
    cutoff_agg   TIMESTAMPTZ := NOW() - INTERVAL '30 days';
    cutoff_uns   TIMESTAMPTZ := NOW() - INTERVAL '30 days';
    cutoff_cron  TIMESTAMPTZ := NOW() - INTERVAL '7 days';
BEGIN
    LOOP BEGIN DELETE FROM equipment_values WHERE ts_value IN (SELECT ts_value FROM equipment_values WHERE ts_value < cutoff_ev LIMIT 5000); GET DIAGNOSTICS deleted_count = ROW_COUNT; EXCEPTION WHEN undefined_table THEN EXIT; END; EXIT WHEN deleted_count = 0; PERFORM pg_sleep(0.05); END LOOP;
    LOOP BEGIN DELETE FROM equipment_events WHERE ts_event IN (SELECT ts_event FROM equipment_events WHERE ts_event < cutoff_evt LIMIT 5000); GET DIAGNOSTICS deleted_count = ROW_COUNT; EXCEPTION WHEN undefined_table THEN EXIT; END; EXIT WHEN deleted_count = 0; PERFORM pg_sleep(0.05); END LOOP;
    LOOP BEGIN DELETE FROM agg_equipment_values_1min_t WHERE ts_value IN (SELECT ts_value FROM agg_equipment_values_1min_t WHERE ts_value < cutoff_agg LIMIT 5000); GET DIAGNOSTICS deleted_count = ROW_COUNT; EXCEPTION WHEN undefined_table THEN EXIT; END; EXIT WHEN deleted_count = 0; PERFORM pg_sleep(0.05); END LOOP;
    LOOP BEGIN DELETE FROM uns_metrics WHERE ts_value IN (SELECT ts_value FROM uns_metrics WHERE ts_value < cutoff_uns LIMIT 5000); GET DIAGNOSTICS deleted_count = ROW_COUNT; EXCEPTION WHEN undefined_table THEN EXIT; END; EXIT WHEN deleted_count = 0; PERFORM pg_sleep(0.05); END LOOP;
    BEGIN DELETE FROM cron.job_run_details WHERE end_time < cutoff_cron; EXCEPTION WHEN OTHERS THEN NULL; END;
END;
$BODY$;

CREATE OR REPLACE FUNCTION public.vacuum_after_cleanup()
RETURNS void LANGUAGE plpgsql AS $BODY$
BEGIN
    BEGIN EXECUTE 'VACUUM (ANALYZE) equipment_values';            EXCEPTION WHEN undefined_table THEN NULL; END;
    BEGIN EXECUTE 'VACUUM (ANALYZE) equipment_events';            EXCEPTION WHEN undefined_table THEN NULL; END;
    BEGIN EXECUTE 'VACUUM (ANALYZE) agg_equipment_values_1min_t'; EXCEPTION WHEN undefined_table THEN NULL; END;
    BEGIN EXECUTE 'VACUUM (ANALYZE) uns_metrics';                 EXCEPTION WHEN undefined_table THEN NULL; END;
    BEGIN EXECUTE 'VACUUM cron.job_run_details';                  EXCEPTION WHEN OTHERS THEN NULL; END;
END;
$BODY$;

SELECT cron.schedule('cleanup-old-data',     '0 3 * * *', 'SELECT public.cleanup_old_staging_data()');
SELECT cron.schedule('vacuum-after-cleanup', '5 3 * * *', 'SELECT public.vacuum_after_cleanup()');
RETENTION_SQL
log "Retention SQL upgrade applied (30d/90d tiers + vacuum-after-cleanup job)"

# ── Cleanup temp clone if we made one ───────────────────────────────────────
[ -d /tmp/packiot-stack-bkp ] && rm -rf /tmp/packiot-stack-bkp

log "Install complete. Test with: sudo systemctl start packiot-db-backup.service && journalctl -u packiot-db-backup.service -n 50"
