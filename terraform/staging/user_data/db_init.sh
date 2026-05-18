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
  -c "shared_preload_libraries=timescaledb,pg_cron" \
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
SQL
echo "Database '${db_name}' ready with TimescaleDB + pg_cron"

echo "=== DB init complete $(date -u) ==="
