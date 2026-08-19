#!/bin/bash
# App EC2 bootstrap — installs Docker, Nginx, Certbot, GitHub Actions runner.
# Runs once on first boot via EC2 user data. Logs to /var/log/packiot-app-init.log.
set -euo pipefail
exec > >(tee /var/log/packiot-app-init.log | logger -t packiot-app-init) 2>&1

# Cloud-init doesn't set HOME; git and ssh need it.
export HOME=/root
export PATH="/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/bin:$PATH"

echo "=== Packiot App init starting $(date -u) ==="
AWS_REGION="${aws_region}"
STAGING_DOMAIN="${staging_domain}"
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

# ── Go toolchain (self-hosted runner: generate-client-bundle.yml) ─────────────
# The bundle workflow builds cmd/onboard-gen with `go build` and assumes go is on
# PATH on the runner (alongside openssl/aws). Install the pinned toolchain to
# /usr/local + symlink into /usr/local/bin (on the runner service's PATH). Idempotent.
GO_VERSION=1.25.0
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION} "; then
  curl -sSfL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz"
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  rm -f /tmp/go.tgz
fi

# ── Swap ──────────────────────────────────────────────────────────────────────
# Instance has 3.7 GiB RAM. Multi-stage Docker builds (especially Go's parallel
# compiler when building oeecloud-worker) can OOM-kill the actions-runner
# without headroom — happened on 2026-06-22 deploy 27984146678: 18-min Go
# build then runner shutdown signal. 4 GiB swap absorbs the spike.
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

# ── Fetch all staging secrets ─────────────────────────────────────────────────
get_secret() {
  aws secretsmanager get-secret-value \
    --secret-id "$1" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text
}

DB_SECRET=$(get_secret "packiot/staging/db")
APP_SECRET=$(get_secret "packiot/staging/app")
HASURA_SECRET=$(get_secret "packiot/staging/hasura")
NR_AUTH=$(get_secret "packiot/staging/nodered-auth")

DB_URL=$(echo "$DB_SECRET"     | jq -r '.url')
DB_PASS=$(echo "$DB_SECRET"    | jq -r '.password')
HASURA_ADMIN=$(echo "$HASURA_SECRET" | jq -r '.admin_secret')
# Hasura expects JWT secret as JSON: {"type":"HS256","key":"<secret>"}
HASURA_JWT_KEY=$(echo "$HASURA_SECRET" | jq -r '.jwt_secret')
HASURA_JWT_JSON="{\"type\":\"HS256\",\"key\":\"$HASURA_JWT_KEY\"}"
API_KEY=$(echo "$APP_SECRET"   | jq -r '.edge_api_key')
MQ_USER=$(echo "$APP_SECRET"   | jq -r '.rabbitmq_user')
MQ_PASS=$(echo "$APP_SECRET"   | jq -r '.rabbitmq_password')
GRAFANA_PASS=$(echo "$APP_SECRET" | jq -r '.grafana_admin_pass')
# CS-Admin edge-bundle dispatch token (ADR-0045 P5) — the edge-api
# POST /api/edge-bundle/generate endpoint fires generate-client-bundle.yml.
GITHUB_DISPATCH_TOKEN=$(echo "$APP_SECRET" | jq -r '.github_dispatch_token // ""')
# Onboard-generate API key (ADR-0045 §generate) — bearer that edge-api uses to
# call the edge-transformer onboard server (:9105). Durable so a fresh instance
# does not lose it (it was hand-added to .env once; codified 2026-08-05).
ONBOARD_API_KEY=$(echo "$APP_SECRET" | jq -r '.onboard_api_key // ""')
# Operator enterprise api_key (ADR-0018 wave 4) — nginx injects this on the
# operator SPA's proxied /api/* writes; edge-api authenticates it as the client
# enterprise's enterprises.api_key. The staging operator SPA is single-tenant
# CPACK (enterprise 3), so this MUST be CPACK's key — an earlier live .env
# wrongly carried Incoplast's (enterprise 4) key, 502'ing operator writes.
# Sourced from the packiot/staging/app secret (key `operator_edge_api_key`,
# value = CPACK's fe1681ba-… enterprises.api_key) so a full re-init re-creates
# it in .env instead of the operator hand-appending it (drops on rebuild).
# NOTE: keeping the literal secret OUT of git — populate the secret out-of-band
# (see ADR-0020 / production-recut-runbook). Empty default keeps the box booting
# if the secret key is absent; operator writes stay 401 until it is populated.
OPERATOR_EDGE_API_KEY=$(echo "$APP_SECRET" | jq -r '.operator_edge_api_key // ""')
NR_USER=$(echo "$NR_AUTH" | jq -r '.username')
NR_PASS=$(echo "$NR_AUTH" | jq -r '.password')
# oauth2-proxy (Cognito) secrets — Authentik retired (ADR-0034 §C). Sourced from
# the packiot/staging/app secret (keys populated out-of-band). client_id + issuer
# + redirect/cookie domains are non-secret and stay in the compose service block;
# only these two are secrets.
OAUTH2_CLIENT_SECRET=$(echo "$APP_SECRET" | jq -r '.oauth2_proxy_client_secret // ""')
OAUTH2_COOKIE_SECRET=$(echo "$APP_SECRET" | jq -r '.oauth2_proxy_cookie_secret // ""')

