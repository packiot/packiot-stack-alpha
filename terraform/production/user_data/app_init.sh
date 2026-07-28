#!/bin/bash
# Production App EC2 bootstrap — installs Docker, Nginx, Certbot, GitHub Actions runner.
# Runs once on first boot via EC2 user data. Logs to /var/log/packiot-app-init.log.
#
# Production variant of the staging app_init.sh. Differences from staging:
#   - Secrets under packiot/production/* (not packiot/staging/*)
#   - No nodered-auth secret fetch (no Node-RED in compose.production.yml)
#   - DB connection: app services reach the DB via the `pgbouncer` compose
#     service (POSTGRES_HOST=pgbouncer); pgbouncer's UPSTREAM is the dedicated
#     r7g DB EC2 at its private IP (POSTGRES_HOST_UPSTREAM=${db_private_ip}).
#     DDL/migration/authentik/adminer connect to that IP directly (pooling
#     breaks advisory locks + prepared statements). The packiot/production/db
#     secret stores creds only — URL is constructed here.
#   - GitHub branch: production (not staging)
#   - Submodule list: edge-api + operator only (no edge-node-red — runs
#     per-factory, not in cloud stack)
#   - Compose file: compose.production.yml (not compose.staging.yml)
#   - Runner labels: self-hosted,production,linux,arm64
#   - No RabbitMQ client-user setup (production doesn't expose AMQP to
#     factories per security_groups.tf)
set -euo pipefail
exec > >(tee /var/log/packiot-app-init.log | logger -t packiot-app-init) 2>&1

# Cloud-init doesn't set HOME; git and ssh need it.
export HOME=/root
export PATH="/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/bin:$PATH"

echo "=== Packiot Production App init starting $(date -u) ==="
AWS_REGION="${aws_region}"
PRODUCTION_DOMAIN="${production_domain}"
GITHUB_REPO="${github_repo}"
STATE_BUCKET="${state_bucket}"

# ── SSM agent — NOT pre-installed on AL2023 arm64; install it first ──────────
dnf install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start  amazon-ssm-agent

# ── System ────────────────────────────────────────────────────────────────────
# AL2023 ships with curl-minimal which conflicts with curl; --allowerasing lets dnf replace it.
dnf update -y --allowerasing
dnf install -y git curl unzip jq python3-pip --allowerasing

# ── Swap ──────────────────────────────────────────────────────────────────────
# Same rationale as staging: t4g.medium has 3.7 GiB RAM. Multi-stage Docker
# builds (Go workers especially) can OOM-kill the actions-runner without
# headroom. 4 GiB swap absorbs the spike.
# Idempotent: skip if /swapfile exists; ensure /etc/fstab entry persists.
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
fi
swapon /swapfile 2>/dev/null || true
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo "Swap: $(free -h | awk '/Swap:/ {print $2}') configured"

# ── Docker + Docker Compose ───────────────────────────────────────────────────
dnf install -y docker
systemctl enable docker
systemctl start docker

# Docker Compose v2 (plugin, not standalone binary)
DOCKER_COMPOSE_VERSION="2.27.0"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/download/v$${DOCKER_COMPOSE_VERSION}/docker-compose-linux-aarch64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version
echo "Docker + Compose installed"

# ── Fetch production secrets ──────────────────────────────────────────────────
get_secret() {
  aws secretsmanager get-secret-value \
    --secret-id "$1" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text
}

DB_SECRET=$(get_secret "packiot/production/db")
APP_SECRET=$(get_secret "packiot/production/app")
HASURA_SECRET=$(get_secret "packiot/production/hasura")
AUTHENTIK_SECRET=$(get_secret "packiot/production/authentik")

