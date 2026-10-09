# ── S3 bucket for staging DB backups ──────────────────────────────────────────
# Nightly pg_dump from the DB EC2 lands here; lifecycle expires raw objects
# after 90 days. The backup script itself enforces 14 daily + 4 weekly +
# 3 monthly = ~21 active objects via keyed paths; the lifecycle rule is a
# belt-and-braces cap so a misbehaving script can't run up costs.

resource "aws_s3_bucket" "db_backups" {
  bucket = "packiot-staging-db-backups-${data.aws_caller_identity.current.account_id}"
  tags = {
    Name    = "packiot-staging-db-backups"
    Purpose = "PostgreSQL nightly pg_dump custom-format gzipped"
  }
}

# Block all public access — backups contain PII (factory equipment names,
# credentials in pg_dump if not stripped, real production data).
resource "aws_s3_bucket_public_access_block" "db_backups" {
  bucket                  = aws_s3_bucket.db_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption with AES-256 (free). KMS would add per-request cost
# without meaningful improvement for a staging DB backup.
resource "aws_s3_bucket_server_side_encryption_configuration" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning ON (2026-09-30 backup audit; NOT YET APPLIED — live is still
# unversioned). Without it one bad prune loop, a compromised DB-box role (it holds
# s3:DeleteObject on the whole bucket) or an overwrite of the `latest` keys
# destroys backups irrecoverably. With it, deletes become delete markers and
# overwritten objects become noncurrent versions, expired by the lifecycle rule
# below after 30 days. Cost: ~one extra day of dumps per overwrite of `latest`.
resource "aws_s3_bucket_versioning" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle: hard 90-day expiration on EVERY object regardless of key prefix.
# This is a runaway-cost guard, not the primary retention mechanism. The
# backup script's own retention logic (in backup-db.sh) decides which keys
# to keep within those 90 days.
resource "aws_s3_bucket_lifecycle_configuration" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id
  rule {
    id     = "expire-after-90-days"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    # Clean up incomplete multipart uploads from interrupted pg_dump streams
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
    # With versioning on: deleted/overwritten versions stay recoverable 30 days.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"
    filter {}
    expiration {
      expired_object_delete_marker = true
    }
  }
}

# ── IAM: DB EC2 can write, delete, list the backup bucket ─────────────────────
# Attached to the existing packiot-staging-db role. pg_dump runs on the DB EC2
# (closest to data, no VPC egress charges).

resource "aws_iam_policy" "db_backup_writer" {
  name = "packiot-staging-db-backup-writer"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteAndListBackups"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
        ]
        Resource = "${aws_s3_bucket.db_backups.arn}/*"
      },
      {
        Sid      = "ListBucketContents"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.db_backups.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "db_backup_writer" {
  role       = aws_iam_role.db.name
  policy_arn = aws_iam_policy.db_backup_writer.arn
}

# ── IAM: app EC2 — historian backup (put-only) + emergency-restore SSM ────────
# The historian lives on the APP box (hist-gateway catalog DB + the Parquet cold
# store), so its nightly backup (scripts/backup-historian.sh) runs there. The
# grant is PUT/GET-only on its two prefixes — deliberately no s3:DeleteObject, so
# a compromised app box cannot destroy backups (backup-historian.sh runs with
# PRUNE=0; the 90-day lifecycle caps age).
# SendCommand to the DB box: the "EMERGENCY – restore database" workflow runs on
# the self-hosted staging runner (this box) and drives restore-db.sh on the DB box
# through SSM. Scoped by the DB instance's Name tag. The app box already holds the
# DB superuser password in /opt/packiot/.env, so this adds no new blast radius.
# NOT YET APPLIED (2026-09-30): until it is, backup-historian.sh runs in its
# "interim" configuration (catalog dumps into the historian bucket's _backup/, no
# Parquet mirror) and the emergency workflow can only restore the historian —
# analytics/superset restores fall back to the manual runbook commands.
# Apply: terraform apply -target=aws_iam_role_policy.app_backup_ops
resource "aws_iam_role_policy" "app_backup_ops" {
  name = "packiot-staging-app-backup-ops"
  role = aws_iam_role.app.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "HistorianBackupPutGet"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = [
          "${aws_s3_bucket.db_backups.arn}/packiot_historian/*",
          "${aws_s3_bucket.db_backups.arn}/historian-parquet/*",
        ]
      },
      {
        Sid      = "HistorianBackupList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.db_backups.arn
        Condition = {
          StringLike = { "s3:prefix" = ["packiot_historian/*", "historian-parquet/*"] }
        }
      },
      {
        Sid      = "EmergencyRestoreSendCommandDocument"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = ["arn:aws:ssm:us-east-1::document/AWS-RunShellScript"]
      },
      {
        Sid      = "EmergencyRestoreSendCommandToDbBox"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = ["arn:aws:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*"]
        Condition = {
          StringEquals = { "ssm:resourceTag/Name" = "packiot-staging-db" }
        }
      },
      {
        Sid      = "EmergencyRestoreReadResults"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = ["*"]
      },
    ]
  })
}


# ── Outputs ───────────────────────────────────────────────────────────────────
output "db_backup_bucket" {
  value       = aws_s3_bucket.db_backups.bucket
  description = "S3 bucket for nightly DB backups; used by backup-db.sh on the DB EC2"
}