# Superset W2 (embedded self-service BI) secrets — durable so a fresh instance
# re-materializes them into .env (they were provisioned into packiot/staging/app
# on 2026-08-09). All default to "" so the block is harmless until the `superset`
# compose profile is enabled (COMPOSE_PROFILES). The Cognito/dashboard values are
# NOT generatable secrets — they are filled at their go-live step (see
# docs/superset-golive-runbook.md): SUPERSET_COGNITO_* come from registering the
# OIDC app client; SUPERSET_OEE_DASHBOARD_UUID from enabling embed on the curated
# dashboard.
SUPERSET_SECRET_KEY=$(echo "$APP_SECRET" | jq -r '.superset_secret_key // ""')
SUPERSET_GUEST_TOKEN_JWT_SECRET=$(echo "$APP_SECRET" | jq -r '.superset_guest_token_jwt_secret // ""')
SUPERSET_DB_PASSWORD=$(echo "$APP_SECRET" | jq -r '.superset_db_password // ""')
SUPERSET_DB_RO_PASSWORD=$(echo "$APP_SECRET" | jq -r '.superset_db_ro_password // ""')
SUPERSET_GUESTTOKEN_ADMIN_USER=$(echo "$APP_SECRET" | jq -r '.superset_guesttoken_admin_user // ""')
SUPERSET_GUESTTOKEN_ADMIN_PASSWORD=$(echo "$APP_SECRET" | jq -r '.superset_guesttoken_admin_password // ""')
SUPERSET_COGNITO_ISSUER=$(echo "$APP_SECRET" | jq -r '.superset_cognito_issuer // ""')
SUPERSET_COGNITO_CLIENT_ID=$(echo "$APP_SECRET" | jq -r '.superset_cognito_client_id // ""')
SUPERSET_COGNITO_CLIENT_SECRET=$(echo "$APP_SECRET" | jq -r '.superset_cognito_client_secret // ""')
SUPERSET_OEE_DASHBOARD_UUID=$(echo "$APP_SECRET" | jq -r '.superset_oee_dashboard_uuid // ""')

# CPACK sparkplug-agent ingest key (ADR-0042 P1) — OPTIONAL / populate-manually.
# Absent until the CPACK tee is provisioned (secret packiot/staging/agent-ingest),
# so this is a guarded fetch defaulting to empty rather than a required get_secret.
# Materializing it here means a full re-init re-creates AGENT_INGEST_API_KEY in
# .env, instead of the operator having to hand-append it (drops on rebuild).
AGENT_INGEST_API_KEY=""
if aws secretsmanager describe-secret \
    --secret-id packiot/staging/agent-ingest \
    --region "$AWS_REGION" > /dev/null 2>&1; then
  AGENT_INGEST_API_KEY=$(get_secret "packiot/staging/agent-ingest" | jq -r '.api_key // ""')
fi