# Production DB secret does NOT carry a `url`/`host` field (per secrets.tf) — we
# construct the URL here. App services connect via the `pgbouncer` compose
# service; pgbouncer's upstream is the dedicated r7g DB EC2 at ${db_private_ip}
# (emitted below as POSTGRES_HOST_UPSTREAM).
DB_USER_FROM_SECRET=$(echo "$DB_SECRET" | jq -r '.user')
DB_NAME_FROM_SECRET=$(echo "$DB_SECRET" | jq -r '.name')
DB_PASS=$(echo "$DB_SECRET"   | jq -r '.password')
HASURA_ADMIN=$(echo "$HASURA_SECRET" | jq -r '.admin_secret')
# Hasura expects JWT secret as JSON: {"type":"HS256","key":"<secret>"}
HASURA_JWT_KEY=$(echo "$HASURA_SECRET" | jq -r '.jwt_secret')
HASURA_JWT_JSON="{\"type\":\"HS256\",\"key\":\"$HASURA_JWT_KEY\"}"
API_KEY=$(echo "$APP_SECRET"   | jq -r '.edge_api_key')
MQ_USER=$(echo "$APP_SECRET"   | jq -r '.rabbitmq_user')
MQ_PASS=$(echo "$APP_SECRET"   | jq -r '.rabbitmq_password')
GRAFANA_PASS=$(echo "$APP_SECRET" | jq -r '.grafana_admin_pass')
AUTHENTIK_DB_PASS=$(echo "$AUTHENTIK_SECRET" | jq -r '.db_password')
AUTHENTIK_SK=$(echo "$AUTHENTIK_SECRET"       | jq -r '.secret_key')
AUTHENTIK_BOOT_PASS=$(echo "$AUTHENTIK_SECRET" | jq -r '.bootstrap_password // ""')
AUTHENTIK_BOOT_TOK=$(echo "$AUTHENTIK_SECRET"  | jq -r '.bootstrap_token // ""')

# DB URL (via pgbouncer): app services connect to the `pgbouncer` compose
# service on :5432; pgbouncer proxies to the r7g upstream. The r7g private IP is
# templated in from terraform (aws_instance.db.private_ip) and exported below as
# POSTGRES_HOST_UPSTREAM — the value pgbouncer + the direct-connect DDL/authentik/
# adminer services read.
POSTGRES_HOST_UPSTREAM="${db_private_ip}"
POSTGRES_URL_VIA_POOL="postgresql://$DB_USER_FROM_SECRET:$DB_PASS@pgbouncer:5432/$DB_NAME_FROM_SECRET"
# DIRECT-to-r7g URL (bypasses pgbouncer) for consumers that use prepared
# statements or advisory locks, which are incompatible with pgbouncer's
# transaction-pooling mode. Hasura in particular fails every BEGIN with
# 42P05 "prepared statement '0' already exists" when routed through pgbouncer.
# This targets the r7g upstream ($${POSTGRES_HOST_UPSTREAM}) DIRECTLY — there is
# NO local `postgres` container in the F3-native prod stack (W1 DB rewire).
POSTGRES_URL_DIRECT="postgresql://$DB_USER_FROM_SECRET:$DB_PASS@$${POSTGRES_HOST_UPSTREAM}:5432/$DB_NAME_FROM_SECRET"

# ── Write .env for Docker Compose ─────────────────────────────────────────────
mkdir -p /opt/packiot
# Guard: skip .env regeneration if it already exists. Stable secrets across
# re-runs are important for any service that derives state from env (e.g.
# Hasura JWT key, Authentik secret_key).
#
# ⚠ DB-TIER REWIRE (W1) OPERATIONAL NOTE: this guard means a box booted under an
# EARLIER .env (which lacked POSTGRES_HOST_UPSTREAM) will NOT pick up the r7g
# upstream automatically — pgbouncer would still resolve `postgres` (now gone).
# To cut a running box over to the r7g, on the box do ONE of:
#   • rm /opt/packiot/.env && re-run this init (regenerates with the upstream), OR
#   • targeted append/sed:
#       echo "POSTGRES_HOST_UPSTREAM=<r7g-private-ip>" >> /opt/packiot/.env
# then: cd /opt/packiot/stack && docker compose -f compose.production.yml up -d --wait
# Verify: docker compose exec pgbouncer pg_isready -h <r7g-private-ip> -p 5432
if [ -f /opt/packiot/.env ]; then
  echo ".env already exists — skipping generation"
  echo "  NOTE (W1 DB rewire): ensure POSTGRES_HOST_UPSTREAM is present — see comment above."
