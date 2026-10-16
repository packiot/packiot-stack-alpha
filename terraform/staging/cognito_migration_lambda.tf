# ── Cognito User Migration Lambda — STAGING (ADR-0034 §4) ─────────────────────
#
# JIT "migrate-on-login" trigger: the first time a not-yet-in-Cognito user signs
# in against the staging pool, Cognito invokes this Lambda with the plaintext
# password; the Lambda validates it against Firebase's Identity Toolkit REST API
# (using the semi-public Firebase WEB API KEY — never the retired Admin SA key)
# and, on success, Cognito creates the user natively carrying that password.
#
# SAFETY / REVERSIBILITY (this is BUILD + PROVE, not cutover):
#   • Staging-only. Touches nothing in prod and nothing in GCP/Firebase until the
#     USER deliberately populates the secret + points FIREBASE_PROJECT_ID at prod.
#   • The Firebase-verify credential is a NEW Secrets Manager secret whose VALUE
#     IS NOT SET HERE — it is populated manually at cutover (see the secret's
#     description + docs/adr/reference/0034-jit-user-migration-lambda.md).
#   • MIGRATION_ENABLED defaults to "false": wiring the trigger onto the pool is
#     inert (every invocation denies) until the USER flips it at cutover.
#   • `terraform destroy` removes the Lambda, role, and secret cleanly.

# ── The Firebase web-API-key secret (VALUE NOT SET IN CODE) ───────────────────
# Populate manually at cutover — mirrors the github_runner secret pattern:
#   aws secretsmanager put-secret-value \
#     --secret-id packiot/staging/firebase-web-api-key \
#     --region us-east-1 \
#     --secret-string '{"web_api_key":"<STAGING_FIREBASE_WEB_API_KEY>"}'
# The Lambda reads it at runtime via the IAM role below — the value never lands
# in terraform state, code, or the Lambda's env.
resource "aws_secretsmanager_secret" "firebase_web_api_key" {
  name                    = "packiot/staging/firebase-web-api-key"
  recovery_window_in_days = 0
  description             = "Firebase WEB API key (Identity Toolkit) for the Cognito migrate-on-login Lambda — populate manually at cutover; NOT the Admin SA key. See docs/adr/reference/0034-jit-user-migration-lambda.md"
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
  name = "packiot-staging-cognito-user-migration"
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
  function_name = "packiot-staging-cognito-user-migration"
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

      # Which Firebase project to verify against. Set to `fbpackiot` (front4's
      # Firebase project) for the STAGING copy exercise (2026-09-03): a front4
      # user's first Cognito login is validated against fbpackiot Firebase and
      # COPIED into the staging pool. The web API key already scopes the project;
      # this is informational/guard metadata for logs + future validation.
      FIREBASE_PROJECT_ID = "fbpackiot"

      # Master gate. ON (2026-09-03) — front4 Cognito-only cutover: migrate-on-
      # login copies Firebase users into the pool. Firebase is never mutated.
      MIGRATION_ENABLED = "true"
    }
  }

  tags = {
    Component = "auth"
    ADR       = "0034"
  }
}

# ── Allow the Cognito user pool to invoke the Lambda ──────────────────────────
resource "aws_lambda_permission" "cognito_invoke" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.user_migration.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.staging.arn
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cognito_user_migration_lambda_arn" {
  description = "ARN of the Cognito migrate-on-login Lambda (ADR-0034)"
  value       = aws_lambda_function.user_migration.arn
}

output "firebase_web_api_key_secret_populate" {
  description = "Command to populate the Firebase-verify secret at cutover (USER-gated; value NOT set by terraform)"
  value       = "aws secretsmanager put-secret-value --secret-id ${aws_secretsmanager_secret.firebase_web_api_key.name} --region ${var.aws_region} --secret-string '{\"web_api_key\":\"<STAGING_FIREBASE_WEB_API_KEY>\"}'"
}
