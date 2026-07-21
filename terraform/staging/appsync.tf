# ── AWS AppSync — STAGING GraphQL "space" ─────────────────────────────────────
#
# A wired, functional, but intentionally NEAR-EMPTY managed GraphQL endpoint.
# The point is to have the door open: a real, Cognito-authed GraphQL API that
# proves out auth + resolvers, ready to grow a schema WHEN a concrete need
# appears — not before. Right now it exposes a single placeholder query, `_ping`,
# resolved locally (NONE data source → static "pong"), so there is no backend
# and no per-request cost beyond the AppSync operation itself.
#
# Auth model:
#   • PRIMARY  = AMAZON_COGNITO_USER_POOLS  → wired to the staging Cognito pool
#                (aws_cognito_user_pool.staging, ADR-0034). This makes the
#                GraphQL space tenant-aware and consistent with the Firebase→
#                Cognito auth consolidation from day one — a real caller presents
#                a Cognito access/id token.
#   • ADDITIONAL = API_KEY  → dev/testing convenience only, so you can curl the
#                endpoint without minting a Cognito token. NOT the real auth.
#
# Cost: pay-per-operation. First 250k query/data-modification ops/mo are free
# tier; an idle API costs ~$0. CloudWatch log ingestion at ERROR level is a few
# cents. Fully reversible — `terraform destroy` removes everything here cleanly.
#
# Staging-only. Touches nothing in prod, nothing in GCP/Firebase.
# ──────────────────────────────────────────────────────────────────────────────

# IAM role AppSync assumes to push field-level logs to CloudWatch Logs.
resource "aws_iam_role" "appsync_logs" {
  name = "packiot-staging-appsync-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "appsync.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Component = "graphql"
  }
}

resource "aws_iam_role_policy_attachment" "appsync_logs" {
  role       = aws_iam_role.appsync_logs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppSyncPushToCloudWatchLogs"
}

# ── The GraphQL API ───────────────────────────────────────────────────────────
resource "aws_appsync_graphql_api" "staging" {
  name = "packiot-staging-graphql"

  # Cognito is the real auth. A caller must present a valid token from the
  # staging user pool; `default_action = ALLOW` lets the per-field auth (there
  # is none yet) fall through to the pool's own token validation.
  authentication_type = "AMAZON_COGNITO_USER_POOLS"

  user_pool_config {
    user_pool_id   = aws_cognito_user_pool.staging.id
    aws_region     = var.aws_region
    default_action = "ALLOW"
  }

  # Dev-convenience secondary auth: lets you hit `_ping` with just an API key,
  # no Cognito token required. Cognito remains the authoritative mechanism.
  additional_authentication_provider {
    authentication_type = "API_KEY"
  }

  # Cheap field-level logging to CloudWatch. ERROR keeps ingestion tiny; X-Ray
  # tracing stays off to avoid its per-trace cost.
  log_config {
    cloudwatch_logs_role_arn = aws_iam_role.appsync_logs.arn
    field_log_level          = "ERROR"
    exclude_verbose_content  = true
  }

  xray_enabled = false

  # ── PLACEHOLDER SCHEMA ──────────────────────────────────────────────────────
  # Deliberately minimal: one query, `_ping`, returning a non-null String.
  # EXPAND THIS by adding types + resolvers backed by a real data source:
  #   • HTTP data source → refdata-api `/v1/*` (the read plane) for tenant data
  #   • Lambda data source → custom resolvers / mutations
  #   • RDS/RDS-Data data source → direct DB reads
  # See docs/graphql-space.md for the step-by-step expansion recipe.
  # (Single leading underscore is legal GraphQL; `__` double-underscore is
  #  reserved for introspection, so `_ping` is a safe placeholder name.)
  #
  # NOTE ON DIRECTIVES: with more than one auth provider configured, an
  # un-annotated field is reachable ONLY by the API's default auth mode
  # (Cognito). To let the dev API key ALSO hit `_ping`, the field is annotated
  # with both `@aws_api_key` and `@aws_cognito_user_pools`. New fields you add
  # get Cognito-only by default unless you opt them into `@aws_api_key` too.
  schema = <<-GRAPHQL
    schema {
      query: Query
    }

    type Query {
      "Liveness probe — always returns \"pong\". Placeholder; replace with real fields."
      _ping: String! @aws_api_key @aws_cognito_user_pools
    }
  GRAPHQL

  tags = {
    Component = "graphql"
    ADR       = "0034"
  }
}

# ── Local (NONE) data source — no backend, no cost ────────────────────────────
# Resolves entirely inside AppSync's mapping templates; never calls out.
resource "aws_appsync_datasource" "none" {
  api_id = aws_appsync_graphql_api.staging.id
  name   = "none_local"
  type   = "NONE"
}

# ── Resolver for Query._ping ──────────────────────────────────────────────────
# VTL unit resolver against the NONE data source: the request template sets the
# payload to the literal "pong", the response template echoes it back as JSON.
resource "aws_appsync_resolver" "ping" {
  api_id      = aws_appsync_graphql_api.staging.id
  type        = "Query"
  field       = "_ping"
  data_source = aws_appsync_datasource.none.name

  request_template = <<-VTL
    {
      "version": "2018-05-29",
      "payload": "pong"
    }
  VTL

  response_template = "$util.toJson($ctx.result)"
}

# ── Dev-convenience API key ───────────────────────────────────────────────────
# For local/dev testing only (see the API_KEY additional auth provider above).
# Fixed expiry avoids a perpetual plan diff; AppSync caps key lifetime at 365
# days. ROTATE before this date (bump `expires`, re-apply) if the space is still
# just `_ping`; if a real consumer appears, give it a Cognito token instead.
resource "aws_appsync_api_key" "dev" {
  api_id      = aws_appsync_graphql_api.staging.id
  description = "Dev/testing convenience key — NOT the real auth (Cognito is)."
  expires     = "2027-07-01T00:00:00Z"
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "graphql_api_id" {
  description = "AppSync GraphQL API id (packiot-staging-graphql)"
  value       = aws_appsync_graphql_api.staging.id
}

output "graphql_endpoint" {
  description = "GraphQL endpoint URL. Auth = Cognito user-pool token (shared with aws_cognito_user_pool.staging) OR the dev API key."
  value       = aws_appsync_graphql_api.staging.uris["GRAPHQL"]
}

output "graphql_api_key" {
  description = "Dev-convenience API key (x-api-key header). Cognito is the real auth; this is for quick curl/testing only."
  value       = aws_appsync_api_key.dev.key
  sensitive   = true
}