else
  cat > /opt/packiot/.env <<ENV
# Generated by app_init.sh (production) — do not edit manually.
# Shared by all Docker Compose services via env_file + variable substitution.

# Postgres — DB lives on the dedicated r7g EC2. App services reach it via the
# `pgbouncer` compose service (POSTGRES_HOST=pgbouncer); pgbouncer's upstream and
# the direct-connect DDL/authentik/adminer services use POSTGRES_HOST_UPSTREAM.
POSTGRES_URL=$POSTGRES_URL_VIA_POOL
POSTGRES_HOST=pgbouncer
POSTGRES_HOST_UPSTREAM=$POSTGRES_HOST_UPSTREAM
POSTGRES_PORT=5432
POSTGRES_USER=$DB_USER_FROM_SECRET
POSTGRES_DB=$DB_NAME_FROM_SECRET
POSTGRES_PASSWORD=$DB_PASS

# Hasura — DIRECT to the r7g (POSTGRES_URL_DIRECT), NOT via pgbouncer. Hasura
# uses prepared statements that collide under pgbouncer's transaction-pooling
# mode (error 42P05 "prepared statement '0' already exists" on every BEGIN).
# HASURA_GRAPHQL_PG_CONNECTIONS=5 (compose) caps the pool against the r7g.
HASURA_GRAPHQL_DATABASE_URL=$POSTGRES_URL_DIRECT
HASURA_GRAPHQL_ADMIN_SECRET=$HASURA_ADMIN
HASURA_GRAPHQL_JWT_SECRET=$HASURA_JWT_JSON
HASURA_GRAPHQL_ENABLE_CONSOLE=true
HASURA_GRAPHQL_DEV_MODE=false

# Edge API
EDGE_API_KEY=$API_KEY
EDGE_API_URL=https://api.$PRODUCTION_DOMAIN
# Set after enterprise onboarding via edge-api:
#   ID_ENTERPRISE=<id>
ID_ENTERPRISE=

# RabbitMQ
RABBITMQ_USER=$MQ_USER
RABBITMQ_PASSWORD=$MQ_PASS
RABBITMQ_URL=amqp://$MQ_USER:$MQ_PASS@rabbitmq:5672

# Grafana
GRAFANA_ADMIN_PASSWORD=$GRAFANA_PASS
GF_SERVER_ROOT_URL=https://grafana.$PRODUCTION_DOMAIN

# Compose substitution helpers
PRODUCTION_DOMAIN=$PRODUCTION_DOMAIN

# Authentik SSO
AUTHENTIK_DB_PASSWORD=$AUTHENTIK_DB_PASS
AUTHENTIK_SECRET_KEY=$AUTHENTIK_SK
AUTHENTIK_WEB__WORKERS=1
AUTHENTIK_BOOTSTRAP_EMAIL=admin@packiot.com
AUTHENTIK_BOOTSTRAP_PASSWORD=$AUTHENTIK_BOOT_PASS
AUTHENTIK_BOOTSTRAP_TOKEN=$AUTHENTIK_BOOT_TOK
ENV
fi

# ── GitHub auth ───────────────────────────────────────────────────────────────
# Production uses the github-runner secret for both git clone AND runner
# registration. Staging splits these into two secrets (github-pat +
# github-runner); production consolidates to reduce secret sprawl. Single
# PAT with `repo` scope serves both purposes.
GITHUB_PAT=$(get_secret "packiot/production/github-runner" | jq -r '.pat')