# ── Write .env for Docker Compose ─────────────────────────────────────────────
mkdir -p /opt/packiot
# Guard: skip .env regeneration if it already exists.
# NODE_RED_CREDENTIAL_SECRET must stay stable — Node-RED uses it to decrypt
# flows_cred.json; regenerating it on a re-run makes credentials unreadable.
#
# ⚠ oauth2-proxy (ADR-0034 §C): the guard means a box booted under an EARLIER
# .env (Authentik-era) will NOT gain the OAUTH2_PROXY_*/COGNITO_* keys
# automatically. To patch a RUNNING box without a full re-init, on the box:
#   SEC=$(aws secretsmanager get-secret-value --secret-id packiot/staging/app \
#         --region us-east-1 --query SecretString --output text)
#   {
#     echo "OAUTH2_PROXY_CLIENT_SECRET=$(echo "$SEC" | jq -r '.oauth2_proxy_client_secret')"
#     echo "OAUTH2_PROXY_COOKIE_SECRET=$(echo "$SEC" | jq -r '.oauth2_proxy_cookie_secret')"
#     echo "COGNITO_USER_POOL_ID=us-east-1_0T9t1sTwt"
#     echo "COGNITO_CS_ADMIN_GROUP=cs-admin"
#     echo "EDGE_API_COGNITO_AUTH_ENABLED=true"
#   } >> /opt/packiot/.env
# then: cd /opt/packiot/stack && docker compose -f compose.staging.yml up -d oauth2-proxy edge-api
#
# ⚠ Superset W2 (same guard): a box booted under an earlier .env will NOT gain the
# SUPERSET_*/POSTGRES_HOST_UPSTREAM keys. To patch a RUNNING box (per the go-live
# runbook), append from Secrets Manager without a full re-init:
#   SEC=$(aws secretsmanager get-secret-value --secret-id packiot/staging/app \
#         --region us-east-1 --query SecretString --output text)
#   {
#     echo "POSTGRES_HOST_UPSTREAM=$(grep -E '^POSTGRES_HOST=' /opt/packiot/.env | cut -d= -f2)"
#     for k in superset_secret_key superset_guest_token_jwt_secret superset_db_password \
#              superset_db_ro_password superset_guesttoken_admin_user \
#              superset_guesttoken_admin_password superset_cognito_issuer \
#              superset_cognito_client_id superset_cognito_client_secret \
#              superset_oee_dashboard_uuid; do
#       echo "$(echo "$k" | tr a-z A-Z)=$(echo "$SEC" | jq -r ".$k // \"\"")"
#     done
#     echo "SUPERSET_FRAME_ANCESTOR=https://front.${staging_domain}"
#     echo "SUPERSET_BASE_URL=http://172.18.0.42:8088"
#   } >> /opt/packiot/.env
# then set COMPOSE_PROFILES=superset and bring up the profile — see the runbook.
if [ -f /opt/packiot/.env ]; then
  echo ".env already exists — skipping generation to preserve NODE_RED_CREDENTIAL_SECRET"
else
  NR_SECRET=$(openssl rand -hex 32)

  cat > /opt/packiot/.env <<ENV
# Generated by app_init.sh — do not edit manually.
# Shared by all Docker Compose services via env_file + variable substitution.

# Postgres (DB EC2, private subnet)
POSTGRES_URL=$DB_URL
POSTGRES_HOST=${db_private_ip}
# DIRECT r7g host (bypasses pgbouncer) for one-shot superuser DDL — Superset's
# metadata role+DB bootstrap (compose.superset.yml superset-db-init) needs a
# direct superuser connection, not the pooler. Same address as POSTGRES_HOST on
# staging; named distinctly so the intent (upstream/direct) is explicit.
POSTGRES_HOST_UPSTREAM=${db_private_ip}
POSTGRES_PORT=5432
POSTGRES_USER=${db_user}
POSTGRES_DB=${db_name}
POSTGRES_PASSWORD=$DB_PASS

# Hasura
HASURA_GRAPHQL_DATABASE_URL=$DB_URL
HASURA_GRAPHQL_ADMIN_SECRET=$HASURA_ADMIN
HASURA_GRAPHQL_JWT_SECRET=$HASURA_JWT_JSON
HASURA_GRAPHQL_ENABLE_CONSOLE=true
HASURA_GRAPHQL_DEV_MODE=false

# Edge API / Node-RED
EDGE_API_KEY=$API_KEY
# CS-Admin edge-bundle dispatch (ADR-0045 P5)
GITHUB_DISPATCH_TOKEN=$GITHUB_DISPATCH_TOKEN
# Onboard-generate bearer: edge-api → edge-transformer:9105 (ADR-0045 §generate)
ONBOARD_API_KEY=$ONBOARD_API_KEY
# Operator SPA enterprise api_key (CPACK / enterprise 3) — nginx injects it on
# proxied /api/* writes; consumed by the operator + operator-adapter services.
OPERATOR_EDGE_API_KEY=$OPERATOR_EDGE_API_KEY
EDGE_API_URL=https://api.$STAGING_DOMAIN
NODE_RED_CREDENTIAL_SECRET=$NR_SECRET
# NODE_RED_ADMIN_USERNAME intentionally omitted: Authentik (via nginx forward
# auth) handles browser access to the Node-RED editor.  Omitting this env var
# leaves settings.js adminAuth = undefined, making the admin API accessible
# from inside the Docker network without credentials (FlowManager, auto-deploy).
# Set after enterprise onboarding via edge-api:
#   ID_ENTERPRISE=<id>
ID_ENTERPRISE=

