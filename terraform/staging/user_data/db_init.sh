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
# ADR-0063 end state (2026-10-15): no timescaledb — packiot_analytics has no TimescaleDB objects
# and the F1 `packiot` database was decommissioned; pg_cron's home is the `postgres` database.
# pg_stat_statements is preloaded for the DB observability dashboard
# (top/slow-query panels); it is a lightweight in-memory query-stats collector.
mkdir -p /var/lib/postgresql/data
# MEMORY OVERCOMMIT (2026-09-24): strict accounting (PostgreSQL docs "Linux Memory
# Overcommit"). With the default heuristic mode a runaway backend (7 GB chunk-wise
# aggregate, 11:23 incident) was SIGKILLed by the kernel OOM-killer → postmaster must
# reset ALL sessions + crash-recover. Mode 2 makes that backend get "out of memory" and
# only its query fails. Ratio 90 → CommitLimit = swap + 90% RAM (~16.5 GB on r7g.large);
# the default 50 (~10.1 GB) sits BELOW normal Committed_AS (~9.6 GB) and would refuse
# ordinary allocations.
cat > /etc/sysctl.d/60-postgres-overcommit.conf <<'SYSCTL'
vm.overcommit_memory = 2
vm.overcommit_ratio = 90
SYSCTL
sysctl -q -p /etc/sysctl.d/60-postgres-overcommit.conf


# LOG ROTATION (2026-09-24): the container ran with an unbounded json-file log —
# log_min_duration_statement=3000 + auto_explain grew it to 28.8 GB (more than half the
# disk's "used" 51 GB), and the DB-box Alloy agent re-reading it pegged a CPU on this
# 2-vCPU box. 5 × 200 MB caps it at 1 GB; slow-query history lives in Loki (relay).
# Like every flag here, it applies on container RECREATE (maintenance window).
# SHM (2026-09-24): Docker's default /dev/shm is 64 MB; Postgres parallel workers
# allocate dynamic shared memory there → "could not resize shared memory segment …
# No space left on device" on large parallel hash joins. 1 GB (≈ the parallel-query
# working set on this 15 GB box).
docker run -d \
  --name timescaledb \
  --restart unless-stopped \
  --log-driver json-file --log-opt max-size=200m --log-opt max-file=5 \
  --shm-size=1g \
  --platform linux/arm64 \
  -p 0.0.0.0:5432:5432 \
  -e POSTGRES_PASSWORD="$DB_PASS" \
  -e POSTGRES_DB=${db_name} \
  -e POSTGRES_USER=${db_user} \
  -e TIMESCALEDB_TELEMETRY=off \
  -v /var/lib/postgresql/data:/var/lib/postgresql/data \
  packiot-postgres:local \
  -c "shared_preload_libraries=pg_cron,pg_stat_statements,auto_explain" \
  -c "cron.database_name=postgres" \
  -c "max_connections=200" \
  -c "pg_stat_statements.max=10000" -c "pg_stat_statements.track=all" \
  -c "auto_explain.log_min_duration=3000" -c "auto_explain.log_analyze=on" \
  -c "auto_explain.log_nested_statements=on" \
  -c "log_min_duration_statement=3000" -c "track_io_timing=on" -c "log_checkpoints=on" \
  -c "log_lock_waits=on" -c "log_autovacuum_min_duration=0" \
  -c "log_line_prefix=%m [%p] %u@%d %a "
# The observability flags above (auto_explain, pg_stat_statements.track=all, lock-wait /
# checkpoint / autovacuum logging) were LIVE-only until the 2026-09-24 recreate — codified
# here so a rebuilt box keeps the slow-query + nested-statement visibility the DB dashboards
# and incident work rely on (track=all is what exposes statements inside procedures).
# max_connections raised 50→200 (2026-09-22): staging has no server-side headroom —
# a near-idle stack already sat at 49/50 (analytics pool 24 + Superset 14 [bypasses
# pgbouncer] + misc 11), so any load test / new tenant hit "too many connections".
# r7g.large has 15GiB RAM; +150 backends ≈ +1.4GiB worst-case, well within headroom.
# Set here as a -c flag (postmaster command line) so it survives a container RECREATE,
# not just a restart — this line overrides postgresql.conf AND postgresql.auto.conf.

echo "TimescaleDB container started, waiting for PostgreSQL to accept connections..."
until docker exec timescaledb pg_isready -U ${db_user} 2>/dev/null; do sleep 5; done
echo "PostgreSQL ready"

# ── Create extensions ──────────────────────────────────────────────────────────
# pg_cron lives in `postgres` (cron.database_name above) and schedules into packiot_analytics with
# cron.schedule_in_database — scripts/ops/adr0063-c2-pgcron-jobs.sql registers those jobs once the
# analytics database is restored. pg_stat_statements: per-query stats for the DB dashboards (the
# preload is cluster-wide; packiot_analytics creates its own copy of the extension via its schema).
# The F1 objects this script used to create in `packiot` (uns_* tables, oee_compute_uns_metrics,
# cleanup_old_staging_data with drop_chunks, the VACUUM job, piot_proc_refresh_runtime) were retired
# with that database (2026-10-15).
docker exec timescaledb psql -U ${db_user} -d postgres <<SQL
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT cron.schedule('cleanup-cron-job-run-details', '15 3 * * *',
       \$\$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'\$\$);
SQL
echo "postgres database ready with pg_cron + pg_stat_statements"

echo "=== DB init complete $(date -u) ==="
