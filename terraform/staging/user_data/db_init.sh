#!/bin/bash
# DB EC2 bootstrap — runs TimescaleDB + pg_cron via Docker on AL2023 ARM64.
# Builds the custom postgres image (db/Dockerfile: timescale + pg_cron) locally from
# the packiot-stack-alpha repo rather than pulling from GHCR, which requires
# packages:read PAT scope not currently in the staging PAT.
# Runs once on first boot via EC2 user data. Logs to /var/log/packiot-db-init.log.
set -euo pipefail
exec > >(tee /var/log/packiot-db-init.log | logger -t packiot-db-init) 2>&1

export PATH="/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/bin:$PATH"
export HOME=/root

echo "=== Packiot DB init starting $(date -u) ==="

# ── SSM agent first — gives remote access even if later steps fail ─────────────
dnf install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
echo "SSM agent started"

# ── System update ──────────────────────────────────────────────────────────────
dnf update -y

# ── Tools ─────────────────────────────────────────────────────────────────────
dnf install -y docker git jq
systemctl enable docker
systemctl start docker
echo "Docker + tools installed"

# ── Fetch secrets ─────────────────────────────────────────────────────────────
get_secret() {
  aws secretsmanager get-secret-value \
    --secret-id "$1" \
    --region ${aws_region} \
    --query SecretString \
    --output text
}

DB_SECRET=$(get_secret "packiot/staging/db")
DB_PASS=$(echo "$DB_SECRET" | jq -r '.password')

GITHUB_PAT=$(get_secret "packiot/staging/github-pat" | jq -r '.token')

# ── Clone repo and build image locally ────────────────────────────────────────
# GHCR pull requires packages:read scope; the staging PAT only has repo scope.
# Clone with HTTPS using the PAT (repo scope is sufficient for private repos).
# Only db/ is needed; --no-recurse-submodules skips unneeded submodules.
REPO_URL="https://x-access-token:$GITHUB_PAT@github.com/${github_repo}.git"
git clone --depth 1 --no-recurse-submodules "$REPO_URL" /tmp/packiot-stack
echo "Repo cloned"

docker build \
  --platform linux/arm64 \
  -t packiot-postgres:local \
  /tmp/packiot-stack/db
echo "packiot-postgres image built"

rm -rf /tmp/packiot-stack

# ── Run TimescaleDB + pg_cron via Docker ───────────────────────────────────────
# shared_preload_libraries and cron.database_name must be passed via -c args:
# the timescale Alpine image reads only $PGDATA/postgresql.conf (no conf.d).
#
# IMPORTANT: because shared_preload_libraries is set here via `-c` (the
# postmaster command line), it takes precedence over postgresql.conf AND
# postgresql.auto.conf. `ALTER SYSTEM SET shared_preload_libraries` on the
# running cluster is therefore IGNORED (pg_settings.source = 'command line').
# To change the preloaded library set you MUST edit this line and recreate
# the container (docker rm -f timescaledb && re-run this docker run) — a
# plain `docker restart` reuses the baked-in Config.Cmd and changes nothing.
#
# timescaledb MUST stay first in the list (TimescaleDB requirement).
# pg_stat_statements is preloaded for the DB observability dashboard
# (top/slow-query panels); it is a lightweight in-memory query-stats collector.
mkdir -p /var/lib/postgresql/data

docker run -d \
  --name timescaledb \
  --restart unless-stopped \
  --platform linux/arm64 \
  -p 0.0.0.0:5432:5432 \
  -e POSTGRES_PASSWORD="$DB_PASS" \
  -e POSTGRES_DB=${db_name} \
  -e POSTGRES_USER=${db_user} \
  -e TIMESCALEDB_TELEMETRY=off \
  -v /var/lib/postgresql/data:/var/lib/postgresql/data \
  packiot-postgres:local \
  -c "shared_preload_libraries=timescaledb,pg_cron,pg_stat_statements" \
  -c "cron.database_name=${db_name}"

