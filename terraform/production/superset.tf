# ══════════════════════════════════════════════════════════════════════════════
# Dedicated persistent Apache Superset host (W2 embedded self-service BI)
# ══════════════════════════════════════════════════════════════════════════════
#
# WHY A DEDICATED BOX (not the app EC2):
# Superset is a memory-heavy multi-process app — gunicorn web (2 GB), a Celery
# worker (1 GB), a dedicated noeviction Redis (320 MB), plus a one-shot arm64
# image BUILD (docker/superset/Dockerfile FROM apache/superset:4.1.1). Co-locating
# it on the t4g.medium app box (which already runs the whole service plane) would
# blow its memory envelope — the same swap-death class the r7g DB split (W6) exists
# to avoid. So Superset gets its OWN t4g.large (8 GB) in the same public subnet.
#
# WHAT THIS FILE PROVISIONS (purely ADDITIVE — creates only NEW resources, touches
# nothing existing): IAM role + instance profile, a dedicated SG, an EIP, the
# t4g.large instance, an S3-hosted init script, the `bi.prod.packiot.app` A record,
# a disk alarm, and an AWS Backup selection. Mirrors the app/DB-box conventions in
# ec2.tf / database.tf so there is nothing new to learn operationally.
#
# EXPLICIT FOLLOW-UPS (NOT done here — each is a deliberate, separately-applied
# step, called out so this apply stays additive-only):
#   (1) DB-SG ingress — the Superset metadata DB connects UPSTREAM-DIRECT to the
#       r7g (compose.superset.yml: POSTGRES_HOST_UPSTREAM), so aws_security_group.db
#       must admit this box on 5432. That is an in-place EDIT of an existing SG, so
#       it is intentionally kept OUT of this file. Apply it deliberately at bring-up:
#         (in security_groups.tf, aws_security_group.db, add)
#           ingress {
#             description     = "PostgreSQL from Superset box (metadata + bi.* views)"
#             from_port       = 5432
#             to_port         = 5432
#             protocol        = "tcp"
#             security_groups = [aws_security_group.superset.id]
#           }
#   (2) prod SUPERSET_* secrets — compose.superset.yml needs SUPERSET_SECRET_KEY,
#       SUPERSET_GUEST_TOKEN_JWT_SECRET, SUPERSET_DB_PASSWORD, SUPERSET_GUESTTOKEN_
#       ADMIN_USER/_PASSWORD, SUPERSET_COGNITO_*, SUPERSET_OEE_DASHBOARD_UUID. Add
#       them to packiot/production/app; superset_init.sh reads them (jq // "" so a
#       missing key doesn't crash the boot — it just leaves Superset un-brought-up).
#   (3) the overlay files (compose.superset.yml, docker/superset/, configs/superset/)
#       land on the `production` branch (PR #780 is on the staging line today). Until
#       then superset_init.sh provisions the host + TLS + DNS and logs that the
#       compose bring-up is pending.
#   (4) CloudFront/WAF edge hardening — mirror edge.tf with a SECOND distribution
#       whose exact alias `bi.prod.packiot.app` fronts an `bi-origin.prod...` record
#       (AWS allows an exact CNAME on one dist to coexist with the `*.prod` wildcard
#       on another), then origin-lock the SG 443 to the CloudFront prefix list. Until
#       then bi is reachable directly over 443, gated by Superset's own Cognito SSO
#       + guest-token auth (NOT open without auth).
#
# Do NOT expose Superset to tenants until (2)+(3) land AND a live 2-tenant RLS
# re-verify passes ON THIS BOX (the staging isolation test already passed).

# ── Feature-local variables (kept here to minimise edits to variables.tf, same
#    convention as edge.tf) ──────────────────────────────────────────────────────

variable "superset_instance_type" {
  description = <<-EOT
    Dedicated Superset EC2 instance type. t4g.large = 2 vCPU / 8 GB (arm64,
    matches the AL2023 arm64 AMI). Superset web (2 GB) + worker (1 GB) + redis
    (320 MB) + the arm64 image build fit comfortably in 8 GB with 4 GB swap
    headroom. Bump to t4g.xlarge (16 GB) only if concurrent dashboard load or
    SQL-Lab async work pushes memory. t-family (burstable, unlimited credits) is
    fine here: BI load is bursty (interactive queries), unlike the DB's sustained
    cagg refresh — the opposite of why the DB is r7g.
  EOT
  type        = string
  default     = "t4g.large"
}

