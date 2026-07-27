# ── App EC2 SG ────────────────────────────────────────────────────────────────
# HTTP/HTTPS open to internet — Nginx basic auth is the access control layer.
# SSH kept open for emergency ops access (key pair only, no password auth).

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

  ingress {
    description = "AMQPS - factory edge clients publishing to RabbitMQ via Nginx TLS proxy"
    from_port   = 5671
    to_port     = 5671
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ADR-0042 P1 — CPACK Node-RED tee → sparkplug-agent /v1/tags front-door.
  # Unlike the other ingress rules this is NOT world-open: it admits only CPACK's
  # egress /32. Nginx terminates TLS on 8447 (nginx_setup.sh cpack-ingest.conf)
  # and proxies to sparkplug-agent-cpack. Inline block (not a standalone
  # aws_security_group_rule) so it stays inside this SG's authoritative rule set
  # — mixing the two forms makes Terraform revoke the standalone rule on apply.
  ingress {
    description = "ADR-0042 P1 CPACK Node-RED tee -> sparkplug-agent /v1/tags (CPACK egress /32 only)"
    from_port   = 8447
    to_port     = 8447
    protocol    = "tcp"
    cidr_blocks = ["179.162.112.58/32"]
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