echo "TimescaleDB container started, waiting for PostgreSQL to accept connections..."
until docker exec timescaledb pg_isready -U ${db_user} 2>/dev/null; do sleep 5; done
echo "PostgreSQL ready"

# ── Create extensions ──────────────────────────────────────────────────────────
# docker-entrypoint-initdb.d/00-init-extensions.sh already runs inside the
# container on first boot, but we guard here too for idempotency.
docker exec timescaledb psql -U ${db_user} -d ${db_name} <<SQL
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_cron;
GRANT USAGE ON SCHEMA cron TO "${db_user}";
-- pg_stat_statements: per-query execution stats for the DB observability
-- dashboard. Requires pg_stat_statements in shared_preload_libraries (above).
-- The shadow DB (packiot_analytics) needs the same CREATE EXTENSION run in it
-- wherever it is provisioned; the preload is cluster-wide so one flag covers
-- both databases.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
echo "Database '${db_name}' ready with TimescaleDB + pg_cron + pg_stat_statements"

# ── OEECloud tables ────────────────────────────────────────────────────────────
# uns_equipment_current_metrics: one row per equipment, tracks latest UNS state.
# The oeecloud UPSERT batch includes this table; if it's missing the entire
# multi-statement transaction rolls back silently (PostgreSQL implicit txn).
docker exec timescaledb psql -U ${db_user} -d ${db_name} <<SQL
CREATE TABLE IF NOT EXISTS public.uns_equipment_current_metrics (
  id_enterprise  INTEGER,
  id_site        INTEGER,
  id_area        INTEGER,
  id_equipment   INTEGER UNIQUE,
  state          INTEGER,
  speed          NUMERIC(12,4),
  updated_at     TIMESTAMPTZ DEFAULT NOW()
);
SQL
echo "OEECloud tables created"

# ── OEE aggregation function + pg_cron job ────────────────────────────────────
# oee_compute_uns_metrics() is the staging equivalent of production's
# piot_proc_refresh_runtime.  It reads the last 5 min of equipment_values,
# computes Quality/Performance/Availability/OEE, and upserts into uns_metrics.
# plpgsql resolves table names at call time, so this is safe to create before
# the app schema is loaded on a fresh deploy — the cron job silently no-ops
# until equipment_values / uns_metrics / equipments exist.
# cron.schedule() is idempotent: same job name replaces the existing entry.
docker exec timescaledb psql -U ${db_user} -d ${db_name} <<'SQL'
CREATE OR REPLACE FUNCTION public.oee_compute_uns_metrics()
RETURNS void
LANGUAGE plpgsql
AS $BODY$
DECLARE
    _now TIMESTAMPTZ := NOW();
