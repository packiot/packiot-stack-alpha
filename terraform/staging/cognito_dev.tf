# ── Dev Cognito user pool (ADR-0060 D3, P2) ───────────────────────────────────
#
# The local dev environment (dev/, ADR-0060) needs real Cognito tokens: front4/csadmin/operator
# use Amplify with only a pool id + client id (no endpoint override), so a local mock issuer
# would need code changes in 4 SPAs (docs/dev/contracts.md F6). A dedicated DEV pool needs none:
# read-api takes its issuer from env (COGNITO_ISSUER / COGNITO_JWKS_URL).
#
# Isolation: a separate pool = a separate issuer. Staging/prod APIs only trust their own pool, so a
# dev token is useless outside a dev stack; dev users exist only here.
#
# Users: the three synthetic users the dev seed generates (dev/seed/generators/identity.users.sql),
# tenant 3. read-api links identity.users.id_user_cognito by e-mail on first login. Passwords are
# random, never e-mailed (message_action = SUPPRESS: example.com is a reserved, undeliverable
# domain), and stored in Secrets Manager `packiot/dev/cognito` with the pool/client ids:
#   aws secretsmanager get-secret-value --secret-id packiot/dev/cognito --query SecretString --output text
# They also live in Terraform state (as origin_verify does); the state bucket is encrypted.

locals {
  dev_cognito_users = {
    "dev-admin"    = "dev-admin@example.com"
    "dev-engineer" = "dev-engineer@example.com"
    "dev-viewer"   = "dev-viewer@example.com"
  }
  dev_cognito_tenant = "3" # the dev seed's tenant (dev/seed/manifest.yml)
}

resource "aws_cognito_user_pool" "dev" {
  name = "packiot-dev"

  # Free tier; same as staging. Do NOT change without a cost review.
  user_pool_tier = "LITE"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "INACTIVE" # dev pool: disposable

  password_policy {
    minimum_length                   = 12
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  username_configuration {
    case_sensitive = false
  }

  # Same schema as the staging pool (cognito.tf) so tokens carry the same claims.
  schema {
    name                     = "email"
    attribute_data_type      = "String"
    developer_only_attribute = false
    mutable                  = true
    required                 = true
    string_attribute_constraints {
      min_length = 5
      max_length = 254
    }
  }

  schema {
    name                     = "id_enterprise"
    attribute_data_type      = "String"
    developer_only_attribute = false
    mutable                  = true
    required                 = false
    string_attribute_constraints {
      min_length = 1
      max_length = 64
    }
  }

  # No UserMigration Lambda: dev users are created here, never migrated from Firebase.

  tags = {
    Component = "auth"
    ADR       = "0060"
    Env       = "dev"
  }
}

# Public SPA client, same flows as staging's front4-amplify (cognito.tf). ALLOW_USER_PASSWORD_AUTH
# also lets scripts/tests obtain a token with `aws cognito-idp initiate-auth`.
resource "aws_cognito_user_pool_client" "dev_spa" {
  name         = "dev-spa"
  user_pool_id = aws_cognito_user_pool.dev.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  supported_identity_providers  = ["COGNITO"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
  auth_session_validity         = 3
}

resource "random_password" "dev_cognito_user" {
  for_each    = local.dev_cognito_users
  length      = 20
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "aws_cognito_user" "dev" {
  for_each       = local.dev_cognito_users
  user_pool_id   = aws_cognito_user_pool.dev.id
  username       = each.value
  password       = random_password.dev_cognito_user[each.key].result # permanent: no forced change
  message_action = "SUPPRESS"

  attributes = {
    email          = each.value
    email_verified = true
    id_enterprise  = local.dev_cognito_tenant
  }
}

resource "aws_secretsmanager_secret" "dev_cognito" {
  name        = "packiot/dev/cognito"
  description = "ADR-0060 dev Cognito pool: pool/client ids, issuer and the synthetic dev users' passwords (dev only)."
  tags = {
    ADR = "0060"
    Env = "dev"
  }
}

resource "aws_secretsmanager_secret_version" "dev_cognito" {
  secret_id = aws_secretsmanager_secret.dev_cognito.id
  secret_string = jsonencode({
    user_pool_id = aws_cognito_user_pool.dev.id
    client_id    = aws_cognito_user_pool_client.dev_spa.id
    issuer       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.dev.id}"
    users        = { for k, email in local.dev_cognito_users : email => random_password.dev_cognito_user[k].result }
  })
}

# Not secret: Amplify ships these in the browser bundle anyway.
output "dev_cognito_user_pool_id" {
  value = aws_cognito_user_pool.dev.id
}

output "dev_cognito_client_id" {
  value = aws_cognito_user_pool_client.dev_spa.id
}

output "dev_cognito_issuer" {
  value = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.dev.id}"
}
