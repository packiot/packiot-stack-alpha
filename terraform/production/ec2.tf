# Production single-EC2 architecture — much simpler than staging because:
#   - No DB EC2 (the local TimescaleDB lives as a Docker container on app EC2)
#   - No mirror-worker (production has no upstream to mirror from)
#   - No mirror-worker → no `databaseCredentials` IAM ARN
#
# The state bucket is shared with staging (same AWS account, different key
# under `production/terraform.tfstate`).
locals {
  state_bucket = "packiot-terraform-state-${data.aws_caller_identity.current.account_id}"
}

# Upload the rendered init script to S3 — EC2 user_data has a 16 KB hard limit
# and the templated app_init.sh exceeds it. The bootstrap script in user_data
# fetches this object at first boot.
resource "aws_s3_object" "app_init" {
  bucket = local.state_bucket
  key    = "scripts/production/app_init.sh"
  content = templatefile("${path.module}/user_data/app_init.sh", {
    db_name = var.db_name
    db_user = var.db_user
    # Upstream DB host: the dedicated r7g EC2's private IP. pgbouncer (and the
    # direct-connect DDL/authentik/adminer services) point at this in .env via
    # POSTGRES_HOST_UPSTREAM. Sourced from the resource attribute (single source
    # of truth) — this makes aws_s3_object.app_init depend on aws_instance.db, so
    # the app box's init script always carries the live DB IP (and the app box
    # boots after the DB EC2 exists). No cycle: the DB EC2 depends on neither.
    db_private_ip     = aws_instance.db.private_ip
    production_domain = var.production_domain
    aws_region        = var.aws_region
    github_repo       = var.github_repo
    state_bucket      = local.state_bucket
  })
}

# nginx_setup.sh stays a separate object so it can be re-run standalone for
# cert renewal or Nginx repairs on a live EC2.
resource "aws_s3_object" "nginx_setup" {
  bucket = local.state_bucket
  key    = "scripts/production/nginx_setup.sh"
  content = templatefile("${path.module}/user_data/nginx_setup.sh", {
    production_domain = var.production_domain
    services          = var.services
    service_auth      = var.service_auth
    aws_region        = var.aws_region
  })
}

