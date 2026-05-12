# ── App EC2 SG ────────────────────────────────────────────────────────────────
# Receives HTTP/HTTPS from internet.
# Sends PostgreSQL traffic to DB SG.
# SSM Session Manager uses 443 outbound (to SSM endpoints via IGW) — no SSH needed.

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
    description = "HTTP (redirected to HTTPS by Nginx)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS - all staging service endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
