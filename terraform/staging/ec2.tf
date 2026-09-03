# The state bucket is created by the bootstrap module; reference it by the
# deterministic name rather than adding a cross-module dependency.
locals {
  state_bucket = "packiot-terraform-state-${data.aws_caller_identity.current.account_id}"
}

# Upload the rendered init script to S3 — EC2 user_data has a hard 16 KB limit
# and the full script exceeds it. The App EC2 user_data fetches this via aws s3 cp.
resource "aws_s3_object" "app_init" {
  bucket = local.state_bucket
  key    = "scripts/app_init.sh"
  content = templatefile("${path.module}/user_data/app_init.sh", {
    db_private_ip  = aws_instance.db.private_ip
    db_name        = var.db_name
    db_user        = var.db_user
    staging_domain = var.staging_domain
    aws_region     = var.aws_region
    github_repo    = var.github_repo
    state_bucket   = local.state_bucket
  })
}

# nginx_setup.sh is kept as a separate S3 object so it can also be run
# standalone for cert renewal or Nginx repairs on a live EC2.
resource "aws_s3_object" "nginx_setup" {
  bucket = local.state_bucket
  key    = "scripts/nginx_setup.sh"
  content = templatefile("${path.module}/user_data/nginx_setup.sh", {
    staging_domain = var.staging_domain
    services       = var.services
    service_auth   = var.service_auth
    aws_region     = var.aws_region
  })
}

