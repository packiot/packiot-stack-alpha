#!/bin/bash
# DB EC2 bootstrap — runs TimescaleDB + pg_cron via Docker on AL2023 ARM64.
# Uses ghcr.io/packiot/packiot-postgres:latest — a custom image built from
# db/Dockerfile that compiles pg_cron from source on top of the official
# timescale/timescaledb:latest-pg15 Alpine base.
# Built by .github/workflows/build-postgres.yml on push to main.
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

# ── Docker ─────────────────────────────────────────────────────────────────────
dnf install -y docker
systemctl enable docker
systemctl start docker
echo "Docker installed"

# ── Fetch DB password from Secrets Manager ────────────────────────────────────
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id packiot/staging/db \
  --region ${aws_region} \
  --query SecretString \
  --output text)

DB_PASS=$(echo "$DB_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# ── Run TimescaleDB + pg_cron via Docker ───────────────────────────────────────
# Custom image adds pg_cron on top of the official timescale base (see db/Dockerfile).
# Port 5432 exposed on all interfaces; security group restricts access to App SG.
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
  ghcr.io/packiot/packiot-postgres:latest

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
