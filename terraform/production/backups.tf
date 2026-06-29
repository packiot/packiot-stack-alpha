# ── S3 bucket for production DB backups ──────────────────────────────────────
# Production has an EMPTY local TimescaleDB in the dry-run phase, so daily
# pg_dump backups produce ~zero-byte objects today. The bucket + IAM are
# provisioned anyway so phase 2 (real prod DB connection) doesn't have a
# bootstrap step — backups start landing immediately when the DB has data.
#
# Same shape as staging's bucket; longer retention (180 days vs 90) because
# production backups are recovery-of-last-resort during the migration window.

resource "aws_s3_bucket" "db_backups" {
  bucket = "packiot-production-db-backups-${data.aws_caller_identity.current.account_id}"
  tags = {
    Name    = "packiot-production-db-backups"
    Purpose = "PostgreSQL nightly pg_dump custom-format gzipped"
  }
}

# Block all public access — backups contain PII once phase 2 lands and
# real customer data starts flowing through pg_dump.
resource "aws_s3_bucket_public_access_block" "db_backups" {
  bucket                  = aws_s3_bucket.db_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption with AES-256 (free). For phase 3 (real customer
# data), evaluate KMS for the extra audit trail; AES-256 is fine for the
# dry-run period.
resource "aws_s3_bucket_server_side_encryption_configuration" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning off — backups are immutable named objects; overwriting is
# intentional when daily/weekly/monthly rotation reuses key prefixes.
resource "aws_s3_bucket_versioning" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id
  versioning_configuration {
    status = "Disabled"
  }
}

# Lifecycle: hard 180-day expiration on every object as a runaway-cost guard.
# Backup script's own retention logic (daily/weekly/monthly) decides which
# keys to keep within those 180 days. Longer than staging's 90 because
# production recovery windows are longer.
resource "aws_s3_bucket_lifecycle_configuration" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id
  rule {
    id     = "expire-after-180-days"
    status = "Enabled"
    filter {}
    expiration {
      days = 180
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ── IAM: App EC2 can write, delete, list the backup bucket ───────────────────
# Single-EC2 design means pg_dump runs on the same instance as everything
# else (vs staging's DB-EC2 pattern). Attaches to the existing
# `packiot-production-app` role from ec2.tf.

resource "aws_iam_policy" "app_backup_writer" {
  name = "packiot-production-app-backup-writer"
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

resource "aws_iam_role_policy_attachment" "app_backup_writer" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.app_backup_writer.arn
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "db_backup_bucket" {
  value       = aws_s3_bucket.db_backups.bucket
  description = "S3 bucket for nightly DB backups; used by backup-db.sh on the App EC2"
}