# RabbitMQ
RABBITMQ_USER=$MQ_USER
RABBITMQ_PASSWORD=$MQ_PASS
RABBITMQ_URL=amqp://$MQ_USER:$MQ_PASS@rabbitmq:5672

# Grafana
GRAFANA_ADMIN_PASSWORD=$GRAFANA_PASS
GF_SERVER_ROOT_URL=https://grafana.$STAGING_DOMAIN

# CPACK sparkplug-agent ingest (ADR-0042 P1) — empty until the agent-ingest
# secret is populated; the sparkplug-agent-cpack service (profile cpack-tee)
# reads this to auth CPACK's Node-RED tee.
AGENT_INGEST_API_KEY=$AGENT_INGEST_API_KEY

# Compose substitution helpers
STAGING_DOMAIN=$STAGING_DOMAIN

# oauth2-proxy (Cognito OIDC) — replaces Authentik (ADR-0034 §C). The oauth2-proxy
# compose service reads these; nginx auth_request gates admin UIs on the cs-admin
# group. edge-api validates Cognito JWTs when EDGE_API_COGNITO_AUTH_ENABLED=true.
OAUTH2_PROXY_CLIENT_SECRET=$OAUTH2_CLIENT_SECRET
OAUTH2_PROXY_COOKIE_SECRET=$OAUTH2_COOKIE_SECRET
COGNITO_USER_POOL_ID=us-east-1_0T9t1sTwt
COGNITO_CS_ADMIN_GROUP=cs-admin
EDGE_API_COGNITO_AUTH_ENABLED=true

# Superset W2 (embedded self-service BI) — INERT until COMPOSE_PROFILES includes
# `superset`. compose.superset.yml reads these; edge-api's superset-embed slice
# reads SUPERSET_BASE_URL + the guest-token admin creds + the dashboard UUID.
# SECRET_KEY and GUEST_TOKEN_JWT_SECRET MUST stay identical across web/worker/init
# (a mismatch invalidates sessions + in-flight guest tokens). Design:
# docs/plans/w2-embedded-superset.md; go-live: docs/superset-golive-runbook.md.
SUPERSET_SECRET_KEY=$SUPERSET_SECRET_KEY
SUPERSET_GUEST_TOKEN_JWT_SECRET=$SUPERSET_GUEST_TOKEN_JWT_SECRET
SUPERSET_DB_PASSWORD=$SUPERSET_DB_PASSWORD
SUPERSET_DB_RO_PASSWORD=$SUPERSET_DB_RO_PASSWORD
SUPERSET_GUESTTOKEN_ADMIN_USER=$SUPERSET_GUESTTOKEN_ADMIN_USER
SUPERSET_GUESTTOKEN_ADMIN_PASSWORD=$SUPERSET_GUESTTOKEN_ADMIN_PASSWORD
SUPERSET_COGNITO_ISSUER=$SUPERSET_COGNITO_ISSUER
SUPERSET_COGNITO_CLIENT_ID=$SUPERSET_COGNITO_CLIENT_ID
SUPERSET_COGNITO_CLIENT_SECRET=$SUPERSET_COGNITO_CLIENT_SECRET
SUPERSET_FRAME_ANCESTOR=https://front.$STAGING_DOMAIN
# edge-api superset-embed slice: in-network base URL + curated dashboard embed UUID.
SUPERSET_BASE_URL=http://172.18.0.42:8088
SUPERSET_OEE_DASHBOARD_UUID=$SUPERSET_OEE_DASHBOARD_UUID
# Activate the profile by setting COMPOSE_PROFILES=superset (do it deliberately,
# per the runbook — leaving it unset keeps the whole overlay dark).
# COMPOSE_PROFILES=superset
ENV
fi

