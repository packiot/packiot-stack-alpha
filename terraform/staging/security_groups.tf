# ── App EC2 SG ────────────────────────────────────────────────────────────────
# HTTP/HTTPS open to internet — Nginx basic auth is the access control layer.
# SSH kept open for emergency ops access (key pair only, no password auth).

resource "aws_security_group" "app" {
  name   = "packiot-staging-app"
  vpc_id = aws_vpc.staging.id

  # SSH is intentionally world-open as codified emergency access, and it is
  # hardened at the sshd layer (password auth OFF, key-only). Kept as-is.
  #
  # RECOMMENDATION (infra audit 2026-08-23, not applied — behaviour change):
  # if the team runs an ops bastion / VPN with a stable egress, tighten this to
  # that CIDR (or an AWS-managed prefix list) instead of 0.0.0.0/0. Day-to-day
  # box access already goes through SSM Session Manager (no inbound :22 needed),
  # so restricting :22 to an ops CIDR loses nothing operationally while removing
  # the internet-wide brute-force surface. Suggested shape (default preserves
  # today's behaviour):
  #   variable "ops_ssh_cidrs" { type = list(string)  default = ["0.0.0.0/0"] }
  #   cidr_blocks = var.ops_ssh_cidrs
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

  # HTTPS 443 — the edge origin-lock toggle (edge.tf, var.edge_origin_lock).
  # FALSE (default): world-open, exactly as before. TRUE: admit 443 ONLY from the
  # AWS-managed CloudFront origin-facing prefix list (pl-3b927c52) so the origin
  # can no longer be reached by bypassing CloudFront. Exactly one of these two
  # dynamic blocks is ever rendered. Port 80 stays world-open below: letsencrypt
  # http-01 renewals come from Let's Encrypt's own servers (not CloudFront), and
  # CloudFront dials the origin https-only so :80 carries no service traffic.
  dynamic "ingress" {
    for_each = var.edge_origin_lock ? [] : [1]
    content {
      description = "HTTPS - all staging service endpoints (world-open; pre origin-lock)"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  dynamic "ingress" {
    for_each = var.edge_origin_lock ? [1] : []
    content {
      description     = "HTTPS - CloudFront edge only (origin-lock; managed prefix list)"
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      prefix_list_ids = [var.cloudfront_prefix_list_id]
    }
  }

  ingress {
    description = "AMQPS (retiring, superseded by Node-RED agent mTLS 8883). CPACK egress /32 only"
    from_port   = 5671
    to_port     = 5671
    protocol    = "tcp"
    cidr_blocks = ["179.162.112.58/32"]
  }

  # ADR-0042 P1 — CPACK Node-RED tee → sparkplug-agent /v1/tags front-door.
  # Unlike the other ingress rules this is NOT world-open: it admits only CPACK's
  # egress /32. Nginx terminates TLS on 8447 (nginx_setup.sh cpack-ingest.conf)
  # and proxies to sparkplug-agent-cpack. Inline block (not a standalone
  # aws_security_group_rule) so it stays inside this SG's authoritative rule set
  # — mixing the two forms makes Terraform revoke the standalone rule on apply.
  ingress {
    description = "ADR-0042 P1 CPACK Node-RED tee to sparkplug-agent v1 tags (CPACK egress /32 only)"
    from_port   = 8447
    to_port     = 8447
    protocol    = "tcp"
    cidr_blocks = ["179.162.112.58/32"]
  }

  # bispharma box Modbus reader → sparkplug-agent-bispharma /v1/tags front-door.
  # Same NOT-world-open posture as cpack above: admits only the bispharma SP box
  # egress /32 (200.153.25.2). Nginx terminates TLS on 8448 (nginx_setup.sh
  # bispharma-ingest.conf) → sparkplug-agent-bispharma (172.18.0.43:9104).
  ingress {
    description = "BISPHARMA box Modbus reader to sparkplug-agent v1 tags (bispharma egress /32 only)"
    from_port   = 8448
    to_port     = 8448
    protocol    = "tcp"
    cidr_blocks = ["200.153.25.2/32"]
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
