# ── Dedicated org-level self-hosted GitHub Actions CI runner ──────────────────
#
# WHY THIS EXISTS:
# The packiot GitHub org is on the Free plan, whose 2,000 Actions-minutes/month
# pool is shared across ALL private repos. When it's exhausted, CI HALTS
# ORG-WIDE (queued jobs never start) until the next billing cycle. A self-hosted
# runner has UNLIMITED free minutes — GitHub only meters GitHub-hosted runners.
#
# This box is a DEDICATED, SEPARATE instance from the prod app EC2 (ec2.tf) and
# the prod DB EC2 (database.tf). It runs NO OEE workload, holds NO customer
# data, and is intentionally isolated so a compromised/runaway CI job cannot
# reach the production plane:
#   - Its OWN security group with NO inbound rules at all (access is SSM-only,
#     which is pure egress — the SSM agent dials out to AWS, nothing dials in).
#   - Its OWN IAM role that can read EXACTLY ONE secret (the CI-runner PAT) and
#     talk to SSM — nothing else. It CANNOT read packiot/production/* app secrets.
#   - Its OWN public subnet (below) so it never shares the prod app/db subnets.
#     Egress-restricted SG (443/80/DNS/NTP only), no wide-open egress.
#
# FIRST CONSUMER: front4 CI (private repo, no external contributors → running
# untrusted forked-PR code is not a risk here; see the runbook's security note
# on why self-hosted runners on PUBLIC repos are dangerous).
#
# SCOPE (scaffold + plan-only): nothing is applied and no runner is registered
# by this commit. See docs/ci-selfhosted-runner-runbook.md for the ordered
# bring-up (create PAT → store in Secrets Manager → terraform apply → verify
# "Idle" in the org runners page → flip front4's runs-on).

# ── x86_64 AMI ────────────────────────────────────────────────────────────────
# NOTE: unlike the prod app/db boxes (Graviton arm64), the CI runner is x86_64.
# front4's build (Vite + node-gyp native deps) and most third-party GitHub
# Actions publish x64 binaries first; x64 avoids arm64 toolchain surprises in
# CI. The runner labels advertise `x64` so workflows target the right arch.
data "aws_ami" "al2023_x86_64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Dedicated subnet (isolated from the prod app/db subnets) ───────────────────
# Public subnet with auto-assigned public IP → egress straight out the existing
# IGW (aws_route_table.public in vpc.tf). Deliberately NOT routed through the
# prod NAT instance: CI pulls GBs (npm, Docker layers, the runner tarball) and
# must not saturate the tiny t4g.nano NAT that the prod DB depends on for its
# egress. Inbound is fully closed by the SG below, so the public IP is
# unreachable — the security posture matches a private box for inbound, while
# keeping CI throughput off the prod egress path and giving SSM a direct route.
resource "aws_subnet" "ci_runner" {
  vpc_id                  = aws_vpc.production.id
  cidr_block              = var.ci_runner_subnet_cidr
  availability_zone       = var.az
  map_public_ip_on_launch = true
  tags                    = { Name = "packiot-ci-runner" }
}

resource "aws_route_table_association" "ci_runner" {
  subnet_id      = aws_subnet.ci_runner.id
  route_table_id = aws_route_table.public.id # IGW egress (vpc.tf)
}

