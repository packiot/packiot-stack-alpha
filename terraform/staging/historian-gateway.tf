# historian-gateway — scoped read-only S3 credential for the pg_duckdb cold path.
#
# The gateway (services/historian-gateway, compose.historian-gateway.yml) reads
# the S3 Parquet historian via DuckDB. Instance-role credential_chain is NOT
# usable: the staging DB enforces IMDSv2 and DuckDB's aws extension cannot fetch
# v2 creds through the docker hop — so the gateway needs an explicit key, scoped
# to read-only on the historian bucket only.
#
# The user + inline policy below were created manually for the staging PoC and
# should be ADOPTED via `import` blocks (terraform >= 1.5) rather than recreated.
# The ACCESS KEY is deliberately NOT a Terraform resource: an aws_iam_access_key puts
# the secret in plaintext in TF state. It lives in Secrets Manager
# packiot/staging/historian-gateway-s3 ({key_id, secret}) and is rotated with
# scripts/rotate-historian-s3-key.sh (create → SM → box .env.historian-gateway +
# pg_duckdb mappings → verify → deactivate old → verify → delete old).
# Rotated 2026-09-24 (P1: the previous key was exposed in a session transcript).

variable "historian_bucket" {
  type    = string
  default = "packiot-staging-historian-639178078294"
}

resource "aws_iam_user" "historian_gateway" {
  name = "svc-historian-gateway"
  tags = {
    purpose = "historian-gateway-ro"
    managed = "terraform"
  }
}

resource "aws_iam_user_policy" "historian_gateway_ro" {
  name = "historian-ro"
  user = aws_iam_user.historian_gateway.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.historian_bucket}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.historian_bucket}"
      },
    ]
  })
}

# Adopt the manually-created user + policy instead of recreating (terraform >=1.5):
import {
  to = aws_iam_user.historian_gateway
  id = "svc-historian-gateway"
}
import {
  to = aws_iam_user_policy.historian_gateway_ro
  id = "svc-historian-gateway:historian-ro"
}