# Amazon Linux 2023 ARM64 — official AWS AMI, updated regularly.
# Graviton2 (arm64) is required to use t4g instances.
data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── IAM: App EC2 ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "app" {
  name = "packiot-production-app"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# SSM Session Manager — no SSH bastion needed, IAM controls access.
resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Agent permissions are bundled into the custom policy below
# instead of the AWS managed CloudWatchAgentServerPolicy — we only need
# PutMetricData (the agent doesn't talk to SSM Parameter Store in this setup).
resource "aws_iam_policy" "app_custom" {
  name = "packiot-production-app-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadProductionSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:packiot/production/*",
        ]
        # NOTE: staging's policy includes `databaseCredentials-??????` to give
        # the mirror-worker SELECT-only access to the real prod DB. Production
        # does NOT need this — no mirror-worker runs here. Explicitly absent.
      },
      {
        Sid      = "ReadInitScript"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${local.state_bucket}/scripts/production/*"
      },
      {
        # s3:ListBucket is bucket-level (not object-level) — separate ARN required.
        # bootstrap.sh uses `aws s3 ls s3://bucket/scripts/production/` to wait
        # for S3 access.
        Sid      = "ListInitScripts"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.state_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = ["scripts/production/*"] }
        }
      },
      {
        # Certbot DNS-01 challenge: create TXT record in Route53, wait for
        # propagation, then Let's Encrypt verifies domain ownership.
        Sid    = "CertbotDnsChallenge"
        Effect = "Allow"
        Action = [
          "route53:GetChange",
          "route53:ChangeResourceRecordSets",
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
        ]
        Resource = "*"
      },
      {
        # CloudWatch Agent publishes node-level disk + memory metrics under the
        # CWAgent namespace. PutMetricData is the write path.
        Sid      = "PublishCloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "app_custom" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.app_custom.arn
}

resource "aws_iam_instance_profile" "app" {
  name = "packiot-production-app"
  role = aws_iam_role.app.name
}

# Disk-fill alarm at 75% on the production EC2 root volume.
# Threshold matches staging — surfaces drift well before lockout.
resource "aws_cloudwatch_metric_alarm" "app_disk_used_percent" {
  alarm_name          = "packiot-production-app-disk-used-percent"
  alarm_description   = "Production app EC2 root disk > 75% — investigate docker / log churn before it fills (see ebs-rescue-mount-stuck-ec2 zettel for recovery)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 75
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  treat_missing_data  = "notBreaching"
  dimensions = {
    InstanceId = aws_instance.app.id
    path       = "/"
    fstype     = "xfs"
    device     = "nvme0n1p1"
  }
  # alarm_actions intentionally empty — alarm becomes observable via console
  # and Grafana CloudWatch datasource immediately. Wire SNS later without
  # recreating.
  tags = {
    Project     = "packiot-stack-alpha"
    Environment = "production"
    Owner       = "ops"
  }
}

# ── SSH Key Pair ──────────────────────────────────────────────────────────────
# REUSES staging's `packiot-staging-ops` key via data lookup — the public
# key (var.ops_ssh_public_key) is identical to staging's, so creating a
# second AWS-level aws_key_pair record would just duplicate the same bytes
# under a different name. Saves one resource; semantically unchanged.
#
# Trade-off: staging + production share the SSH credential today. If/when
# production carries real customer data (phase 3), split to a production-
# dedicated key:
#   1. Generate new keypair on the operator's machine
#   2. Replace this `data` block with a `resource "aws_key_pair" "ops" {
#      key_name = "packiot-production-ops"
#      public_key = "<new key>" }`
#   3. terraform apply (instance NOT replaced — aws_key_pair updates don't
#      trigger EC2 replacement; only new SSH sessions use the new key)
#
# The var.ops_ssh_public_key is no longer referenced after this change.
# Left in variables.tf for documentation and easy re-introduction.
data "aws_key_pair" "ops" {
  key_name = "packiot-staging-ops"
}

# ── App EC2 ───────────────────────────────────────────────────────────────────
# Single instance carrying the entire production stack:
#   - All Docker services (pgbouncer, hasura, edge-api, oeecloud-worker,
#     operator, grafana, loki, prometheus, promtail, authentik, adminer,
#     nginx)
#   - The local empty TimescaleDB container (the dry-run boot DB)
#   - The self-hosted GitHub Actions runner
#
# On-demand (NOT spot) because the postgres container is on this same node;
# a spot interruption mid-write could corrupt WAL. Trade-off accepted for
# dry-run; phase-3 (write cutover) will split out the DB to its own
# instance and the App EC2 can move to spot/ASG.

resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = var.app_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  key_name                    = data.aws_key_pair.ops.key_name
  associate_public_ip_address = false # using static EIP (see vpc.tf)

  # T4G unlimited burst — production prioritises availability over surprise
  # cost; the alternative (`standard`) throttles to baseline CPU after credits
  # exhaust, which would degrade observability + edge-api during incidents.
  credit_specification {
    cpu_credits = "unlimited"
  }

  root_block_device {
    volume_size           = var.app_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false # preserve data on accidental termination
  }

  # Tiny bootstrapper only — fetches the real init script from S3 at runtime.
  # app_init.sh is uploaded as aws_s3_object.app_init (rendered with all vars).
  user_data = base64encode(templatefile("${path.module}/user_data/app_bootstrap.sh", {
    state_bucket = local.state_bucket
    aws_region   = var.aws_region
  }))

  tags = { Name = "packiot-production-app" }

  # Both S3 objects must exist before the instance boots and app_init.sh runs.
  depends_on = [aws_s3_object.app_init, aws_s3_object.nginx_setup]

  lifecycle {
    # associate_public_ip_address drifts when EIP is re-associated after
    # replacement; the EIP handles static public IP so the instance attribute
    # doesn't matter.
    ignore_changes = [ami, user_data, associate_public_ip_address]
  }
}
