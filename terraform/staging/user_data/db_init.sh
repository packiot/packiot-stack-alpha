#!/bin/bash
# DB EC2 bootstrap — runs TimescaleDB via Docker on AL2023 ARM64.
# TimescaleDB has no native aarch64 RPMs for EL9; timescale/timescaledb:latest-pg15
# is multi-arch (arm64 + amd64) and is the correct image for this host.
# NOTE: timescaledb-ha is amd64-only and MUST NOT be used on Graviton.
# pg_cron is not included in this image; OEE aggregate refreshes run manually
# until a custom image that adds pg_cron is adopted.
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
# timescaledb-ha includes pg_cron and is multi-arch (arm64 + amd64).
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
  timescale/timescaledb:latest-pg15

echo "TimescaleDB container started, waiting for PostgreSQL to accept connections..."
until docker exec timescaledb pg_isready -U ${db_user} 2>/dev/null; do sleep 5; done
echo "PostgreSQL ready"

# ── Create extensions ──────────────────────────────────────────────────────────
docker exec timescaledb psql -U ${db_user} -d ${db_name} <<SQL
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
SQL
echo "Database '${db_name}' ready with TimescaleDB"

echo "=== DB init complete $(date -u) ==="
