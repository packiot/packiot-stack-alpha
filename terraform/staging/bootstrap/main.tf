# Bootstrap — run ONCE via `make tf-bootstrap` to create the S3 state bucket.
# S3 native locking (Terraform >= 1.10) replaces DynamoDB — no extra resources needed.
#
# After running bootstrap, use `make tf-init` to configure the remote backend.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project   = "packiot"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# Bucket name is account-scoped — globally unique without a random suffix.
resource "aws_s3_bucket" "state" {
  bucket        = "packiot-terraform-state-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
}

# Versioning is required for S3 native locking (uses conditional writes on the lock file).
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
