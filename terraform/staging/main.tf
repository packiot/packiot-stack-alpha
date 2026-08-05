terraform {
  required_version = ">= 1.10" # S3 native locking requires 1.10+

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Backend values supplied at init time via `make tf-init` — not hardcoded here.
  # use_lockfile=true enables S3 native locking (no DynamoDB needed).
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "packiot"
      Environment = "staging"
      ManagedBy   = "terraform"
    }
  }
}

# us-east-1-pinned provider for the edge layer (edge.tf). CloudFront viewer ACM
# certs and WAFv2 web ACLs with scope=CLOUDFRONT MUST be created in us-east-1.
# The root provider already defaults there (var.aws_region), but pinning an
# explicit alias keeps the edge resources correct even if aws_region is changed.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "packiot"
      Environment = "staging"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
