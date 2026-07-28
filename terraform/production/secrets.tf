# All secrets stored in AWS Secrets Manager under the packiot/production/ prefix.
# The App EC2 IAM role has read access scoped to this prefix only (see ec2.tf).
#
# recovery_window_in_days = 7 → 7-day grace period on terraform destroy.
# Stronger than staging's 0 because production deletion shouldn't be instant
# (mistakes happen; a week to recover is cheap insurance).

# ── Random password generators ────────────────────────────────────────────────

resource "random_password" "db" {
  length  = 32
  special = false # avoids shell quoting issues in psql connection strings
}

resource "random_password" "hasura_admin" {
  length  = 32
  special = false
}

resource "random_password" "hasura_jwt" {
  length  = 64
  special = false
}

resource "random_password" "edge_api_key" {
  length  = 32
  special = false
}

resource "random_password" "rabbitmq" {
  length  = 24
  special = false
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

# ── DB credentials (LOCAL prod-dryrun postgres) ───────────────────────────────
# These creds authenticate against the LOCAL TimescaleDB container that runs
# on the same EC2. Services in compose.production.yml connect via compose
# network hostname `pgbouncer` (not stored in the secret since it's a
# compose-internal detail).
#
# When phase 2 lands (real prod DB connection to tsp12), this secret's
# host/port fields will be updated to point at tsp12's endpoint and the
# compose env will switch DATABASE_URL accordingly. The cutover is a single
# `aws secretsmanager update-secret` + `docker compose restart`.

resource "aws_secretsmanager_secret" "db" {
  name                    = "packiot/production/db"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    port     = 5432
    name     = var.db_name
    user     = var.db_user
    password = random_password.db.result
    # NOTE: deliberately NO `host` or `url` field today — the local prod-dryrun
    # postgres lives in compose and is reachable by service name (`pgbouncer`).
    # When phase 2 swaps in the tsp12 connection, host + url will be added
    # and the production stack will be reconfigured via env to use them.
  })

  # Don't overwrite if the secret was manually rotated.
  lifecycle { ignore_changes = [secret_string] }
}

# ── Hasura ────────────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "hasura" {
  name                    = "packiot/production/hasura"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "hasura" {
  secret_id = aws_secretsmanager_secret.hasura.id
  secret_string = jsonencode({
    admin_secret = random_password.hasura_admin.result
    jwt_secret   = random_password.hasura_jwt.result
  })
  lifecycle { ignore_changes = [secret_string] }
}

# ── Application secrets ───────────────────────────────────────────────────────
# edge-api auth key + RabbitMQ creds + Grafana admin password.

resource "aws_secretsmanager_secret" "app" {
  name                    = "packiot/production/app"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    edge_api_key       = random_password.edge_api_key.result
    rabbitmq_user      = "packiot"
    rabbitmq_password  = random_password.rabbitmq.result
    grafana_admin_pass = random_password.grafana_admin.result
  })
  lifecycle { ignore_changes = [secret_string] }
}

# NOTE: staging's `packiot/staging/nodered-auth` secret is deliberately ABSENT
# from production. No Node-RED runs in compose.production.yml (per ADR-0003
# scope — edge-nodered is per-factory, not in the cloud stack).

