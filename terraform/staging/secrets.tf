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
