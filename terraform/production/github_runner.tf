# ─────────────────────────────────────────────────────────────────────────────
# Self-hosted GitHub Actions runner (task #57)
#
# WHY: every workflow across the packiot org runs on `ubuntu-latest`. The org is
# on the GitHub Free plan and hits the Actions minutes/billing cap → jobs die in
# ~2s with "no runner assigned" and no logs, so CI AND the deploy pipelines are
# ALL dead. This is a persistent, org-level, arm64 self-hosted runner that
# escapes that cap and restores CI + deploys.
#
# ARCH: arm64 (t4g/Graviton) — matches the stack (app/db/superset all Graviton),
# so the Docker images it builds are the arm64 images prod actually runs.
#
# SECURITY POSTURE (first cut, private org, trusted contributors):
#   • Runner runs as a non-root `runner` user; box managed via SSM (no SSH, no
#     inbound SG rules).
#   • The box's OWN IAM is minimal (SSM only). AWS deploy creds continue to come
#     per-workflow via the existing OIDC deployer role (oidc.tf) — the runner box
#     is NOT a standing set of AWS deploy keys.
#   • PAT (admin:org) lives in Secrets Manager, populated out-of-band, read only
#     at boot to mint a short-lived registration token.
#   Hardening follow-ups (noted, not blocking): ephemeral per-job runners; GitHub
#   org setting "require approval for outside collaborators"; least-priv refinement.
# ─────────────────────────────────────────────────────────────────────────────

variable "runner_instance_type" {
  description = "Instance type for the self-hosted CI runner (arm64/Graviton)."
  type        = string
  default     = "t4g.medium" # 2 vCPU / 4 GB — headroom for Docker + Go/Node builds
}

variable "runner_version" {
  description = "GitHub Actions runner release to install (arm64 tarball)."
  type        = string
  default     = "2.336.0"
}

variable "runner_root_volume_gb" {
  description = "Root gp3 volume — Docker layer cache + build workspaces."
  type        = number
  default     = 50
}

locals {
  github_org    = "packiot"
  runner_labels = "self-hosted,linux,arm64,packiot-prod"
}

# ── PAT secret: created empty, populated out-of-band (never in git/terraform) ──
# Populate with:  aws secretsmanager put-secret-value --secret-id github-runner-pat \
#                   --secret-string '{"pat":"<PAT with admin:org / manage_runners>"}'
resource "aws_secretsmanager_secret" "runner_pat" {
  name        = "github-runner-pat"
  description = "GitHub PAT (admin:org) the runner uses at boot to mint a registration token. Set out-of-band."
}

resource "aws_secretsmanager_secret_version" "runner_pat" {
  secret_id     = aws_secretsmanager_secret.runner_pat.id
  secret_string = jsonencode({ pat = "REPLACE_ME_OUT_OF_BAND" })
  lifecycle { ignore_changes = [secret_string] }
}

# ── IAM: minimal — SSM management + read only its own PAT secret ──────────────
resource "aws_iam_role" "runner" {
  name = "packiot-production-github-runner"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "runner_ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "runner_pat_read" {
  name = "packiot-production-github-runner-pat-read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.runner_pat.arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "runner_pat_read" {
  role       = aws_iam_role.runner.name
  policy_arn = aws_iam_policy.runner_pat_read.arn
}

resource "aws_iam_instance_profile" "runner" {
  name = "packiot-production-github-runner"
  role = aws_iam_role.runner.name
}

# ── Egress-only SG (no inbound; managed via SSM) ─────────────────────────────
resource "aws_security_group" "runner" {
  name        = "packiot-production-github-runner"
  description = "Self-hosted CI runner — egress only (GitHub, package mirrors, AWS)."
  vpc_id      = aws_vpc.production.id

  egress {
    description = "All outbound (GitHub, dnf, AWS, ECR)."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-production-github-runner" }
}

# ── The runner instance ──────────────────────────────────────────────────────
resource "aws_instance" "runner" {
  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = var.runner_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.runner.id]
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.runner_root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  user_data = base64encode(templatefile("${path.module}/user_data/runner_init.sh", {
    github_org           = local.github_org
    runner_pat_secret_id = aws_secretsmanager_secret.runner_pat.name
    aws_region           = var.aws_region
    runner_version       = var.runner_version
    runner_labels        = local.runner_labels
  }))

  # user_data re-runs only on replacement; ignore so a version bump doesn't force
  # a rebuild out from under a live runner (bump deliberately via taint).
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "packiot-production-github-runner" }
}

output "github_runner_instance_id" {
  description = "Instance ID of the self-hosted CI runner (SSM target for management)."
  value       = aws_instance.runner.id
}