# ── RabbitMQ creds for oeecloud-worker ────────────────────────────────────────
# oeecloud-worker fetches its own AMQP creds from a DEDICATED secret at startup
# rather than reading RABBITMQ_USER/RABBITMQ_PASSWORD from .env (the worker does
# NOT fall back to env — it refuses to run if this secret is missing). First
# dry-run boot surfaced the missing declaration. In dry-run we reuse the admin
# creds from `app` (random_password.rabbitmq); phase 2 should split these into a
# least-priv AMQP user once real factory traffic flows.
resource "aws_secretsmanager_secret" "rabbitmq_oeecloud_creds" {
  name                    = "packiot/production/rabbitmq-oeecloud-creds"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "rabbitmq_oeecloud_creds" {
  secret_id = aws_secretsmanager_secret.rabbitmq_oeecloud_creds.id
  secret_string = jsonencode({
    username = "packiot"
    password = random_password.rabbitmq.result
  })
  lifecycle { ignore_changes = [secret_string] }
}

# ── Nginx basic auth ──────────────────────────────────────────────────────────
# All production service vhosts behind Nginx require this credential pair.
# nginx_setup.sh fetches at runtime and writes /etc/nginx/.htpasswd.
# To rotate: update the secret, then re-run nginx_setup.sh on the App EC2.

resource "random_password" "nginx_auth" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "nginx_auth" {
  name                    = "packiot/production/nginx-auth"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "nginx_auth" {
  secret_id = aws_secretsmanager_secret.nginx_auth.id
  secret_string = jsonencode({
    username = "packiot"
    password = random_password.nginx_auth.result
  })
  lifecycle { ignore_changes = [secret_string] }
}

# ── Authentik SSO ────────────────────────────────────────────────────────────
# Outer-gate SSO for the production service vhosts. Production gets its own
# Authentik install — independent identity provider from staging's.

resource "random_password" "authentik_db" {
  length  = 32
  special = false
}

resource "random_password" "authentik_secret_key" {
  length  = 64
  special = false
}

resource "random_password" "authentik_bootstrap_password" {
  length  = 32
  special = false
}

resource "random_password" "authentik_bootstrap_token" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "authentik" {
  name                    = "packiot/production/authentik"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "authentik" {
  secret_id = aws_secretsmanager_secret.authentik.id
  secret_string = jsonencode({
    db_password        = random_password.authentik_db.result
    secret_key         = random_password.authentik_secret_key.result
    bootstrap_password = random_password.authentik_bootstrap_password.result
    bootstrap_token    = random_password.authentik_bootstrap_token.result
  })
  lifecycle { ignore_changes = [secret_string] }
}

# ── GitHub Actions runner ─────────────────────────────────────────────────────
# Populate manually after apply — store a long-lived PAT (not a short-lived
# registration token). register-runner.sh exchanges the PAT for a fresh
# 1-hour token via the GitHub API each time it runs, so re-registration is safe.
#
# When ADR-0006 phase 1 lands (OIDC for AWS auth), the runner will use OIDC
# at job time instead of a long-lived PAT. Until then, the PAT pattern below
# matches staging's onboarding flow.
#
#   1. Create a classic GitHub PAT with 'repo' scope at github.com → Settings →
#      Developer settings → Personal access tokens → Tokens (classic).
#   2. aws secretsmanager put-secret-value \
#        --secret-id packiot/production/github-runner \
#        --region us-east-1 \
#        --secret-string '{"pat":"ghp_YOURTOKEN","repo":"packiot/packiot-stack-alpha"}'
#   3. SSH/SSM into the App EC2 and run: sudo /opt/packiot/register-runner.sh

resource "aws_secretsmanager_secret" "github_runner" {
  name                    = "packiot/production/github-runner"
  recovery_window_in_days = 7
  description             = "GitHub Actions runner — PAT + repo (populate manually, see comment above)"
}

# ── EC2 Serial Console rescue password ────────────────────────────────────────
# Set on the root account at app_init.sh time. Used ONLY for Serial Console
# login when in-band paths (SSM, SSH, EC2 Instance Connect) have died. Same
# rationale as staging's `packiot/staging/ec2-rescue` — see the staging
# secrets.tf comment block for the full justification + operator playbook.
#
# Account-level requirement: AWS Serial Console must be enabled for the
# account — `aws ec2 enable-serial-console-access --region us-east-1`.
# Already enabled for staging; same setting applies to production (it's
# account-scoped, not per-instance).

resource "random_password" "ec2_rescue_root" {
  length  = 32
  special = false # Serial Console keyboards are sometimes US-only QWERTY;
  # alphanumeric-only avoids shift+special character pain. Length 32 with
  # [A-Za-z0-9] still gives ~190 bits of entropy.
}

resource "aws_secretsmanager_secret" "ec2_rescue" {
  name                    = "packiot/production/ec2-rescue"
  recovery_window_in_days = 7
  description             = "Root password for EC2 Serial Console rescue access (in-band paths down)"
}

resource "aws_secretsmanager_secret_version" "ec2_rescue" {
  secret_id = aws_secretsmanager_secret.ec2_rescue.id
  secret_string = jsonencode({
    root_password = random_password.ec2_rescue_root.result
    # Operator instructions, embedded in the secret so a panicked engineer
    # gets the playbook in the same response as the password.
    how_to_use = "1) AWS Console → EC2 → packiot-production-app → Connect → Serial Console. 2) Hit Enter to get login prompt. 3) Login as root with this password. 4) Diagnose: df -h, journalctl -xe, systemctl status docker."
  })
  lifecycle { ignore_changes = [secret_string] }
}
