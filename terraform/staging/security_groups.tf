# ── CloudFront managed prefix list ────────────────────────────────────────────
# AWS-maintained list of all CloudFront origin-facing IP ranges.
# Using this instead of 0.0.0.0/0 ensures only CloudFront can reach port 80.
# The list updates automatically — no manual maintenance needed.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# ── App EC2 SG ────────────────────────────────────────────────────────────────
# Port 80 (HTTP): CloudFront origin traffic only — restricted to CF prefix list.
# Port 443 (HTTPS): NOT exposed — CloudFront uses HTTP origin (port 80).
#   Let's Encrypt cert + port 443 on Nginx exist for emergency direct access
#   but are unreachable from the internet via this SG.
# SSH: kept open for emergency SSM-free access (ops key pair, not password).

resource "aws_security_group" "app" {
  name   = "packiot-staging-app"
  vpc_id = aws_vpc.staging.id

  ingress {
    description = "SSH - emergency/debug access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description     = "HTTP - CloudFront origin traffic only (WAF + CF handle TLS)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    description = "All outbound - Docker Hub pulls, GitHub, AWS APIs, DB"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-staging-app-sg" }
}

# ── DB EC2 SG ─────────────────────────────────────────────────────────────────
# Only accepts PostgreSQL from the App EC2.
# Egress through fck-nat for OS updates and TimescaleDB telemetry (disabled).

resource "aws_security_group" "db" {
  name   = "packiot-staging-db"
  vpc_id = aws_vpc.staging.id

  ingress {
    description     = "PostgreSQL from App EC2 only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "OS updates and SSM via fck-nat"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-staging-db-sg" }
}