# ── GitHub auth ───────────────────────────────────────────────────────────────
# PAT covers all four repos (main + submodules) via a single HTTPS URL rewrite.
# Avoids the per-repo deploy key restriction: GitHub deploy keys are scoped to
# one repo each, making multi-repo submodule setups require N separate keys.
GITHUB_PAT=$(get_secret "packiot/staging/github-pat" | jq -r '.token')

# Rewrite packiot HTTPS URLs to embed the PAT.  Longest-prefix matching ensures
# this only applies to packiot org repos, not github.com at large.
git config --global url."https://x-access-token:$${GITHUB_PAT}@github.com/packiot/".insteadOf "https://github.com/packiot/"

echo "GitHub auth configured"

# ── Clone / update repo ───────────────────────────────────────────────────────
cd /opt/packiot
if [ -d "stack/.git" ]; then
  cd stack
  git fetch origin
  git checkout staging
  git pull origin staging
  # Non-fatal: if the submodule pointer references a not-yet-pushed commit,
  # warn and continue with the already-checked-out state rather than aborting.
  # oeecloud-node-red removed 2026-06-24 (decommissioned; replaced by
  # services/oeecloud-worker, which is in-repo not a submodule).
  git submodule update --init -- edge-api edge-node-red operator \
    || echo "WARNING: submodule update failed — continuing with existing state"
  cd /opt/packiot
else
  git clone --branch staging "https://x-access-token:$${GITHUB_PAT}@github.com/$${GITHUB_REPO}.git" stack
  cd stack
  git submodule update --init -- edge-api edge-node-red operator
  cd /opt/packiot
fi

# Symlink .env into the repo so Docker Compose auto-loads it for variable substitution.
ln -sf /opt/packiot/.env /opt/packiot/stack/.env

# ── Nginx + Certbot ───────────────────────────────────────────────────────────
# nginx_setup.sh is the canonical script — also safe to run standalone for repairs.
aws s3 cp "s3://$STATE_BUCKET/scripts/nginx_setup.sh" /tmp/nginx_setup.sh \
  --region "$AWS_REGION"
bash /tmp/nginx_setup.sh

# ── GitHub Actions self-hosted runner ─────────────────────────────────────────
# The runner registers against the repo and listens for workflow jobs tagged
# with runs-on: [self-hosted, staging].
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
  --secret-id packiot/staging/github-runner \
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

# RUNNER_ALLOW_RUNASROOT=1: bootstrap runs as root; runner allows this for staging
RUNNER_ALLOW_RUNASROOT=1 ./config.sh \
  --url "https://github.com/$REPO" \
  --token "$REG_TOKEN" \
  --name "staging-$(hostname)" \
  --labels "self-hosted,staging,linux,arm64" \
  --unattended \
  --replace

./svc.sh install root
./svc.sh start
echo "Runner registered and running"
SCRIPT
chmod +x /opt/packiot/register-runner.sh

echo "Runner binaries ready. Run: sudo /opt/packiot/register-runner.sh"
echo "  (after populating packiot/staging/github-runner in Secrets Manager)"

# ── SSM Agent ─────────────────────────────────────────────────────────────────
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# ── Serial Console rescue: set root password from Secrets Manager ─────────────
# AL2023 ships with no root password set; the Serial Console login prompt
# rejects every attempt. Without this, when an in-band path is dead
# (docker.service failed → SSM agent crashed → sshd unhappy after a
# disk-full incident) there is NO viable rescue except EBS detach-attach.
# Setting a strong password here makes Serial Console a 30-second
# diagnostic option for the same failure mode.
#
# Idempotent: chpasswd overwrites any existing password. Skipped (with a
# log line) if the rescue secret isn't populated yet — happens on the
# very first apply before the secret has propagated through Secrets
# Manager replication.
if aws secretsmanager describe-secret \
    --secret-id packiot/staging/ec2-rescue \
    --region "$AWS_REGION" > /dev/null 2>&1; then
  RESCUE_SECRET=$(get_secret "packiot/staging/ec2-rescue")
  RESCUE_ROOT_PASS=$(echo "$RESCUE_SECRET" | jq -r '.root_password')
  if [ -n "$RESCUE_ROOT_PASS" ] && [ "$RESCUE_ROOT_PASS" != "null" ]; then
    echo "root:$RESCUE_ROOT_PASS" | chpasswd
    echo "Root password set from packiot/staging/ec2-rescue for Serial Console access"
  else
    echo "SKIP: packiot/staging/ec2-rescue.root_password is empty"
  fi
else
  echo "SKIP: packiot/staging/ec2-rescue not in Secrets Manager — Serial Console rescue unavailable"
