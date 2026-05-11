#!/bin/bash
# DB EC2 bootstrap — installs PostgreSQL 15 + TimescaleDB + pg_cron on AL2023 ARM64.
# Runs once on first boot via EC2 user data. Logs to /var/log/packiot-db-init.log.
set -euo pipefail
exec > >(tee /var/log/packiot-db-init.log | logger -t packiot-db-init) 2>&1

echo "=== Packiot DB init starting $(date -u) ==="

# ── System update ──────────────────────────────────────────────────────────────
dnf update -y

# ── PostgreSQL 15 (AL2023 ships pg15 in standard repos) ───────────────────────
dnf install -y postgresql15 postgresql15-server postgresql15-contrib

postgresql-15-setup initdb
echo "PostgreSQL 15 initialised"

# ── TimescaleDB ────────────────────────────────────────────────────────────────
# packagecloud.io hosts pre-built RPMs for EL9/aarch64.
# TimescaleDB IS NOT available on RDS — this is why we use EC2.
curl -s https://packagecloud.io/install/repositories/timescale/timescaledb/script.rpm.sh \
  | bash
dnf install -y timescaledb-2-postgresql-15
echo "TimescaleDB installed"

# ── pg_cron ────────────────────────────────────────────────────────────────────
# pg_cron runs SQL jobs on a schedule inside PostgreSQL itself.
# The OEE stored procs use it for continuous aggregate refresh.
dnf install -y pg_cron_15 2>/dev/null || {
  # PGDG fallback for pg_cron if packagecloud doesn't carry it
  dnf install -y \
    https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-aarch64/pgdg-redhat-repo-latest.noarch.rpm \
    --nogpgcheck || true
  dnf install -y pg_cron_15 --nogpgcheck
}
echo "pg_cron installed"

# ── postgresql.conf ────────────────────────────────────────────────────────────
PG_CONF="/var/lib/pgsql/15/data/postgresql.conf"

cat >> "$PG_CONF" <<EOF

# Packiot staging overrides
shared_preload_libraries = 'timescaledb,pg_cron'
cron.database_name = '${db_name}'
timescaledb.telemetry_level = off

listen_addresses = '*'
max_connections = 100
shared_buffers = 512MB
work_mem = 16MB
maintenance_work_mem = 128MB
effective_cache_size = 1536MB

log_timezone = 'UTC'
timezone = 'UTC'
EOF

# ── pg_hba.conf ────────────────────────────────────────────────────────────────
# Allow md5 auth from the full VPC CIDR.
# Only the App EC2 SG can actually reach port 5432 (enforced by the SG rule).
cat > /var/lib/pgsql/15/data/pg_hba.conf <<EOF
local   all   all                  trust
host    all   all   127.0.0.1/32   md5
host    all   all   ${vpc_cidr}    md5
EOF

# ── Start PostgreSQL ───────────────────────────────────────────────────────────
systemctl enable postgresql-15
systemctl start postgresql-15
echo "PostgreSQL started"

# ── Fetch DB password from Secrets Manager ────────────────────────────────────
# The DB IAM role has GetSecretValue scoped to packiot/staging/db*.
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id packiot/staging/db \
  --region ${aws_region} \
  --query SecretString \
  --output text)

DB_PASS=$(echo "$DB_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# ── Create DB user + database ─────────────────────────────────────────────────
sudo -u postgres psql <<SQL
ALTER USER ${db_user} WITH PASSWORD '$DB_PASS';
CREATE DATABASE ${db_name} OWNER ${db_user};
\c ${db_name}
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_cron;
GRANT USAGE ON SCHEMA cron TO ${db_user};
SQL
echo "Database '${db_name}' created with TimescaleDB + pg_cron"

# ── SSM Agent (pre-installed on AL2023, ensure it's running) ──────────────────
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

echo "=== DB init complete $(date -u) ==="