BEGIN
    INSERT INTO uns_metrics (
        ts_value, id_enterprise, id_site, id_area, id_equipment,
        metric_name, metric_value, metric_type
    )
    SELECT
        _now,
        agg.id_enterprise, agg.id_site, agg.id_area, agg.id_equipment,
        m.metric_name, m.metric_value, m.metric_type
    FROM (
        SELECT
            ev.id_equipment, ev.id_enterprise, ev.id_site, ev.id_area,
            COALESCE(SUM(ev.net_production_incr), 0)           AS net_prod,
            COALESCE(SUM(ev.scrap_incr),           0)           AS scrap,
            COALESCE(AVG(ev.speed),                0)           AS avg_speed,
            COUNT(*)                                            AS ticks,
            SUM(CASE WHEN ev.state = 6 THEN 1 ELSE 0 END)      AS exec_ticks,
            COALESCE(MAX(e.production_speed),     120)          AS ideal_speed
        FROM equipment_values ev
        JOIN equipments e ON e.id_equipment = ev.id_equipment
        WHERE ev.ts_value > NOW() - INTERVAL '5 minutes'
        GROUP BY ev.id_equipment, ev.id_enterprise, ev.id_site, ev.id_area
    ) agg
    CROSS JOIN LATERAL (
        VALUES
            ('quality_percent',
             CASE WHEN (agg.net_prod + agg.scrap) > 0
                  THEN ROUND(((agg.net_prod / (agg.net_prod + agg.scrap)) * 100)::numeric, 2)
                  ELSE 100.0 END,
             'percent'),
            ('performance_percent',
             CASE WHEN agg.ideal_speed > 0
                  THEN ROUND((LEAST(agg.avg_speed / agg.ideal_speed, 1.0) * 100)::numeric, 2)
                  ELSE 0.0 END,
             'percent'),
            ('availability_percent',
             CASE WHEN agg.ticks > 0
                  THEN ROUND(((agg.exec_ticks::numeric / agg.ticks) * 100)::numeric, 2)
                  ELSE 0.0 END,
             'percent'),
            ('oee_percent',
             CASE WHEN agg.ticks > 0 AND agg.ideal_speed > 0
                  THEN ROUND((
                          (CASE WHEN (agg.net_prod + agg.scrap) > 0
                                THEN agg.net_prod / (agg.net_prod + agg.scrap)
                                ELSE 1.0 END)
                        * LEAST(agg.avg_speed / agg.ideal_speed, 1.0)
                        * (agg.exec_ticks::numeric / agg.ticks)
                        * 100
                  )::numeric, 2)
                  ELSE 0.0 END,
             'percent'),
            ('total_production', ROUND(agg.net_prod::numeric, 0), 'count'),
            ('total_scrap',      ROUND(agg.scrap::numeric,    0), 'count'),
            ('avg_speed',        ROUND(agg.avg_speed::numeric, 2), 'units_per_min')
    ) AS m(metric_name, metric_value, metric_type)
    ON CONFLICT (ts_value, id_equipment, metric_name)
        DO UPDATE SET metric_value = EXCLUDED.metric_value;
END;
$BODY$;

SELECT cron.schedule(
    'oee-compute',
    '* * * * *',
    'SELECT public.oee_compute_uns_metrics()'
);
SQL
echo "OEE function created + pg_cron job scheduled (every minute)"

# ── Periodic data cleanup via pg_cron ────────────────────────────────────
# Deletes staging rows older than 90 days from high-volume time-series tables.
# Uses a function so pg_cron only needs one command string; plpgsql silently
# no-ops if a table doesn't exist yet (fresh deploy before app schema loads).
# cron.schedule() is idempotent: same job name replaces an existing entry.
#
# equipment_values / equipment_events are TimescaleDB hypertables, so retention is
# drop_chunks() — O(chunks) metadata work that is instant and WAL-cheap. The old
# row-by-row `DELETE ... WHERE ts_value IN (SELECT ts_value ... LIMIT 5000)` semi-
# join hash-scanned the whole 12M-row hypertable EVERY batch (worse with the stale
# planner stats left behind by the broken vacuum job below) and blew the 2-min
# statement_timeout. uns_metrics is a plain table, so it uses a single index-driven
# DELETE — NOT a batched loop: a batched loop inside a plpgsql FUNCTION cannot COMMIT
# between batches (only a PROCEDURE can), so dead tuples from earlier batches are not
# reclaimed until the one enclosing txn ends and each later batch re-skips them —
# O(n²). One ranged DELETE on the ts_value index is linear.
#
# statement_timeout: the 2-min cap is armed against the TOP-LEVEL command when it
# arrives, so a `SET LOCAL` in the function body is too late (the timer for the
# enclosing `SELECT cleanup_old_staging_data()` is already ticking). Instead the cron
# COMMAND prepends `SET statement_timeout = 0;` — pg_cron runs that as its own
# statement first, so the following SELECT re-arms with the lifted value. (This trick
# is safe for a function/SELECT but NOT for the bare VACUUM below: a multi-statement
# string executes in one implicit txn, and VACUUM cannot run inside a txn.)
docker exec timescaledb psql -U ${db_user} -d ${db_name} <<'SQL'
CREATE OR REPLACE FUNCTION public.cleanup_old_staging_data()
RETURNS void LANGUAGE plpgsql AS $BODY$
DECLARE
    cutoff_ev   TIMESTAMPTZ := NOW() - INTERVAL '90 days';
    cutoff_uns  TIMESTAMPTZ := NOW() - INTERVAL '90 days';
