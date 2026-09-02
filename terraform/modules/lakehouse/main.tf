# ADR-0041 — offline lakehouse (S3 + Glue + Athena). SCAFFOLD MODULE — NOT WIRED TO ANY ROOT.
# Merging this provisions nothing (no root references `../modules/lakehouse`). See README.md.
# Decision: docs/adr/0041-gcp-exit-lakehouse.md · Build plan: docs/adr/reference/designs/0041-lakehouse-build-plan.md

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  bucket_name    = "packiot-lake-${var.env}"
  workgroup_name = "packiot-lake-${var.env}"
}

# ── S3: the object-storage lake (bronze/silver/gold parquet) ──────────────────
resource "aws_s3_bucket" "lake" {
  bucket = local.bucket_name
  tags   = { ADR = "0041", Tier = "offline-lakehouse" }
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule { object_ownership = "BucketOwnerEnforced" } # ACLs disabled
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" } # SSE-S3; swap to aws:kms + CMK if needed (design §8 Q3)
  }
}

resource "aws_s3_bucket_versioning" "lake" {
  bucket = aws_s3_bucket.lake.id
  versioning_configuration { status = "Enabled" } # idempotent partition overwrite is auditable/reversible (design §4.4)
}

resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    id     = "expire-athena-results"
    status = "Enabled"
    filter { prefix = "athena-results/" }
    expiration { days = var.athena_results_expiry_days }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = var.noncurrent_version_expiry_days }
  }
}

# ── Glue Data Catalog databases (tables created via Athena DDL — build plan §3) ──
resource "aws_glue_catalog_database" "bronze" {
  name        = "bronze"
  description = "ADR-0041 lakehouse — immutable raw tier (equipment_*_raw export)"
}

resource "aws_glue_catalog_database" "gold" {
  name        = "gold"
  description = "ADR-0041 lakehouse — reporting rollups (equipment_runtime_*, cq_logs)"
}

# ── Athena workgroup — engine v3, cost guardrails (build plan §5) ──────────────
resource "aws_athena_workgroup" "lake" {
  name = local.workgroup_name

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.bytes_scanned_cutoff_per_query # hard stop vs runaway full-scan

    engine_version {
      selected_engine_version = "Athena engine version 3" # Trino
    }

    result_configuration {
      output_location = "s3://${aws_s3_bucket.lake.bucket}/athena-results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = { ADR = "0041", Tier = "offline-lakehouse" }
}