# db_init.sh outgrew the AWS user_data 16 KB hard limit (the templated script
# exceeds 12 KB raw → ~17 KB base64). Mirror the app pattern: tiny bootstrap
# in user_data, full script fetched from S3 at first boot. The DB EC2's
# `lifecycle.ignore_changes = [user_data]` block already prevents Terraform
# from replacing the running instance when this rendering changes.
resource "aws_s3_object" "db_init" {
  bucket = local.state_bucket
  key    = "scripts/db_init.sh"
  content = templatefile("${path.module}/user_data/db_init.sh", {
    db_name     = var.db_name
    db_user     = var.db_user
    aws_region  = var.aws_region
    github_repo = var.github_repo
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

# ── IAM: DB EC2 ───────────────────────────────────────────────────────────────

resource "aws_iam_role" "db" {
  name = "packiot-staging-db"
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
resource "aws_iam_role_policy_attachment" "db_ssm" {
  role       = aws_iam_role.db.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "db_secrets" {
  name = "packiot-staging-db-secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadStagingSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:packiot/staging/db*",
          # github-pat is needed by db_init.sh to clone the repo and build the postgres image locally.
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:packiot/staging/github-pat*",
        ]
      },
      {
        # db_bootstrap.sh fetches db_init.sh from S3 at first boot (mirrors the
        # app pattern). Object-level grant is scoped to scripts/* so the role
        # cannot read terraform state files in the same bucket.
        Sid      = "ReadInitScript"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${local.state_bucket}/scripts/*"
      },
      {
        # s3:ListBucket is bucket-level — separate ARN required. bootstrap.sh
        # uses `aws s3 ls s3://bucket/scripts/` as a readiness probe.
        Sid      = "ListInitScripts"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.state_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = ["scripts/*"] }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "db_secrets" {
  role       = aws_iam_role.db.name
  policy_arn = aws_iam_policy.db_secrets.arn
}

resource "aws_iam_instance_profile" "db" {
  name = "packiot-staging-db"
  role = aws_iam_role.db.name
}

# ── IAM: App EC2 ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "app" {
  name = "packiot-staging-app"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "app_custom" {
  name = "packiot-staging-app-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadStagingSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:packiot/staging/*",
          # databaseCredentials holds the prod SELECT-only awslambda user creds,
          # read by the mirror-worker to replay prod user_logs onto staging.
          # ?????? matches the 6-char alphanumeric suffix AWS auto-appends —
          # constraining to the canonical name only. A future secret like
          # `databaseCredentials-prod-foo-XXXXXX` would NOT match (12 chars
          # after the literal `databaseCredentials-` instead of 6).
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:databaseCredentials-??????",
        ]
      },
      {
        # Write access to app-owned staging secrets (e.g. the operator super-admin
        # password packiot/staging/operator/*). Scoped to packiot/staging/* so the
        # box can create/rotate its own secrets instead of leaving a plaintext file
        # on disk. Read stays the separate ReadStagingSecrets statement above.
        # NOTE: applied live via `aws iam create-policy-version` (v8) because a
        # pre-existing templatefile bug (app_init.sh references GO_VERSION, not
        # passed in ec2.tf's vars map) currently blocks `terraform plan/apply`.
        Sid    = "WriteStagingAppSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue",
          "secretsmanager:TagResource",
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:packiot/staging/*",
        ]
      },
      {
        Sid      = "ReadInitScript"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${local.state_bucket}/scripts/*"
      },
      {
        # s3:ListBucket is bucket-level (not object-level) — separate ARN required.
        # bootstrap.sh uses `aws s3 ls s3://bucket/scripts/` to wait for S3 access.
        Sid      = "ListInitScripts"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.state_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = ["scripts/*"] }
        }
      },
      {
        # Certbot uses DNS-01 challenge: creates a TXT record in Route53,
        # waits for propagation, then Let's Encrypt verifies domain ownership.
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
        # CWAgent namespace. PutMetricData is the write path; the agent's own
        # config refresh + log polls don't need extra permissions because the
        # EC2 already has AmazonSSMManagedInstanceCore + S3 access for its
        # bootstrap script. Disk-fill alarm at 75% lives in Terraform separately
        # (aws_cloudwatch_metric_alarm.app_disk_used_percent).
        Sid      = "PublishCloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        # CS-Admin cognito-users page (edge-api, running on this app EC2 under
        # the instance role) manages Cognito users/groups for onboarding. The
        # ListUsers-backed page 502'd because the role lacked cognito-idp read
        # access. Scoped to the single staging user pool ARN — no wildcard —
        # so the app can only touch the pool it authenticates against. Codifies
        # the inline policy added live (put-role-policy csadmin-cognito-user-mgmt).
        Sid    = "CsAdminCognitoUserMgmt"
        Effect = "Allow"
        Action = [
          "cognito-idp:ListUsers",
          "cognito-idp:AdminGetUser",
          "cognito-idp:AdminCreateUser",
          "cognito-idp:AdminSetUserPassword",
          "cognito-idp:AdminAddUserToGroup",
          "cognito-idp:AdminRemoveUserFromGroup",
          "cognito-idp:AdminListGroupsForUser",
          "cognito-idp:ListGroups",
          "cognito-idp:AdminDisableUser",
          "cognito-idp:AdminEnableUser",
        ]
        Resource = "arn:aws:cognito-idp:${var.aws_region}:${data.aws_caller_identity.current.account_id}:userpool/us-east-1_0T9t1sTwt"
      },
      {
        # apply-agent-config (edge-ssm #224) provisions a tenant's raw_tag_map
        # into the shared multi-tenant sparkplug-agent-shared, which runs on THIS
        # app box. edge-api (on this instance role) SSM-SendCommands the box to
        # ITSELF to base64-write the tenant yaml + force-recreate the agent. The
        # SendCommand needs BOTH the document AND the target instance authorized,
        # and a Condition binds the whole statement — so, exactly like the external
        # packiot-edge-ssm-control policy, they are split: the document carries no
        # tag (unconditioned), the target is scoped by the managed-by tag.
        Sid      = "SharedAgentSendCommandDocument"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"
      },
      {
        # Target scope: SendCommand only to an EC2 instance tagged
        # managed-by=packiot-edge-api (the app box carries it — see
        # aws_instance.app.tags). CRITICAL: an EC2 target uses the ec2:instance
        # ARN, NOT ssm:instance (that namespace is hybrid mi- activations only) —
        # the mismatch silently AccessDenies. Codifies the live
        # packiot-edge-ssm-control v4 grant so seam2 is self-sufficient in-repo.
        Sid      = "SharedAgentSendCommandTarget"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/managed-by" = "packiot-edge-api" }
        }
      }
    ]
  })
}

# Disk-fill alarm at 75% on the app EC2 root volume. Triggered by the
# CWAgent disk_used_percent metric for path=/ on the staging app instance.
# Action target: SNS topic that pages on-call (created separately if not
# already present — for now we use the existing 'packiot-staging-alerts'
# topic name; harmless to alarm without an SNS subscriber while we wire it).
#
# Threshold rationale: 75% catches drift before the 2026-06-22 100% lockout
# scenario repeats. Disk grew to 64 GB so 75% = 48 GB used (vs 27 GB
# steady-state today) — plenty of headroom for legitimate growth before
# alarming.
resource "aws_cloudwatch_metric_alarm" "app_disk_used_percent" {
  alarm_name          = "packiot-staging-app-disk-used-percent"
  alarm_description   = "Staging app EC2 root disk > 75% — investigate docker / log churn before it fills (see ebs-rescue-mount-stuck-ec2 zettel for recovery)"
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
  # alarm_actions intentionally empty for now — the alarm becomes observable
  # via the AWS console and Grafana CloudWatch datasource immediately, and
  # we can wire SNS / chatops later without recreating it.
  tags = {
    Project     = "packiot-stack-alpha"
    Environment = "staging"
    Owner       = "ops"
  }
}

resource "aws_iam_role_policy_attachment" "app_custom" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.app_custom.arn
}

resource "aws_iam_instance_profile" "app" {
  name = "packiot-staging-app"
  role = aws_iam_role.app.name
}

# ── SSH Key Pair ──────────────────────────────────────────────────────────────
# Emergency/debug SSH access. The corresponding private key is in the
# operator's ~/.ssh/id_ed25519 — no need to store it in Secrets Manager.

resource "aws_key_pair" "ops" {
  key_name   = "packiot-staging-ops"
  public_key = var.ops_ssh_public_key
}

# ── DB EC2 ────────────────────────────────────────────────────────────────────
# On-demand — spot interruption during a PostgreSQL write can corrupt WAL.

resource "aws_instance" "db" {
  ami                    = data.aws_ami.al2023_arm64.id
  instance_type          = var.db_instance_type
  subnet_id              = aws_subnet.private.id
  private_ip             = "10.10.10.89"
  vpc_security_group_ids = [aws_security_group.db.id]
  iam_instance_profile   = aws_iam_instance_profile.db.name
  key_name               = aws_key_pair.ops.key_name

  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    volume_size           = var.db_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false # preserve data on accidental termination
  }

  # Tiny bootstrapper only — fetches the real init script from S3 at runtime.
  # db_init.sh is uploaded as aws_s3_object.db_init (rendered with all vars).
  # See user_data/db_bootstrap.sh and the explanatory comment on the
  # aws_s3_object.db_init resource for the reason this is split.
  user_data = base64encode(templatefile("${path.module}/user_data/db_bootstrap.sh", {
    state_bucket = local.state_bucket
    aws_region   = var.aws_region
  }))

  tags = { Name = "packiot-staging-db" }

  # S3 object must exist before the instance boots and db_bootstrap.sh runs.
  depends_on = [aws_s3_object.db_init]

  lifecycle {
    # Prevent Terraform from replacing the instance when the AMI updates.
    # Trigger a manual AMI update + instance refresh to control timing.
    ignore_changes = [ami, user_data]
  }
}

# ── App EC2 ───────────────────────────────────────────────────────────────────
# On-demand — reliable for staging; spot was too frequently interrupted.
# For production: replace with ASG + mixed on-demand/spot fleet.

resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = var.app_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  key_name                    = aws_key_pair.ops.key_name
  associate_public_ip_address = false # using static EIP (see vpc.tf)

  # T4G defaults to unlimited burst; standard avoids surprise overage charges
  # on staging. Production should use unlimited (availability > cost).
  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    volume_size           = var.app_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  # Tiny bootstrapper only — fetches the real init script from S3 at runtime.
  # app_init.sh is uploaded as aws_s3_object.app_init (rendered with all vars).
  user_data = base64encode(templatefile("${path.module}/user_data/app_bootstrap.sh", {
    state_bucket = local.state_bucket
    aws_region   = var.aws_region
  }))

  # managed-by=packiot-edge-api: the ownership tag edge-api's SendCommand policy
  # (SharedAgentSendCommandTarget above) scopes to. This box runs both edge-api
  # AND the shared sparkplug-agent-shared, so apply-agent-config self-targets it.
  # Must stay in sync with that policy Condition — dropping this tag AccessDenies
  # every apply-agent-config. Codifies the live `ec2 create-tags` added 2026-09-01.
  tags = {
    Name         = "packiot-staging-app"
    "managed-by" = "packiot-edge-api"
  }

  # Both S3 objects must exist before the instance boots and app_init.sh runs.
  depends_on = [aws_s3_object.app_init, aws_s3_object.nginx_setup]

  lifecycle {
    # associate_public_ip_address drifts when EIP is re-associated after replacement;
    # the EIP handles static public IP so the instance attribute doesn't matter.
    ignore_changes = [ami, user_data, associate_public_ip_address]
  }
}