# Rewrite packiot HTTPS URLs to embed the PAT. Longest-prefix matching ensures
# this only applies to packiot org repos, not github.com at large.
#
# IDEMPOTENCY: `git config --global url.X.insteadOf Y` keys on the literal URL
# string X (which includes the PAT). Re-running this script with a different
# PAT — e.g. after rotation — would ADD a second section rather than replace
# the first. Two competing insteadOf rules silently break git auth (older
# stale rule may win). Strip every prior packiot-PAT section before re-adding.
python3 -c "
import re, os, sys
path = '/root/.gitconfig'
if not os.path.exists(path): sys.exit(0)
with open(path) as f: c = f.read()
c = re.sub(r'\[url \"https://x-access-token:[^\"]+@github\.com/packiot/\"\][^\[]*', '', c)
with open(path, 'w') as f: f.write(c)
"
git config --global url."https://x-access-token:$${GITHUB_PAT}@github.com/packiot/".insteadOf "https://github.com/packiot/"

echo "GitHub auth configured"

# ── Clone / update repo ───────────────────────────────────────────────────────
# Branch: production (not staging). Submodules: edge-api + operator only.
# edge-node-red is per-factory, not in cloud production stack.
cd /opt/packiot
if [ -d "stack/.git" ]; then
  cd stack
  git fetch origin
  git checkout production
  git pull origin production
  # --force ensures git retries clones for submodules whose checkout dir
  # exists but is empty/stale (left over from a previous auth failure) — a
  # failed first clone otherwise leaves empty placeholder dirs that block retry.
  git submodule update --init --force -- edge-api operator \
    || echo "WARNING: submodule update failed — continuing with existing state"
  cd /opt/packiot
else
  git clone --branch production "https://x-access-token:$${GITHUB_PAT}@github.com/$${GITHUB_REPO}.git" stack
  cd stack
  git submodule update --init -- edge-api operator
  cd /opt/packiot
fi

# Symlink .env into the repo so Docker Compose auto-loads it for variable substitution.
ln -sf /opt/packiot/.env /opt/packiot/stack/.env

# ── Nginx + Certbot ───────────────────────────────────────────────────────────
# nginx_setup.sh is the canonical script — also safe to run standalone for repairs.
aws s3 cp "s3://$STATE_BUCKET/scripts/production/nginx_setup.sh" /tmp/nginx_setup.sh \
  --region "$AWS_REGION"
bash /tmp/nginx_setup.sh

# ── GitHub Actions self-hosted runner ─────────────────────────────────────────
# The runner registers against the repo and listens for workflow jobs tagged
# with runs-on: [self-hosted, production, linux, arm64].
# Registration token is short-lived; it's fetched from Secrets Manager and
# used once. Subsequent runner auth uses ~/.config/actions-runner/.credentials.

RUNNER_VERSION="2.334.0"
RUNNER_ARCH="arm64"

# libicu is required by the .NET Core runtime embedded in the runner
dnf install -y libicu

mkdir -p /opt/actions-runner
cd /opt/actions-runner

curl -sLO "https://github.com/actions/runner/releases/download/v$${RUNNER_VERSION}/actions-runner-linux-$${RUNNER_ARCH}-$${RUNNER_VERSION}.tar.gz"
tar xzf "actions-runner-linux-$${RUNNER_ARCH}-$${RUNNER_VERSION}.tar.gz"
rm "actions-runner-linux-$${RUNNER_ARCH}-$${RUNNER_VERSION}.tar.gz"

# Create a helper script for (re-)registering the runner.
# Run this manually after populating the github-runner secret in Secrets Manager.
cat > /opt/packiot/register-runner.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id packiot/production/github-runner \
  --region "${aws_region}" \
  --query SecretString \
  --output text)
PAT=$(echo  "$SECRET" | jq -r '.pat')
REPO=$(echo "$SECRET" | jq -r '.repo')

# Exchange long-lived PAT for a short-lived (1h) registration token via GitHub API
REG_TOKEN=$(curl -sf -X POST \
  -H "Authorization: token $PAT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/actions/runners/registration-token" \
  | jq -r '.token')

cd /opt/actions-runner

# Idempotent: stop and uninstall existing service before re-registering
if [ -f /opt/actions-runner/.service ]; then
  ./svc.sh stop    || true
  ./svc.sh uninstall || true
fi

