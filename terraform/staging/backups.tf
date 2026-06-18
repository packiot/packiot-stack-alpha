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

# Versioning off — backups are immutable named objects; overwriting is intentional
# when daily/weekly/monthly rotation reuses key prefixes.
resource "aws_s3_bucket_versioning" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id
  versioning_configuration {
    status = "Disabled"
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

# ── Outputs ───────────────────────────────────────────────────────────────────
output "db_backup_bucket" {
  value       = aws_s3_bucket.db_backups.bucket
  description = "S3 bucket for nightly DB backups; used by backup-db.sh on the DB EC2"
}