BEGIN
    -- Hypertables: drop whole chunks older than the cutoff. undefined_table /
    -- undefined_function no-op on a fresh deploy or plain Postgres; any other
    -- error (e.g. table exists but is not a hypertable) falls back to a ranged
    -- DELETE so retention still happens.
    BEGIN
        PERFORM drop_chunks('public.equipment_values', older_than => cutoff_ev);
    EXCEPTION
        WHEN undefined_table OR undefined_function THEN NULL;
        WHEN OTHERS THEN
            BEGIN DELETE FROM equipment_values WHERE ts_value < cutoff_ev;
            EXCEPTION WHEN undefined_table THEN NULL; END;
    END;

    BEGIN
        PERFORM drop_chunks('public.equipment_events', older_than => cutoff_ev);
    EXCEPTION
        WHEN undefined_table OR undefined_function THEN NULL;
        WHEN OTHERS THEN
            BEGIN DELETE FROM equipment_events WHERE ts_event < cutoff_ev;
            EXCEPTION WHEN undefined_table THEN NULL; END;
    END;

    -- Plain table: single linear index-driven DELETE (timeout lifted by the cron
    -- command prepend). Left dead tuples are reclaimed by the vacuum job below.
    BEGIN
        DELETE FROM uns_metrics WHERE ts_value < cutoff_uns;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;
END;
$BODY$;

SELECT cron.schedule(
    'cleanup-old-data',
    '0 3 * * *',
    'SET statement_timeout = 0; SELECT public.cleanup_old_staging_data()'
);
SQL
echo "pg_cron daily cleanup registered (03:00 UTC, keeps last 90 days of equipment_values / equipment_events / uns_metrics)"

# ── VACUUM (ANALYZE) after the cleanup, as a TOP-LEVEL command ─────────────
# VACUUM cannot run inside a transaction block, and pg_cron wraps every job in a
# txn — so it CANNOT be wrapped in a function/CALL/DO (that is exactly what the
# earlier `SELECT vacuum_after_cleanup()` job did, and it failed every night with
# "VACUUM cannot run inside a transaction block"). Scheduling a bare VACUUM string
# lets pg_cron run it directly, outside a txn. Runs at 03:05, after cleanup (03:00),
# to reclaim dead tuples and — critically — refresh planner stats so the cleanup
# semi-scans and the OEE queries do not fall back to seq scans on stale statistics.
docker exec timescaledb psql -U ${db_user} -d ${db_name} <<'SQL'
SELECT cron.schedule(
    'vacuum-after-cleanup',
    '5 3 * * *',
    'VACUUM (ANALYZE) public.equipment_values, public.equipment_events, public.uns_metrics'
);
SQL
echo "pg_cron VACUUM (ANALYZE) registered (03:05 UTC, bare top-level VACUUM)"

# ── OEE engine orchestrator via pg_cron ───────────────────────────────────
# piot_proc_refresh_runtime (db/20-oee-engine-parity.sql) is prod's master OEE
# orchestrator: drains production_orders_runtime.recalc_needed and fills the
# equipment/area/site runtime tables. It is a PROCEDURE with internal COMMITs,
# so it MUST be scheduled as a top-level CALL — wrapping it in a guard function
# would fail with "invalid transaction termination". On a fresh deploy the runs
# fail (recorded in cron.job_run_details) until the app schema loads; harmless.
# cron.schedule() is idempotent: same job name replaces an existing entry.
docker exec timescaledb psql -U ${db_user} -d ${db_name} <<'SQL'
SELECT cron.schedule(
    'oee-refresh-runtime',
    '* * * * *',
    'CALL piot_proc_refresh_runtime();'
);
SQL
echo "pg_cron OEE orchestrator registered (every minute: CALL piot_proc_refresh_runtime)"

echo "=== DB init complete $(date -u) ==="
