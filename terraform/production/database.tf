# ── Dedicated DB EC2 (W6 — right-sized, split off the app box) ────────────────
#
# WHY THIS EXISTS (production-buildout-roadmap.md §W6, risk R2):
# The app box is a t4g.medium (4 GB) running a *local* TimescaleDB container.
# TimescaleDB's continuous-aggregate refresh is memory-hungry and SUSTAINED, not
# bursty — burst-credit instances are the wrong model. Staging already swap-died
# on this exact class and needed a max_bg_workers bump + restart. Under a real
# client (edge-transformer + refdata + mosquitto + observability all on the same
# box) the app-local DB would swap and die. W6 moves the DB onto its own
# MEMORY-family (r7g) instance in the private subnet.
#
# SINGLE-FLOW F3-NATIVE (ADR-0032, roadmap §3.1): this is ONE database whose
# `public` schema *is* the F3 schema. No packiot_analytics suffix (nothing to
# disambiguate with a single flow), no F1 legacy `public`, no F2 shadow_go_port,
# no comparator schemas. Greenfield prod is *born* at ADR-0032's end-state.
#
# SCOPE (config/plan-only): this terraform provisions the right-sized instance
# running an empty TimescaleDB. Assembling the F3 schema as `public` (roadmap
# W1.4, "highest-care") and repointing the compose DATABASE_URL/pgbouncer from
# the app-local container to db_private_ip (W1 compose-parity) are deliberate
# follow-ups — NOT done here. Nothing is applied.

# ── IAM: DB EC2 ───────────────────────────────────────────────────────────────
resource "aws_iam_role" "db" {
  name = "packiot-production-db"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# SSM Session Manager — the DB has no public IP and no SSH ingress, so SSM is
# the only in-band access path (matches staging's DB EC2).
resource "aws_iam_role_policy_attachment" "db_ssm" {
  role       = aws_iam_role.db.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read ONLY the DB secret (name/user/password) so the bootstrap can start the
# TimescaleDB container with the managed superuser password. Scoped to the
# db secret prefix — not the whole packiot/production/* set the app role reads.
resource "aws_iam_policy" "db_secrets" {
  name = "packiot-production-db-secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadDbSecret"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:packiot/production/db*",
        ]
      },
      {
        # CloudWatch Agent publishes DB-node disk + memory metrics (memory is the
        # metric that matters most for the swap-guard this instance exists to fix).
        Sid      = "PublishCloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "db_secrets" {
  role       = aws_iam_role.db.name
  policy_arn = aws_iam_policy.db_secrets.arn
}

resource "aws_iam_instance_profile" "db" {
  name = "packiot-production-db"
  role = aws_iam_role.db.name
}

# ── DB EC2 ────────────────────────────────────────────────────────────────────
# r7g (Graviton3, arm64 — uses the same AL2023 arm64 AMI as the app box).
# On-demand, NEVER spot: a spot interruption mid-write can corrupt PostgreSQL
# WAL. gp3 with provisioned IOPS + throughput above the free baseline (WAL +
# cagg refresh are write-heavy). No public IP; egress via the NAT instance.
resource "aws_instance" "db" {
  ami                    = data.aws_ami.al2023_arm64.id
  instance_type          = var.db_instance_type
  subnet_id              = aws_subnet.private.id
  private_ip             = var.db_private_ip
  vpc_security_group_ids = [aws_security_group.db.id]
  iam_instance_profile   = aws_iam_instance_profile.db.name
  key_name               = data.aws_key_pair.ops.key_name

  # NO credit_specification block: r7g is a fixed-performance (non-burstable)
  # family with no CPU-credit concept — AWS rejects credit_specification on it
  # (unlike staging's t4g DB). Fixed performance is exactly why this family was
  # chosen: TimescaleDB cagg refresh is a SUSTAINED load, not a burst.
  # On-demand (never spot) — a spot interruption mid-write can corrupt WAL.

  root_block_device {
    volume_size           = var.db_volume_size_gb
    volume_type           = "gp3"
    iops                  = var.db_iops
    throughput            = var.db_throughput_mbps
    encrypted             = true
    delete_on_termination = false # preserve the F3 data dir on accidental termination
  }

  # Minimal, honest bootstrap: install Docker + start an EMPTY TimescaleDB
  # (same image pin the roadmap records) with a persistent data dir and the
  # managed superuser password pulled from Secrets Manager. The F3 schema is
  # NOT assembled here — that is roadmap W1.4 (assemble the F3 schema DDL as
  # `public`), applied by the deploy/migrate pipeline once compose repoints at
  # this box. This keeps the terraform self-contained + `validate`-clean without
  # inlining the schema build.
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    set -euo pipefail
    dnf install -y docker jq awscli
    systemctl enable --now docker
    mkdir -p /opt/packiot/pgdata
    DB_PASS=$(aws secretsmanager get-secret-value \
      --secret-id packiot/production/db --region ${var.aws_region} \
      --query SecretString --output text | jq -r .password)
    docker run -d --name timescaledb --restart unless-stopped \
      -p ${var.db_private_ip}:5432:5432 \
      -e POSTGRES_DB=${var.db_name} \
      -e POSTGRES_USER=${var.db_user} \
      -e POSTGRES_PASSWORD="$DB_PASS" \
      -v /opt/packiot/pgdata:/var/lib/postgresql/data \
      timescale/timescaledb:2.25.2-pg16
  USERDATA
  )

  tags = { Name = "packiot-production-db" }

  lifecycle {
    # Don't replace the instance (and its WAL) on AMI refresh or user_data
    # churn — control DB replacement timing manually (matches staging).
    ignore_changes = [ami, user_data]
  }
}

# ── Disk-fill alarm on the DB volume ──────────────────────────────────────────
# Same 75% threshold + CWAgent namespace as the app box (ec2.tf). The DB box is
# the one whose disk fills first once real client data flows.
resource "aws_cloudwatch_metric_alarm" "db_disk_used_percent" {
  alarm_name          = "packiot-production-db-disk-used-percent"
  alarm_description   = "Production DB EC2 root disk > 75% — investigate TimescaleDB data/WAL growth before lockout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 75
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  treat_missing_data  = "notBreaching"
  dimensions = {
    InstanceId = aws_instance.db.id
    path       = "/"
    fstype     = "xfs"
    device     = "nvme0n1p1"
  }
  tags = {
    Project     = "packiot-stack-alpha"
    Environment = "production"
    Owner       = "ops"
  }
}

# ── AWS Backup selection for the DB EC2 (W6.4) ────────────────────────────────
# Reuses the daily plan + role from snapshots.tf. Targeted by Name tag so a
# replacement instance with the same tag is picked up automatically. This is the
# recovery-of-last-resort for the F3 data dir until a pg_dump/WAL-archive path
# lands (backups.tf S3 bucket already exists for that).
resource "aws_backup_selection" "db_ec2" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "packiot-production-db-ec2"
  plan_id      = aws_backup_plan.ec2_daily.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Name"
    value = "packiot-production-db"
  }
}
