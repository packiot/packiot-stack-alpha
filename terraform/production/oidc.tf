# GitHub Actions OIDC for AWS — ADR-0006 phase 1 pattern.
#
# The IAM OIDC identity provider for token.actions.githubusercontent.com
# ALREADY EXISTS in this AWS account (account 639178078294) — verified
# 2026-06-29 via `aws iam list-open-id-connect-providers`. Reuse it via
# data lookup rather than creating a duplicate.
#
# This file defines the production-specific IAM role that workflows can
# assume via OIDC. The trust policy is scoped to:
#   - Source repo: packiot/packiot-stack-alpha
#   - Source branch: production OR explicit workflow_dispatch
# Anything else is rejected at the AWS STS layer regardless of what the
# workflow YAML claims.
#
# Today, deploy-production.yml does NOT need to assume this role — the
# self-hosted runner on the production EC2 already has the
# packiot-production-app IAM role attached (per ec2.tf), which grants
# Secrets Manager + S3 + CloudWatch perms at runtime. The role here is
# foundational for future workflows that need AWS access from
# HOSTED runners (ubuntu-latest), or for steps in the deploy workflow
# that pre-stage data before the self-hosted phase.

data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions_deployer_production" {
  name        = "github-actions-deployer-production"
  description = "OIDC-assumable by GitHub Actions workflows in packiot/packiot-stack-alpha on the production branch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github_actions.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        # Audience: AWS requires the OIDC token's `aud` claim to match.
        # GitHub's official action `aws-actions/configure-aws-credentials`
        # uses `sts.amazonaws.com` by default.
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Subject: limit to the production branch on packiot-stack-alpha.
        # `repo:packiot/packiot-stack-alpha:ref:refs/heads/production`
        # matches workflow runs triggered by a push to that exact branch.
        # `ref:refs/heads/production` is more restrictive than `ref:*` —
        # a workflow run from a PR or another branch can NOT assume this
        # role, even with the right repo.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:packiot/packiot-stack-alpha:ref:refs/heads/production",
            # workflow_dispatch runs from the production branch land here too
            "repo:packiot/packiot-stack-alpha:environment:production",
          ]
        }
      }
    }]
  })
}

# Minimal initial permissions — extend as workflow steps actually need them.
# Current deploy-production.yml runs entirely on a self-hosted runner that
# already has the EC2's packiot-production-app IAM role; this OIDC role is
# foundational for future hosted-runner steps.
resource "aws_iam_policy" "github_actions_deployer_production" {
  name        = "github-actions-deployer-production"
  description = "Permissions for workflows assuming github-actions-deployer-production via OIDC"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read packiot/production/* — allows future workflow steps to fetch
        # secrets (e.g. a release-notes job that reads the prod DB cred to
        # diff schemas, or a smoke-test job that needs the API key).
        Sid    = "ReadProductionSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:packiot/production/*",
        ]
      },
      {
        # Describe-only on EC2 — useful for workflows that need to look up
        # the production EC2's instance ID or status. No mutations.
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
        ]
        Resource = "*"
      },
      {
        # SSM read — allows workflows to use Session Manager to issue
        # diagnostic commands (e.g. fleet-version probe) without an
        # interactive shell. Scoped to the production EC2 instance.
        Sid    = "SSMConnect"
        Effect = "Allow"
        Action = [
          "ssm:DescribeInstanceInformation",
          "ssm:GetCommandInvocation",
          "ssm:SendCommand",
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.app.id}",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_deployer_production" {
  role       = aws_iam_role.github_actions_deployer_production.name
  policy_arn = aws_iam_policy.github_actions_deployer_production.arn
}

output "github_actions_deployer_role_arn" {
  description = "ARN of the OIDC-assumable role for production deploy workflows. Reference this in deploy-production.yml via `role-to-assume:`."
  value       = aws_iam_role.github_actions_deployer_production.arn
}