# ── Security group: NO inbound, egress-restricted ─────────────────────────────
# No ingress block at all → zero inbound (SSM needs none; the agent dials out).
# Egress is scoped to what a runner actually needs, NOT the wide-open `-1` the
# app/db boxes use:
#   - 443: GitHub API/registration, code checkout, ghcr.io/Docker Hub pulls,
#          npm registry, dnf (AL2023 https mirrors), SSM/EC2messages/Secrets Mgr.
#   - 80:  package-mirror redirects + a few registries that still 302 over http.
#   - 53 (udp+tcp): DNS — without this the box can't resolve anything, including
#          the SSM endpoints. The VPC resolver lives at VPC-base+2; a restrictive
#          egress SG must explicitly permit 53 or the whole box is deaf.
#   - 123 (udp): NTP — a skewed clock breaks TLS handshakes (cert notBefore/After
#          and the runner's token exchange), a classic self-hosted-runner failure.
resource "aws_security_group" "ci_runner" {
  name        = "packiot-ci-runner"
  description = "Self-hosted CI runner: no inbound (SSM-only access), egress restricted to 443/80/DNS/NTP"
  vpc_id      = aws_vpc.production.id

  # (intentionally NO ingress blocks — access is via SSM Session Manager only)

  egress {
    description = "HTTPS — GitHub, ghcr/Docker Hub, npm, dnf mirrors, SSM, Secrets Manager"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP — package-mirror redirects / registries that 302 over http"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS (UDP) — resolve GitHub/registry/SSM hostnames via the VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS (TCP) — large responses / fallback"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "NTP — clock sync (skewed clock breaks TLS + token exchange)"
    from_port   = 123
    to_port     = 123
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-ci-runner-sg" }
}

# ── Secrets Manager: org-registration PAT ─────────────────────────────────────
# Stores the GitHub PAT the bootstrap exchanges (at boot, and on every re-run of
# the helper) for a short-lived ORG registration token. The token itself is
# never stored — only the long-lived PAT, which the box reads once per (re-)reg.
#
# PLACEHOLDER value only — a real token is NEVER committed. `ignore_changes`
# means the manual `aws secretsmanager put-secret-value` (see runbook step 1)
# sticks and terraform won't revert it. The bootstrap fail-closes if it still
# reads the placeholder (see ci_runner_setup.sh).
#
# PAT SCOPE required (pick one):
#   - Fine-grained PAT: Organization permissions → "Self-hosted runners" =
#     Read and write  (this is the `manage_runners:org` capability).
#   - Classic PAT: `admin:org` scope.
# See the runbook for step-by-step PAT creation.
resource "aws_secretsmanager_secret" "ci_runner_github_pat" {
  name                    = "packiot/production/ci-runner-github-pat"
  recovery_window_in_days = 7
  description             = "GitHub org-scoped PAT for self-hosted CI runner registration (manage_runners:org / admin:org). Populate via put-secret-value — see docs/ci-selfhosted-runner-runbook.md."
}

resource "aws_secretsmanager_secret_version" "ci_runner_github_pat" {
  secret_id = aws_secretsmanager_secret.ci_runner_github_pat.id
  secret_string = jsonencode({
    # PLACEHOLDER — replace via `aws secretsmanager put-secret-value` (runbook §1).
    # The bootstrap exits non-zero if it reads this sentinel, so a box that boots
    # before the PAT is set stays up + SSM-reachable but does NOT register.
    pat = "REPLACE_ME_WITH_ORG_PAT"
    org = var.github_org
  })
  lifecycle { ignore_changes = [secret_string] }
}

# ── IAM: CI runner ────────────────────────────────────────────────────────────
resource "aws_iam_role" "ci_runner" {
  name = "packiot-ci-runner"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# SSM Session Manager — the ONLY access path (no SSH, no inbound). Same managed
# policy the app/db boxes use.
resource "aws_iam_role_policy_attachment" "ci_runner_ssm" {
  role       = aws_iam_role.ci_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read EXACTLY the one CI-runner PAT secret — nothing else. Deliberately NOT the
# packiot/production/* wildcard the app role has: a CI job must never be able to
# read the prod DB/Hasura/edge-api secrets. Least privilege is the whole point
# of giving this box its own role instead of reusing the app profile.
resource "aws_iam_policy" "ci_runner_secrets" {
  name = "packiot-ci-runner-secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadCiRunnerPatOnly"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        # The `-??????` suffix matches the 6-char random suffix Secrets Manager
        # appends to the ARN; without it GetSecretValue by full ARN is denied.
        Resource = [
          aws_secretsmanager_secret.ci_runner_github_pat.arn,
          "${aws_secretsmanager_secret.ci_runner_github_pat.arn}-??????",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ci_runner_secrets" {
  role       = aws_iam_role.ci_runner.name
  policy_arn = aws_iam_policy.ci_runner_secrets.arn
}

resource "aws_iam_instance_profile" "ci_runner" {
  name = "packiot-ci-runner"
  role = aws_iam_role.ci_runner.name
}

# ── CI runner EC2 ─────────────────────────────────────────────────────────────
# t3.medium (2 vCPU / 4 GB) minimum — a 2 GB box OOMs on the front4 Vite build.
# On-demand by default; spot is a cost lever documented in the runbook (a spot
# interruption only kills the in-flight CI job, which GitHub re-queues — no data
# at risk here, unlike the DB box).
resource "aws_instance" "ci_runner" {
  ami                         = data.aws_ami.al2023_x86_64.id
  instance_type               = var.ci_runner_instance_type
  subnet_id                   = aws_subnet.ci_runner.id
  vpc_security_group_ids      = [aws_security_group.ci_runner.id]
  iam_instance_profile        = aws_iam_instance_profile.ci_runner.name
  associate_public_ip_address = true # egress via IGW; inbound still fully closed by the SG

  # t3 is burstable — `unlimited` avoids CI builds throttling to baseline CPU
  # after credits exhaust (a long Vite/tsc build would otherwise crawl).
  credit_specification {
    cpu_credits = "unlimited"
  }

  root_block_device {
    volume_size           = var.ci_runner_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true # ephemeral CI box — nothing to preserve
  }

  # Full bootstrap rendered from the standalone setup script. Kept inline (not
  # via the app box's S3 indirection) because it's well under the 16 KB user_data
  # limit. `$${VAR}` in the script escapes shell vars from templatefile.
  user_data = base64encode(templatefile("${path.module}/user_data/ci_runner_setup.sh", {
    aws_region       = var.aws_region
    github_org       = var.github_org
    runner_version   = var.ci_runner_version
    runner_labels    = join(",", var.ci_runner_labels)
    runner_ephemeral = var.ci_runner_ephemeral ? "true" : "false"
    pat_secret_id    = aws_secretsmanager_secret.ci_runner_github_pat.name
  }))

  tags = { Name = "packiot-ci-runner" }

  # The PAT secret must exist before the box boots and reads it.
  depends_on = [aws_secretsmanager_secret_version.ci_runner_github_pat]

  lifecycle {
    # Don't replace the box on AMI refresh or user_data churn — re-registering a
    # runner is a manual, controlled action (SSM in + run the helper), not an
    # instance replacement.
    ignore_changes = [ami, user_data, associate_public_ip_address]
  }
}
