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

# ⚠ DURABILITY GAP (host is not terraform-managed) — DOCUMENTED, NOT FIXED.
# The first live boot hand-added `host = 10.20.10.89` (the r7g DB EC2's PRIVATE
# IP) to this secret so oeecloud-worker's PG resolver could reach the upstream.
# But `ignore_changes = [secret_string]` above means terraform will NEVER
# reconcile that field, AND the r7g private IP is DYNAMIC — an r7g replacement
# (or stop/start on some instance types) assigns a new private IP, orphaning the
# stale `host` in this secret. oeecloud-worker would then resolve a dead host.
# Proper fix (pick one, out of scope for this PR):
#   (a) terraform manages host — drop `host` from ignore_changes (or split it
#       into a separate un-ignored version field) and template it from
#       aws_instance.db.private_ip, so a replace re-writes the secret; OR
#   (b) oeecloud-worker reads the host from the POSTGRES_HOST_UPSTREAM env var
#       (already templated into .env by app_init.sh from db_private_ip) instead
#       of from this secret — a small Go change that removes the secret's host
#       responsibility entirely. (b) is preferred: single source of truth for
#       the upstream IP, and app_init already owns it.

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
    # ── Operator SPA keys (CPACK PO-control cutover — cpack-po-cutover-runbook.md
    #    B2/B5). The `operator` compose service's nginx injects both server-side;
    #    the browser never holds a key. Both default EMPTY and are HAND-FILLED at
    #    client onboarding (ignore_changes below preserves the hand-set values),
    #    the same out-of-band pattern as the oauth2/superset/onboard keys:
    #      operator_edge_api_key    (B2) = the operator client's enterprises.api_key
    #        (a DB-generated randomUUID from onboarding — NOT terraform-random).
    #        For CPACK this is enterprise 3's api_key.
    #      operator_refdata_api_key (B5) = the opaque refdata read key. MUST match
    #        the token in the refdata_query_keys secret's api_keys map (which maps
    #        it → the client's enterprise id). app_init.sh reads both into .env
    #        (OPERATOR_EDGE_API_KEY / OPERATOR_REFDATA_API_KEY). Populate via a
    #        put-secret-value merge on the box (values never printed).
    operator_edge_api_key    = ""
    operator_refdata_api_key = ""
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

# ── RabbitMQ creds for edge-transformer + ingest-shim ─────────────────────────
# Both edge-transformer and ingest-shim fetch their AMQP creds from a DEDICATED
# secret at startup (RABBITMQ_SECRET_ID in compose.production.yml) rather than
# reading RABBITMQ_USER/RABBITMQ_PASSWORD from .env. Like oeecloud-worker they
# refuse to run if the secret is missing — first fresh boot surfaced the absence
# (had to be hand-created). Same dry-run shortcut: reuse the admin creds from
# `app` (random_password.rabbitmq); phase 2 should split into a least-priv AMQP
# user once real factory traffic flows.
resource "aws_secretsmanager_secret" "rabbitmq_edge_transformer_creds" {
  name                    = "packiot/production/rabbitmq-edge-transformer-creds"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "rabbitmq_edge_transformer_creds" {
  secret_id = aws_secretsmanager_secret.rabbitmq_edge_transformer_creds.id
  secret_string = jsonencode({
    username = "packiot"
    password = random_password.rabbitmq.result
  })
  lifecycle { ignore_changes = [secret_string] }
}

# ── refdata-api per-tenant query keys ─────────────────────────────────────────
# refdata-api reads QUERY_API_KEYS from this secret (deploy fills
# REFDATA_QUERY_API_KEYS in .env; compose passes it through as
# ${REFDATA_QUERY_API_KEYS:-}). The value is a "key:customer_id,key2:cid2" map
# resolved SERVER-SIDE for tenant reads. It is NON-BLOCKING — refdata boots and
# stays healthy with no keys (an empty/malformed map simply denies all X-Api-Key
# reads). Declared here (was referenced but absent → hand-created on first boot)
# with a minimal empty shape; CS fills real keys per client at onboarding.
resource "aws_secretsmanager_secret" "refdata_query_keys" {
  name                    = "packiot/production/refdata-query-keys"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "refdata_query_keys" {
  secret_id = aws_secretsmanager_secret.refdata_query_keys.id
  # Empty default — the per-tenant map is hand-filled at client onboarding via
  # `aws secretsmanager put-secret-value` (a fresh env can't know a client's read
  # key until the client exists). ignore_changes preserves the hand-set map.
  # Format: "key:enterprise_id,key2:cid2". For the CPACK PO-control cutover
  # (docs/clients/cpack-po-cutover-runbook.md B5) this holds the operator read key
  # mapped to enterprise 3 — the SAME token stored as app.operator_refdata_api_key
  # (the two MUST agree; refdata resolves customer_id from the key server-side).
  # app_init.sh reads .api_keys → .env REFDATA_QUERY_API_KEYS.
  secret_string = jsonencode({
    api_keys = ""
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
