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
  }

  # Backend values supplied at init time via `make tf-init` (production-specific
  # target) — not hardcoded here. Production workspace state lives in the
  # SAME S3 bucket as staging (packiot-terraform-state-639178078294) but
  # under a different key (`production/terraform.tfstate` vs
  # `staging/terraform.tfstate`). use_lockfile=true → S3 native locking.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "packiot"
      Environment = "production"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