# RUNNER_ALLOW_RUNASROOT=1: bootstrap runs as root; runner allows this for production
RUNNER_ALLOW_RUNASROOT=1 ./config.sh \
  --url "https://github.com/$REPO" \
  --token "$REG_TOKEN" \
  --name "production-$(hostname)" \
  --labels "self-hosted,production,linux,arm64" \
  --unattended \
  --replace

./svc.sh install root
./svc.sh start
echo "Runner registered and running"
SCRIPT
chmod +x /opt/packiot/register-runner.sh

echo "Runner binaries ready. Run: sudo /opt/packiot/register-runner.sh"
echo "  (after populating packiot/production/github-runner in Secrets Manager)"

# ── SSM Agent ─────────────────────────────────────────────────────────────────
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# ── Serial Console rescue: set root password from Secrets Manager ─────────────
# Same rationale as staging — see staging's app_init.sh comment block.
# Account-level requirement: aws ec2 enable-serial-console-access --region us-east-1
# (already enabled for staging; same setting applies account-wide).
#
# Idempotent: chpasswd overwrites any existing password. Skipped (with log)
# if the rescue secret isn't populated yet.
if aws secretsmanager describe-secret \
    --secret-id packiot/production/ec2-rescue \
    --region "$AWS_REGION" > /dev/null 2>&1; then
  RESCUE_SECRET=$(get_secret "packiot/production/ec2-rescue")
  RESCUE_ROOT_PASS=$(echo "$RESCUE_SECRET" | jq -r '.root_password')
  if [ -n "$RESCUE_ROOT_PASS" ] && [ "$RESCUE_ROOT_PASS" != "null" ]; then
    echo "root:$RESCUE_ROOT_PASS" | chpasswd
    echo "Root password set from packiot/production/ec2-rescue for Serial Console access"
  else
    echo "SKIP: packiot/production/ec2-rescue.root_password is empty"
  fi
else
  echo "SKIP: packiot/production/ec2-rescue not in Secrets Manager — Serial Console rescue unavailable"
fi

# ── Weekly docker-prune systemd timer ─────────────────────────────────────────
# Same rationale as staging: bounds /var/lib/docker growth so deploy iterations
# don't fill the disk. Same CRITICAL FLAG: --volumes=false. Authentik users,
# Grafana dashboards, RabbitMQ queues, local postgres data all live in named
# volumes that must NOT be pruned.

cat > /etc/systemd/system/docker-prune.service <<'UNIT'
[Unit]
Description=Prune docker images, build cache, stopped containers (KEEP volumes)
Documentation=https://docs.docker.com/engine/reference/commandline/system_prune/
Wants=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker system prune -af --volumes=false
TimeoutStartSec=600
UNIT

cat > /etc/systemd/system/docker-prune.timer <<'UNIT'
[Unit]
Description=Weekly docker-prune to bound /var/lib/docker growth

[Timer]
# Monday 04:17 UTC — one day after staging's Sunday timer so AWS Backup's
# concurrency limits aren't a contention point during the daily 04:00 UTC
# snapshot window.
OnCalendar=Mon *-*-* 04:17:00
Persistent=true
RandomizedDelaySec=300
Unit=docker-prune.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now docker-prune.timer
echo "docker-prune.timer enabled"

# ── Start Docker Compose stack ────────────────────────────────────────────────
cd /opt/packiot/stack
docker compose -f compose.production.yml up -d --build
echo "Docker Compose stack started"
echo "NOTE: set ID_ENTERPRISE in /opt/packiot/.env after enterprise onboarding, then:"
echo "      docker compose -f compose.production.yml restart oeecloud-worker"

# NOTE: Staging's RabbitMQ client-user setup is DELIBERATELY ABSENT here.
# Production doesn't expose AMQP to external factory edges from this stack
# (no port 5671 ingress in security_groups.tf). If/when production becomes
# the broker for factory edges, port the setup block from staging's
# app_init.sh and add the matching security group rule.

echo "=== Production App init complete $(date -u) ==="