variable "superset_volume_size_gb" {
  description = "gp3 root volume: OS + Docker + the derived Superset image (~1.5 GB) + Redis AOF + logs. 40 GB leaves ample headroom (metadata lives on the r7g, not here)."
  type        = number
  default     = 40
}

variable "superset_subdomain" {
  description = "Left label of the Superset hostname (<superset_subdomain>.prod.packiot.app → Superset EIP). front4 embeds dashboards from here via edge-api-minted guest tokens."
  type        = string
  default     = "bi"
}

# ── IAM: Superset EC2 ──────────────────────────────────────────────────────────
# Same shape as the app role (ec2.tf): SSM for shell-less access, read production
# secrets, read the init script from S3, certbot DNS-01 via Route53, publish CW
# metrics. No backup-writer / no databaseCredentials — this box writes no backups
# and runs no mirror-worker.
resource "aws_iam_role" "superset" {
  name = "packiot-production-superset"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "superset_ssm" {
  role       = aws_iam_role.superset.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "superset_custom" {
  name = "packiot-production-superset-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadProductionSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = ["arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:packiot/production/*"]
      },
      {
        Sid      = "ReadInitScript"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${local.state_bucket}/scripts/production/*"
      },
      {
        Sid      = "ListInitScripts"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.state_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = ["scripts/production/*"] }
        }
      },
      {
        # Certbot DNS-01 for the wildcard *.prod.packiot.app cert (same mechanism
        # as the app box's nginx_setup.sh).
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
        Sid      = "PublishCloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "superset_custom" {
  role       = aws_iam_role.superset.name
  policy_arn = aws_iam_policy.superset_custom.arn
}

resource "aws_iam_instance_profile" "superset" {
  name = "packiot-production-superset"
  role = aws_iam_role.superset.name
}

# ── Security group ──────────────────────────────────────────────────────────────
# TIGHT by design: SSM-only management (NO SSH 22 ingress — mirrors the DB box, a
# stricter posture than the app box). 443 admits the world for now because bi is
# reached directly until the CloudFront/WAF edge (follow-up 4) fronts it — but the
# app itself is NOT open without auth: Superset's Cognito SSO gates interactive
# access and edge-api-minted guest tokens gate the embedded dashboards. 80 is only
# an HTTP→HTTPS redirect. Egress all so the box reaches the r7g (once follow-up 1
# admits it), Secrets Manager, S3, Docker Hub, Route53, Let's Encrypt.
resource "aws_security_group" "superset" {
  name   = "packiot-production-superset"
  vpc_id = aws_vpc.production.id

  ingress {
    description = "HTTP (redirected to HTTPS by nginx)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS - Superset UI + embedded dashboards (Cognito SSO + guest-token auth). Lock to CloudFront prefix list in edge-hardening follow-up."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound - r7g metadata DB (5432, once DB SG admits this box), Secrets Manager, S3, Docker Hub, Route53, ACME"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-production-superset-sg" }
}

# ── Init script (S3-hosted — same pattern as aws_s3_object.app_init) ────────────
# EC2 user_data has a 16 KB hard limit; the full init exceeds it, so the tiny
# inline bootstrap on the instance fetches this rendered object at first boot.
resource "aws_s3_object" "superset_init" {
  bucket = local.state_bucket
  key    = "scripts/production/superset_init.sh"
  content = templatefile("${path.module}/user_data/superset_init.sh", {
    aws_region         = var.aws_region
    production_domain  = var.production_domain
    github_repo        = var.github_repo
    state_bucket       = local.state_bucket
    superset_subdomain = var.superset_subdomain
    # r7g private IP — POSTGRES_HOST_UPSTREAM for the metadata DB + the bi.* views.
    # Sourced from the variable (default 10.20.10.89) rather than aws_instance.db to
    # keep this box's graph decoupled from the DB instance.
    db_private_ip = var.db_private_ip
  })
}

# ── EIP (stable public IP for the bi.prod.packiot.app A record) ─────────────────
resource "aws_eip" "superset" {
  domain = "vpc"
  tags   = { Name = "packiot-production-superset-eip" }
}

resource "aws_eip_association" "superset" {
  instance_id   = aws_instance.superset.id
  allocation_id = aws_eip.superset.id
}

# ── Superset EC2 ────────────────────────────────────────────────────────────────
# t4g.large in the public subnet with its own EIP + SG. On-demand with unlimited
# burst (BI queries are bursty). Root volume preserved on accidental termination.
resource "aws_instance" "superset" {
  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = var.superset_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.superset.id]
  iam_instance_profile        = aws_iam_instance_profile.superset.name
  key_name                    = data.aws_key_pair.ops.key_name
  associate_public_ip_address = false # using the static EIP below

  credit_specification {
    cpu_credits = "unlimited"
  }

  root_block_device {
    volume_size           = var.superset_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  # Tiny bootstrapper — mirrors app_bootstrap.sh: waits for the EIP/IMDS/S3, then
  # fetches + execs the rendered superset_init.sh from S3.
  user_data = base64encode(<<-BOOTSTRAP
    #!/bin/bash
    set -euo pipefail
    export PATH="/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/bin:$PATH"
    LOG=/var/log/packiot-bootstrap.log
    log() { echo "[superset-bootstrap $(date -u +%T)] $*" | tee -a "$LOG" >> /dev/console 2>/dev/null || true; }
    log "=== Superset bootstrap starting ==="
    until curl -sf --connect-timeout 5 https://aws.amazon.com/ > /dev/null 2>&1; do
      log "Waiting for internet (EIP association may still be in progress)..."; sleep 5
    done
    until aws s3 ls "s3://${local.state_bucket}/scripts/production/" --region ${var.aws_region} > /dev/null 2>&1; do
      log "Waiting for S3 IAM access..."; sleep 5
    done
    dnf install -y amazon-ssm-agent 2>&1 | tee -a "$LOG" || true
    systemctl enable --now amazon-ssm-agent 2>&1 | tee -a "$LOG" || true
    aws s3 cp "s3://${local.state_bucket}/scripts/production/superset_init.sh" /opt/packiot-superset-init.sh --region ${var.aws_region}
    chmod +x /opt/packiot-superset-init.sh
    log "Handing off to superset_init.sh"
    exec /opt/packiot-superset-init.sh
  BOOTSTRAP
  )

  tags = { Name = "packiot-production-superset" }

  depends_on = [aws_s3_object.superset_init]

  lifecycle {
    ignore_changes = [ami, user_data, associate_public_ip_address]
  }
}

# ── DNS: bi.prod.packiot.app → Superset EIP ─────────────────────────────────────
# A NEW record in the production child zone. Deliberately NOT added to var.services
# (that would re-render aws_s3_object.app_init / nginx_setup — an in-place change to
# existing resources). `bi` matches the CloudFront `*.prod.packiot.app` wildcard
# alias, but this A record points DIRECTLY at the box (CloudFront fronting is
# follow-up 4); a wildcard alias on the distribution does not create or conflict
# with a Route53 record.
resource "aws_route53_record" "superset_bi" {
  zone_id = aws_route53_zone.production.zone_id
  name    = "${var.superset_subdomain}.${var.production_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.superset.public_ip]
}

# ── Disk-fill alarm (mirror app/DB boxes) ───────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "superset_disk_used_percent" {
  alarm_name          = "packiot-production-superset-disk-used-percent"
  alarm_description   = "Production Superset EC2 root disk > 75% — investigate docker image/log churn before lockout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 75
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  treat_missing_data  = "notBreaching"
  dimensions = {
    InstanceId = aws_instance.superset.id
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

# ── AWS Backup selection (reuses the daily plan + role from snapshots.tf) ────────
# Targeted by Name tag so a replacement instance is picked up automatically.
resource "aws_backup_selection" "superset_ec2" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "packiot-production-superset-ec2"
  plan_id      = aws_backup_plan.ec2_daily.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Name"
    value = "packiot-production-superset"
  }
}

# ── Outputs ─────────────────────────────────────────────────────────────────────
output "superset_public_ip" {
  description = "Static EIP of the dedicated Superset EC2 (bi.prod.packiot.app A record target)."
  value       = aws_eip.superset.public_ip
}

output "ssm_connect_superset" {
  description = "Connect to the Superset EC2 via SSM (no SSH/bastion)."
  value       = "aws ssm start-session --target ${aws_instance.superset.id} --region ${var.aws_region}"
}

output "superset_url" {
  description = "Superset UI / embedded-dashboard origin."
  value       = "https://${var.superset_subdomain}.${var.production_domain}"
}