fi

# ── Weekly docker-prune systemd timer ─────────────────────────────────────────
# Bounds /var/lib/docker growth so the 2026-06-22 disk-full incident doesn't
# repeat. Each deploy iteration writes a few hundred MB of new image layers
# (yarn install + Vite build + nginx layer for the operator alone). Without
# pruning, four deploys in a day used ~3 GB and after ~10 days the disk
# filled (overlay2 → 13 GB → docker.service refused to start → sshd, SSM
# all in-band paths went dark → only EBS-detach-rescue worked).
#
# CRITICAL FLAG: --volumes=false. The named volumes hold Authentik users,
# Grafana dashboards, RabbitMQ queues, Node-RED context. Pruning volumes
# would nuke staging-only state we can't recover from S3 backups (the DB
# backups cover the timescaledb container only).
#
# Idempotent: the unit files are owned by this script; subsequent runs of
# user_data overwrite them and re-enable the timer — same end state.
cat > /etc/systemd/system/docker-prune.service <<'UNIT'
[Unit]
Description=Prune docker images, build cache, stopped containers (KEEP volumes)
Documentation=https://docs.docker.com/engine/reference/commandline/system_prune/
Wants=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker system prune -af --volumes=false
# Hard kill after 10 min — a hung prune shouldn't block the next deploy.
TimeoutStartSec=600
UNIT

cat > /etc/systemd/system/docker-prune.timer <<'UNIT'
[Unit]
Description=Weekly docker-prune to bound /var/lib/docker growth

[Timer]
# Sunday 04:17 UTC — off-hours for both deploys and humans inspecting staging.
OnCalendar=Sun *-*-* 04:17:00
# Persistent + RandomizedDelaySec means the timer still fires if the host
# was down at the scheduled time (caught up on next boot) and avoids
# coordinated startup load if we ever run multiple staging EC2s.
Persistent=true
RandomizedDelaySec=300
Unit=docker-prune.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now docker-prune.timer
echo "docker-prune.timer enabled (next: $(systemctl show docker-prune.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo 'pending'))"

# ── Start Docker Compose stack ────────────────────────────────────────────────
cd /opt/packiot/stack
docker compose -f compose.staging.yml up -d --build
echo "Docker Compose stack started"
echo "NOTE: set ID_ENTERPRISE in /opt/packiot/.env after enterprise onboarding, then:"
echo "      docker compose -f compose.staging.yml restart edge-nodered oeecloud-worker"

# ── RabbitMQ: dedicated client user for external factory edges ────────────────
# Requires the secret packiot/staging/rabbitmq-client-creds to exist:
#   {"username":"edge-client","password":"<strong-password>"}
# If the secret is absent, this block is skipped; run manually later via SSM.
#
# The client user gets write-only access to the default vhost '/':
#   configure="" — cannot create/delete exchanges or queues
#   write=".*"   — can publish to any exchange (what a factory edge needs)
#   read=""      — cannot consume (oeecloud-worker holds the consumer role)
if aws secretsmanager describe-secret \
    --secret-id packiot/staging/rabbitmq-client-creds \
    --region "$AWS_REGION" > /dev/null 2>&1; then

  CLIENT_CREDS=$(get_secret "packiot/staging/rabbitmq-client-creds")
  CLIENT_USER=$(echo "$CLIENT_CREDS" | jq -r '.username')
  CLIENT_PASS=$(echo "$CLIENT_CREDS" | jq -r '.password')

  # Wait for RabbitMQ to accept management API calls (up to 120s)
  echo "Waiting for RabbitMQ management API..."
  for i in $(seq 1 24); do
    if curl -sf "http://127.0.0.1:15672/api/healthchecks/node" \
        -u "$MQ_USER:$MQ_PASS" > /dev/null; then
      echo "RabbitMQ ready"
      break
    fi
    sleep 5
  done

  # Create user (PUT is idempotent — safe to re-run; updates password if changed).
  # Tags: "management" allows the user to call the management HTTP API (including
  # the /api/exchanges/publish endpoint). AMQP permissions below restrict to write-only.
  curl -sf -u "$MQ_USER:$MQ_PASS" -X PUT \
    "http://127.0.0.1:15672/api/users/$CLIENT_USER" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"$CLIENT_PASS\",\"tags\":\"management\"}"

  # Grant write-only permissions on default vhost '/'
  # URL-encode '/' as '%2F' — RabbitMQ management API requires this.
  curl -sf -u "$MQ_USER:$MQ_PASS" -X PUT \
    "http://127.0.0.1:15672/api/permissions/%2F/$CLIENT_USER" \
    -H "Content-Type: application/json" \
    -d '{"configure":"","write":".*","read":""}'

  echo "RabbitMQ client user '$CLIENT_USER' created with write-only access to vhost '/'"
