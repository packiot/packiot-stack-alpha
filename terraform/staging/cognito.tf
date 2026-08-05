# ── Amazon Cognito — STAGING user pool (ADR-0034) ─────────────────────────────
#
# Foundation for the Firebase → Cognito auth migration. Staging-only, isolated,
# reversible (terraform destroy removes it cleanly). Touches nothing in prod and
# nothing in GCP/Firebase.
#
# End-state (ADR-0034): front4 (Amplify Auth SDK) signs users in against this
# pool; refdata-api dual-verifies Cognito JWTs alongside Firebase during the
# migration window. The tenant binding `id_enterprise` is modelled as a native
# custom attribute so it can be surfaced as a token claim (custom:id_enterprise)
# — harmless if the team later chooses a DB-lookup instead of a claim.
#
# Tier: LITE — preserves the free MAU allowance (USER confirmed <10k MAU). This
# explicitly avoids the paid ESSENTIALS default and the PLUS threat-protection
# add-on (advanced security), which is why no `user_pool_add_ons` block is set.

resource "aws_cognito_user_pool" "staging" {
  name = "packiot-staging"

  # Free-tier plan. Do NOT change to ESSENTIALS/PLUS without a cost review.
  user_pool_tier = "LITE"

  # Email is the login identifier — direct email/password sign-in, no username.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Staging convenience: allow `terraform destroy` to remove the pool without a
  # manual console step. Flip to "ACTIVE" if this pool is ever promoted.
  deletion_protection = "INACTIVE"

  password_policy {
    minimum_length                   = 8
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # Recovery only via a verified email (no SMS — no phone attribute collected).
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  username_configuration {
    case_sensitive = false
  }

  # Standard attribute: email is required and immutable-in-spirit but kept
  # mutable so a user can update it via the normal Cognito flow.
  schema {
    name                     = "email"
    attribute_data_type      = "String"
    developer_only_attribute = false
    mutable                  = true
    required                 = true
    string_attribute_constraints {
      min_length = 5
      max_length = 254 # RFC 5321 max email length
    }
  }

  # Custom attribute → surfaces in tokens as `custom:id_enterprise`.
  # The tenant binding. Mutable so migrate-on-login / admin flows can set it.
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

  # Custom attribute → surfaces as `custom:firebase_uid`. Set by the User
  # Migration Lambda (ADR-0034 §4) when a Firebase user is migrated on login: it
  # carries the legacy Firebase uid (localId) forward so a later reconciler can
  # map Firebase uid ↔ Cognito sub. Cognito never removes custom attributes, so
  # this is purely additive; harmless once the migration window closes.
  schema {
    name                     = "firebase_uid"
    attribute_data_type      = "String"
    developer_only_attribute = false
    mutable                  = true
    required                 = false
    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  # ── User Migration trigger (ADR-0034 §4 — JIT Firebase→Cognito) ─────────────
  # Wires the migrate-on-login Lambda as the pool's UserMigration trigger. This
  # is ADDITIVE + INERT until cutover: the Lambda's MIGRATION_ENABLED flag
  # defaults OFF and the Firebase-verify secret is unpopulated, so every
  # invocation denies (a login for a non-existent Cognito user fails exactly as
  # it does today). Reversible: remove this block (or set the ARN to null) to
  # detach the trigger. See cognito_migration_lambda.tf.
  lambda_config {
    user_migration = aws_lambda_function.user_migration.arn
  }

  # No advanced security (threat protection) — that requires the paid PLUS tier.

  tags = {
    Component = "auth"
    ADR       = "0034"
  }
}

# ── App client for front4 (Amplify Auth) ──────────────────────────────────────
#
# PUBLIC client (no secret) — front4 is a browser SPA, a secret would be exposed.
# Amplify uses SRP for password auth; refresh tokens keep sessions alive.
resource "aws_cognito_user_pool_client" "front4" {
  name         = "front4-amplify"
  user_pool_id = aws_cognito_user_pool.staging.id

  generate_secret = false # public client — SPA cannot keep a secret

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",     # Amplify default password sign-in (SRP)
    "ALLOW_REFRESH_TOKEN_AUTH" # silent session refresh
  ]

  # Token lifetimes.
  access_token_validity  = 1  # hours
  id_token_validity      = 1  # hours
  refresh_token_validity = 30 # days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Cognito-native users only (no federated IdPs in staging).
  supported_identity_providers = ["COGNITO"]

  # Return an explicit AuthN error instead of a generic one only when it does not
  # leak whether an account exists — Cognito best practice.
  prevent_user_existence_errors = "ENABLED"

  enable_token_revocation = true
  auth_session_validity   = 3 # minutes — for challenge/response flows

  # No hosted-UI OAuth flows: front4 uses the Amplify SDK directly, so no
  # callback/logout URLs or Cognito hosted domain are provisioned.
}

# ── Hosted-UI domain (ADR-0034 §C — Authentik retirement) ─────────────────────
#
# oauth2-proxy (the forward-auth gate that replaces Authentik's embedded outpost
# in front of the internal admin UIs) drives the OIDC *authorization-code* flow.
# That flow needs Cognito's hosted `/oauth2/authorize` + `/oauth2/token`
# endpoints, which only exist once a domain is attached to the pool. The prefix
# resolves to https://packiot-auth.auth.us-east-1.amazoncognito.com and is
# advertised in the pool's OIDC discovery document — oauth2-proxy discovers it
# automatically from the issuer URL. Additive; the front4 SDK path is unaffected.
resource "aws_cognito_user_pool_domain" "hosted_ui" {
  domain       = "packiot-auth"
  user_pool_id = aws_cognito_user_pool.staging.id
}

# ── Confidential app clients for oauth2-proxy (one per environment) ────────────
#
# Unlike front4 (a browser SPA → public, secretless), oauth2-proxy is a
# server-side confidential client: it keeps a secret and runs the code flow with
# a back-channel token exchange. Separate clients per environment so a staging
# session can never mint a token accepted at the prod callback, even though both
# share this single pool (the ADR-0034 migration reality — prod csadmin already
# authenticates against it). The secret is read post-apply via
# `aws cognito-idp describe-user-pool-client` and placed in each host's `.env`
# (OAUTH2_PROXY_CLIENT_SECRET) — never committed.
locals {
  oauth2_proxy_clients = {
    staging = "auth.staging.packiot.app"
    prod    = "auth.prod.packiot.app"
  }
}

resource "aws_cognito_user_pool_client" "oauth2_proxy" {
  for_each     = local.oauth2_proxy_clients
  name         = "oauth2-proxy-${each.key}"
  user_pool_id = aws_cognito_user_pool.staging.id

  generate_secret = true # confidential server-side client

  # Authorization-code flow via the hosted UI (no direct password flows here —
  # oauth2-proxy never sees the password; Cognito's hosted login does).
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = ["https://${each.value}/oauth2/callback"]
  logout_urls   = ["https://${each.value}/oauth2/sign_out"]

  # Token lifetimes mirror front4; refresh keeps the SSO session alive across the
  # *.{{env}}.packiot.app admin UIs (cookie is scoped to the parent domain).
  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
  auth_session_validity         = 3

  # The hosted-UI domain must exist before a client can use the OAuth flows.
  depends_on = [aws_cognito_user_pool_domain.hosted_ui]

  lifecycle {
    # `generate_secret` is create-only AND cannot be read back on import (the
    # Cognito API returns the secret value but no boolean saying one was
    # generated), so a freshly-imported client reads it as false and would
    # otherwise force-replace — churning the client_id and invalidating the
    # secret already placed in each host's .env. These clients were bootstrapped
    # via CLI (with --generate-secret) then imported; ignore the attribute so
    # plan/apply stays a no-op. Removing a client still works: `terraform state
    # rm` + delete the app client.
    ignore_changes = [generate_secret]
  }
}
