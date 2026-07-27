# All secrets stored in AWS Secrets Manager under the packiot/staging/ prefix.
# The App and DB EC2 IAM roles have read access scoped to this prefix.
#
# recovery_window_in_days = 0 → immediate deletion on terraform destroy.
# For production, set to 7+ to prevent accidental data loss.

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

# ── DB credentials ────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "db" {
  name                    = "packiot/staging/db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    host     = aws_instance.db.private_ip
    port     = 5432
    name     = var.db_name
    user     = var.db_user
    password = random_password.db.result
    url      = "postgresql://${var.db_user}:${random_password.db.result}@${aws_instance.db.private_ip}:5432/${var.db_name}"
  })

  # Don't overwrite if the secret was manually rotated.
  lifecycle { ignore_changes = [secret_string] }
}

# ── Hasura ────────────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "hasura" {
  name                    = "packiot/staging/hasura"
  recovery_window_in_days = 0
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

resource "aws_secretsmanager_secret" "app" {
  name                    = "packiot/staging/app"
  recovery_window_in_days = 0
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

# ── CPACK agent ingest key (ADR-0042 P1) ──────────────────────────────────────
# The X-Ingest-Key the sparkplug-agent-cpack service authenticates CPACK's
# Node-RED tee against (compose env AGENT_INGEST_API_KEY). NOT a random_password:
# the value must MATCH what CPACK's Node-RED is already configured with, so it is
# chosen out-of-band and populated MANUALLY (same pattern as github-runner). No
# secret_version here on purpose — Terraform must never generate, store, or echo
# this value in state/plan. app_init.sh reads it (guarded) and writes it into
# /opt/packiot/.env, so a full instance re-init re-materializes it instead of the
# operator having to hand-append it (which drops on rebuild).
#
# Populate once (out-of-band value from CPACK ops):
#   aws secretsmanager put-secret-value \
#     --secret-id packiot/staging/agent-ingest \
#     --region us-east-1 \
#     --secret-string '{"api_key":"<AGENT_INGEST_API_KEY>"}'
resource "aws_secretsmanager_secret" "agent_ingest" {
  name                    = "packiot/staging/agent-ingest"
  recovery_window_in_days = 0
  description             = "CPACK sparkplug-agent X-Ingest-Key (ADR-0042 P1) — populate manually, see comment above"
}

# ── Node-RED admin auth ────────────────────────────────────────────────────────
# Both edge-nodered and oeecloud use this single credential pair.
# settings.js reads NODE_RED_ADMIN_USERNAME + NODE_RED_ADMIN_PASSWORD_HASH from env.
# app_init.sh fetches the plaintext password and generates the bcrypt hash at boot.

resource "random_password" "nodered_admin" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "nodered_auth" {
  name                    = "packiot/staging/nodered-auth"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "nodered_auth" {
  secret_id = aws_secretsmanager_secret.nodered_auth.id
  secret_string = jsonencode({
    username = "packiot"
    password = random_password.nodered_admin.result
  })
  lifecycle { ignore_changes = [secret_string] }
}

# ── Nginx basic auth ──────────────────────────────────────────────────────────
# All staging service vhosts require this credential pair.
# nginx_setup.sh fetches this at runtime and writes /etc/nginx/.htpasswd.
# To rotate: update the secret, then re-run nginx_setup.sh on the App EC2.

resource "random_password" "nginx_auth" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "nginx_auth" {
  name                    = "packiot/staging/nginx-auth"
  recovery_window_in_days = 0
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
  name                    = "packiot/staging/authentik"
  recovery_window_in_days = 0
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
# registration token). register-runner.sh exchanges the PAT for a fresh 1-hour
# token via the GitHub API each time it runs, so re-registration is safe.
#
#   1. Create a classic GitHub PAT with 'repo' scope at github.com → Settings →
#      Developer settings → Personal access tokens → Tokens (classic).
#   2. aws secretsmanager put-secret-value \
#        --secret-id packiot/staging/github-runner \
#        --region us-east-1 \
#        --secret-string '{"pat":"ghp_YOURTOKEN","repo":"packiot/packiot-stack-alpha"}'
#   3. SSH/SSM into the App EC2 and run: sudo /opt/packiot/register-runner.sh

resource "aws_secretsmanager_secret" "github_runner" {
  name                    = "packiot/staging/github-runner"
  recovery_window_in_days = 0
  description             = "GitHub Actions runner — PAT + repo (populate manually, see comment above)"
}

# ── EC2 Serial Console rescue password ────────────────────────────────────────
# Set on the root account at app_init.sh time. Used ONLY for EC2 Serial Console
# login when in-band paths (SSM, SSH, EC2 Instance Connect) have died —
# typically because /var/lib/docker filled the root FS and userspace went
# down (2026-06-22 incident shape).
#
# Serial Console expects password auth (not SSH keys). Without this password,
# root has no usable credential on AL2023 (no default password set), so the
# Console login prompt rejects every attempt and an EBS detach-attach-rescue
# is the only path back in. With this password, Serial Console becomes a
# 30-second "tail /var/log/...; df -h; systemctl status docker" recovery
# vs the 25-minute EBS rescue.
#
# Account-level requirement: AWS Serial Console must be enabled for the
# account — `aws ec2 enable-serial-console-access --region us-east-1`.
# That call is idempotent + one-time; not codified in TF because there's
# no first-class resource for the per-account toggle (the GetSerialConsoleAccessStatus
# / EnableSerialConsoleAccess API pair is account-scoped, not resource-scoped).

resource "random_password" "ec2_rescue_root" {
  length  = 32
  special = false # Serial Console QWERTY input — avoid characters that
  # require shift-keys + nation-specific layouts (keyboards in a Serial
  # Console session are sometimes US-only). Length 32 still gives ~190
  # bits of entropy with [A-Za-z0-9], well above the threshold to make
  # online brute-force impractical.
}

resource "aws_secretsmanager_secret" "ec2_rescue" {
  name                    = "packiot/staging/ec2-rescue"
  recovery_window_in_days = 0
  description             = "Root password for EC2 Serial Console rescue access (in-band paths down)"
}

resource "aws_secretsmanager_secret_version" "ec2_rescue" {
  secret_id = aws_secretsmanager_secret.ec2_rescue.id
  secret_string = jsonencode({
    root_password = random_password.ec2_rescue_root.result
    # Operator instructions, embedded in the secret so a panicked engineer
    # gets the playbook in the same response as the password.
    how_to_use = "1) AWS Console → EC2 → packiot-staging-app → Connect → Serial Console. 2) Hit Enter to get login prompt. 3) Login as root with this password. 4) Diagnose: df -h, journalctl -xe, systemctl status docker."
  })
  lifecycle { ignore_changes = [secret_string] }
}