else
  echo "SKIP: packiot/staging/rabbitmq-client-creds not found — create it in Secrets Manager then re-run this block via SSM"
fi

# ── edge-transformer user + Phase 2 topology (ADR-0009) ──────────────────────
# Provisions:
#   1. RMQ user `edge-transformer` with least-priv perms scoped to
#      ^(edge-transformer\..*|outbox\..*|edge\.plc-normalized)$
#   2. Topic exchange `edge.plc-normalized` for normalized PLC payloads
#      from Node-RED publishers (per docs/clients/_normalized-payload-schema.yaml).
#   3. Topic exchange `dlx.edge.plc-normalized` for failed-after-retry messages.
#
# Both exchanges are durable + idempotent (PUT is upsert-shaped in the RMQ
# management API). Declaring them early is harmless — they sit empty until
# Phase 2's Node-RED publisher flow lands.
#
# When the secret is missing, skip cleanly (matches the pattern above). For
# the live secret created 2026-06-30, this block runs end-to-end on next deploy.
if aws secretsmanager describe-secret \
    --secret-id packiot/staging/rabbitmq-edge-transformer-creds \
    --region "$AWS_REGION" > /dev/null 2>&1; then

  ET_CREDS=$(get_secret "packiot/staging/rabbitmq-edge-transformer-creds")
  ET_USER=$(echo "$ET_CREDS" | jq -r '.username')
  ET_PASS=$(echo "$ET_CREDS" | jq -r '.password')

  # Idempotent user create. Tag "management" is needed if the service ever
  # uses the HTTP API (the AMQP consumer pattern doesn't, but it's harmless).
  curl -sf -u "$MQ_USER:$MQ_PASS" -X PUT \
    "http://127.0.0.1:15672/api/users/$ET_USER" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"$ET_PASS\",\"tags\":\"\"}"

  # Least-priv perms — see docs/guides/edge-transformer-phase-2-runbook.md §2.B.
  # The regex restricts edge-transformer to its own queues + the shared
  # publish exchange. Cannot touch other tenants' queues, management API,
  # or other exchanges. Bounded blast radius.
  #
  # Naming convention: hyphen-separated (matches oeecloud-worker's
  # `oeecloud-worker-q-retry-30s` style). The `.` in the regex is a
  # wildcard (any char) — matches `edge-transformer-q`, `edge-transformer-q-retry-30s`, etc.
  curl -sf -u "$MQ_USER:$MQ_PASS" -X PUT \
    "http://127.0.0.1:15672/api/permissions/%2F/$ET_USER" \
    -H "Content-Type: application/json" \
    -d '{"configure":"^(edge-transformer.*|outbox.*)$","write":"^(edge-transformer.*|outbox.*|edge\\.plc-normalized.*|oee)$","read":"^(edge\\.plc-normalized|dlx\\.edge\\.plc-normalized|edge-transformer.*|outbox.*|oee)$"}'

  echo "RabbitMQ user '$ET_USER' created with edge-transformer least-priv perms"

  # Declare the Phase 2 topology — exchange + DLX. Topic-type, durable.
  curl -sf -u "$MQ_USER:$MQ_PASS" -X PUT \
    "http://127.0.0.1:15672/api/exchanges/%2F/edge.plc-normalized" \
    -H "Content-Type: application/json" \
    -d '{"type":"topic","durable":true,"auto_delete":false}'

  curl -sf -u "$MQ_USER:$MQ_PASS" -X PUT \
    "http://127.0.0.1:15672/api/exchanges/%2F/dlx.edge.plc-normalized" \
    -H "Content-Type: application/json" \
    -d '{"type":"topic","durable":true,"auto_delete":false}'

  echo "RabbitMQ topology declared: edge.plc-normalized + dlx.edge.plc-normalized (topic, durable)"
else
  echo "SKIP: packiot/staging/rabbitmq-edge-transformer-creds not found — create it in Secrets Manager then re-run this block via SSM"
fi

echo "=== App init complete $(date -u) ==="
