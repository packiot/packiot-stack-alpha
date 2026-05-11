# Bootstrap — run ONCE with local backend to create the S3 + DynamoDB state backend.
# After applying, initialise the staging config with the remote backend.
#
#   cd terraform/staging/bootstrap
#   terraform init && terraform apply
#   cd ..
#   terraform init          ← will prompt to migrate local state — say yes

terraform {
  required_version = ">= 1.6"
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

# Bucket name is account-scoped so it is globally unique without a random suffix.
resource "aws_s3_bucket" "state" {
  bucket        = "packiot-terraform-state-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
}

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

# DynamoDB for state locking — PAY_PER_REQUEST so idle cost is $0.
resource "aws_dynamodb_table" "lock" {
  name         = "packiot-terraform-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}
