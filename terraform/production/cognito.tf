# ── Amazon Cognito — PRODUCTION user pool (ADR-0034 / #159 Path B) ─────────────
#
# The dedicated PRODUCTION customer-auth pool for the Firebase → Cognito
# migration (docs/plans/firebase-to-cognito-migration-epic.md). This pool serves
# the LEGACY customer plane (front4-prod → api4.packiot.com / edge.api4 →
# back4-api + primary-api + edge-api-prod on the packiot40 DB).
#
# WHY A SEPARATE POOL (not the staging `packiot-staging` pool):
#   Mixing planes in one pool is a blast-radius + hygiene hazard — staging test
#   users would become prod-authenticatable, and a staging pool change could 401
#   the customer base. This is the dedicated prod identity store; the front4
#   Amplify SPA points at THIS pool once Phase 3 of the epic flips the env.
#
# SCOPE NOTE — the prod internal-admin SSO (oauth2-proxy in front of the
# *.prod.packiot.app admin UIs) already authenticates against the STAGING pool
# (see user_data/app_init.sh COGNITO_USER_POOL_ID=us-east-1_0T9t1sTwt, ADR-0034
# §C). That is a SEPARATE concern and is intentionally NOT moved here: this pool
# is exclusively the front4 CUSTOMER plane. Migrating oauth2-proxy onto this pool
# (and adding its confidential clients) is a later, independent step.
#
# SAFETY / REVERSIBILITY (this is AUTHORING, not cutover):
#   • Additive — creating the pool changes nothing for logged-in customers; they
#     keep using Firebase until front4-prod's env is flipped (epic Phase 3).
#   • The UserMigration trigger is INERT: the prod lambda ships with
#     MIGRATION_ENABLED=false and an unpopulated Firebase-verify secret, so every
#     invocation denies (see cognito_migration_lambda.tf).
#   • deletion_protection = ACTIVE (unlike staging's INACTIVE) — a prod customer
#     pool that will hold 828 migrated identities must NOT be removable by a stray
#     `terraform destroy`. Flip to INACTIVE only for a deliberate teardown.
#
# Tier: LITE — preserves the free MAU allowance (~828 customer users, well under
# the 10k free-tier ceiling). Explicitly avoids paid ESSENTIALS/PLUS.

resource "aws_cognito_user_pool" "prod" {
  name = "packiot-prod"

  # Free-tier plan. Do NOT change to ESSENTIALS/PLUS without a cost review.
  user_pool_tier = "LITE"

  # Email is the login identifier — direct email/password sign-in, no username.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # PROD deviation from staging: protect the customer pool from accidental
  # destroy. Flip to "INACTIVE" only for an intentional teardown.
  deletion_protection = "ACTIVE"

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

  # Standard attribute: email is required, kept mutable so a user can update it
  # via the normal Cognito flow.
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
  # NOTE: the current migrate-on-login Lambda does NOT populate this claim —
  # tenant resolution happens server-side via users.id_user_cognito + link-on-
  # login (epic §3.2). The attribute is kept for parity + future claim-based
  # resolution; harmless if unused.
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
  # Migration Lambda when a Firebase user is migrated on login: it carries the
  # legacy Firebase uid (localId) forward so a later reconciler can map
  # Firebase uid ↔ Cognito sub. Purely additive; harmless once migration closes.
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
  # Wires the migrate-on-login Lambda as the pool's UserMigration trigger.
  # ADDITIVE + INERT until cutover: the Lambda's MIGRATION_ENABLED flag defaults
  # OFF and the Firebase-verify secret is unpopulated, so every invocation denies
  # (a login for a non-existent Cognito user fails exactly as it does today).
  # Reversible: remove this block to detach the trigger. See
  # cognito_migration_lambda.tf.
  lambda_config {
    user_migration = aws_lambda_function.user_migration.arn
  }

  # No advanced security (threat protection) — that requires the paid PLUS tier.

  tags = {
    Component = "auth"
    ADR       = "0034"
    Jira      = "159"
    Plane     = "legacy-customer"
  }
}

# ── App client for front4-prod (Amplify Auth) ─────────────────────────────────
#
# PUBLIC client (no secret) — front4 is a browser SPA, a secret would be exposed.
# Amplify uses SRP for password auth; USER_PASSWORD_AUTH is enabled so the
# UserMigration Lambda can fire on a Firebase user's first login (SRP can't
# trigger it — the user isn't in the pool yet). Refresh tokens keep sessions.
resource "aws_cognito_user_pool_client" "front4" {
  name         = "front4-amplify"
  user_pool_id = aws_cognito_user_pool.prod.id

  generate_secret = false # public client — SPA cannot keep a secret

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",      # Amplify default password sign-in (SRP)
    "ALLOW_USER_PASSWORD_AUTH", # so the migrate-on-login Lambda fires on 1st login
    "ALLOW_REFRESH_TOKEN_AUTH", # silent session refresh
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

  # Cognito-native users only (no federated IdPs).
  supported_identity_providers = ["COGNITO"]

  # Do not leak whether an account exists.
  prevent_user_existence_errors = "ENABLED"

  enable_token_revocation = true
  auth_session_validity   = 3 # minutes — for challenge/response flows

  # No hosted-UI OAuth flows: front4 uses the Amplify SDK directly.
}

# ── Hosted-UI domain ──────────────────────────────────────────────────────────
#
# Provisions Cognito's hosted /oauth2/* + /login endpoints under
# https://packiot-prod-auth.auth.us-east-1.amazoncognito.com. front4's Amplify
# SDK path does NOT use this today (it does SRP/USER_PASSWORD_AUTH directly), but
# the domain is required to later (a) surface Cognito hosted forgot-password (the
# Firebase reset flow goes inert under Cognito — epic §1.1) and (b) migrate the
# prod oauth2-proxy admin SSO onto this pool. The prefix is globally unique per
# region — `packiot-auth` is already taken by staging, hence `packiot-prod-auth`.
# Additive; harmless while unconsumed.
resource "aws_cognito_user_pool_domain" "hosted_ui" {
  domain       = "packiot-prod-auth"
  user_pool_id = aws_cognito_user_pool.prod.id
}
