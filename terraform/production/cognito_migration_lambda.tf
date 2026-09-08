# ── Cognito User Migration Lambda — PRODUCTION (ADR-0034 §4 / #159) ────────────
#
# JIT "migrate-on-login" trigger for the PROD customer pool: the first time a
# not-yet-in-Cognito customer signs in against packiot-prod, Cognito invokes this
# Lambda with the plaintext password; the Lambda validates it against Firebase's
# Identity Toolkit REST API (using the semi-public Firebase WEB API KEY — never
# the retired Admin SA key) and, on success, Cognito creates the user natively
# carrying that same password. No forced resets; Firebase is never mutated.
#
# SAFETY / REVERSIBILITY (this is AUTHORING, not cutover):
#   • MIGRATION_ENABLED defaults to "false" → wiring the trigger onto the pool is
#     INERT (every invocation denies) until the USER flips it at cutover (epic
#     Phase 2, just-before the front4-prod flip).
#   • The Firebase-verify credential is a NEW Secrets Manager secret whose VALUE
#     IS NOT SET HERE — it is populated manually at cutover (see the secret's
#     description + the epic runbook). The value never lands in terraform state,
#     code, or the Lambda's env.
#   • Touches nothing in prod-customer auth and nothing in GCP/Firebase until the
#     USER deliberately populates the secret AND flips MIGRATION_ENABLED=true.
#   • FIREBASE_PROJECT_ID = fbpackiot (the single, real Firebase project) — the
#     web API key already scopes the project; this is guard/log metadata.

# ── The Firebase web-API-key secret (VALUE NOT SET IN CODE) ───────────────────
# Populate manually at cutover:
#   aws secretsmanager put-secret-value \
#     --secret-id packiot/prod/firebase-web-api-key \
#     --region us-east-1 \
#     --secret-string '{"web_api_key":"<FIREBASE_WEB_API_KEY>"}'
resource "aws_secretsmanager_secret" "firebase_web_api_key" {
  name                    = "packiot/prod/firebase-web-api-key"
  recovery_window_in_days = 0
  description             = "Firebase WEB API key (Identity Toolkit) for the PROD Cognito migrate-on-login Lambda — populate manually at cutover; NOT the Admin SA key. See docs/plans/firebase-to-cognito-migration-epic.md"
}

# ── Package the handler (index.mjs only — no node_modules; the Node 20 runtime
#    bundles @aws-sdk/* and provides global fetch) ─────────────────────────────
data "archive_file" "user_migration" {
  type        = "zip"
  source_file = "${path.module}/../../services/cognito-user-migration/index.mjs"
  output_path = "${path.module}/.build/cognito-user-migration.zip"
}

# ── IAM role: logs + read ONLY the Firebase-verify secret ─────────────────────
resource "aws_iam_role" "user_migration" {
  name = "packiot-prod-cognito-user-migration"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = {
    Component = "auth"
    ADR       = "0034"
    Jira      = "159"
  }
}

# CloudWatch Logs (basic execution).
resource "aws_iam_role_policy_attachment" "user_migration_logs" {
  role       = aws_iam_role.user_migration.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read ONLY the one Firebase-verify secret — least privilege.
resource "aws_iam_role_policy" "user_migration_secret" {
  name = "read-firebase-web-api-key"
  role = aws_iam_role.user_migration.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.firebase_web_api_key.arn
    }]
  })
}

# ── The Lambda ────────────────────────────────────────────────────────────────
resource "aws_lambda_function" "user_migration" {
  function_name = "packiot-prod-cognito-user-migration"
  role          = aws_iam_role.user_migration.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  architectures = ["arm64"] # cheapest; matches the t4g fleet
  timeout       = 10        # one outbound Firebase REST call + a secret fetch
  memory_size   = 128

  filename         = data.archive_file.user_migration.output_path
  source_code_hash = data.archive_file.user_migration.output_base64sha256

  environment {
    variables = {
      # Reference to the secret (the VALUE is fetched at runtime, never here).
      FIREBASE_WEB_API_KEY_SECRET_ID = aws_secretsmanager_secret.firebase_web_api_key.name

      # The single real Firebase project (front4's) — a customer's first Cognito
      # login is validated against fbpackiot and COPIED into the prod pool. The
      # web API key already scopes the project; this is guard/log metadata.
      FIREBASE_PROJECT_ID = "fbpackiot"

      # Master gate. OFF (authoring) — the trigger is wired but inert. The USER
      # flips this to "true" at cutover (epic Phase 2), just-before the
      # front4-prod Cognito flip. Firebase is never mutated.
      MIGRATION_ENABLED = "false"
    }
  }

  tags = {
    Component = "auth"
    ADR       = "0034"
    Jira      = "159"
  }
}

# ── Allow the Cognito user pool to invoke the Lambda ──────────────────────────
resource "aws_lambda_permission" "cognito_invoke" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.user_migration.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.prod.arn
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cognito_user_migration_lambda_arn" {
  description = "ARN of the PROD Cognito migrate-on-login Lambda (ADR-0034 / #159)"
  value       = aws_lambda_function.user_migration.arn
}

output "firebase_web_api_key_secret_populate" {
  description = "Command to populate the Firebase-verify secret at cutover (USER-gated; value NOT set by terraform)"
  value       = "aws secretsmanager put-secret-value --secret-id ${aws_secretsmanager_secret.firebase_web_api_key.name} --region ${var.aws_region} --secret-string '{\"web_api_key\":\"<FIREBASE_WEB_API_KEY>\"}'"
}
