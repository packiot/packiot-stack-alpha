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
    aws_region     = var.aws_region
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
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:packiot/staging/db*"
    }]
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
        Sid      = "ReadStagingSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:packiot/staging/*"
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
      }
    ]
  })
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

  user_data = base64encode(templatefile("${path.module}/user_data/db_init.sh", {
    db_name    = var.db_name
    db_user    = var.db_user
    aws_region = var.aws_region
    vpc_cidr   = var.vpc_cidr
  }))

  tags = { Name = "packiot-staging-db" }

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

  tags = { Name = "packiot-staging-app" }

  # Both S3 objects must exist before the instance boots and app_init.sh runs.
  depends_on = [aws_s3_object.app_init, aws_s3_object.nginx_setup]

  lifecycle {
    # associate_public_ip_address drifts when EIP is re-associated after replacement;
    # the EIP handles static public IP so the instance attribute doesn't matter.
    ignore_changes = [ami, user_data, associate_public_ip_address]
  }
}
