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

# ── DB EC2 ────────────────────────────────────────────────────────────────────
# On-demand — spot interruption during a PostgreSQL write can corrupt WAL.

resource "aws_instance" "db" {
  ami                    = data.aws_ami.al2023_arm64.id
  instance_type          = var.db_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.db.id]
  iam_instance_profile   = aws_iam_instance_profile.db.name

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
# Spot with "stop" interruption behavior: AWS stops the instance (not terminates)
# when reclaiming capacity — EBS persists, Docker services resume on restart.
# For production: replace with ASG + mixed on-demand/spot fleet.

resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = var.app_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = false # using static EIP (see vpc.tf)

  instance_market_options {
    market_type = "spot"
    spot_options {
      instance_interruption_behavior = "stop"
      spot_instance_type             = "persistent"
    }
  }

  root_block_device {
    volume_size           = var.app_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  user_data = base64encode(templatefile("${path.module}/user_data/app_init.sh", {
    db_private_ip  = aws_instance.db.private_ip
    db_name        = var.db_name
    staging_domain = var.staging_domain
    services       = var.services
    aws_region     = var.aws_region
    github_repo    = var.github_repo
  }))

  tags = { Name = "packiot-staging-app" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
