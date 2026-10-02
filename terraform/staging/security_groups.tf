# ── App EC2 SG ────────────────────────────────────────────────────────────────
# HTTP/HTTPS open to internet — Nginx basic auth is the access control layer.
# No SSH ingress — access via SSM Session Manager (see below).

resource "aws_security_group" "app" {
  name   = "packiot-staging-app"
  vpc_id = aws_vpc.staging.id

  # NO SSH (closed 2026-09-24). Box access = SSM Session Manager only (no inbound port;
  # IAM-authorized, CloudTrail-audited). Evidence at closing: 0 accepted SSH logins in 30
  # days vs 4,429 failed/brute-force attempts — :22 served only attackers. Break-glass if
  # SSM itself is down: add a TEMPORARY rule for your /32, never 0.0.0.0/0.

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

  # DB-box observability push (DB box → app-box Alloy gateway). The DB box accepts
  # no inbound; it PUSHES. 3101 = Loki log relay (added live earlier, codified here
  # 2026-09-23 — it was missing, so an apply would have REVOKED it and silently cut
  # DB slow-query logs). 3102 = Prometheus remote-write relay for DB host metrics
  # (disk/cpu/mem; T0 grain-tiered retention). Source = DB SG only.
  ingress {
    description     = "Alloy Loki-push from DB-box log agent (staging observability)"
    from_port       = 3101
    to_port         = 3101
    protocol        = "tcp"
    security_groups = [aws_security_group.db.id]
  }
  ingress {
    description     = "Alloy Prometheus remote-write from DB-box agent (host metrics)"
    from_port       = 3102
    to_port         = 3102
    protocol        = "tcp"
    security_groups = [aws_security_group.db.id]
  }

  # Shared multi-tenant ingest front-door (ingest.staging:8449) → sparkplug-agent-shared.
  # NOT world-open: admits each onboarded client's box egress /32. As clients are
  # added, append their /32 here (bispharma SP = 200.153.25.2). A key-only public
  # variant is possible later, but keep the /32 defence-in-depth for now.
  ingress {
    description = "Shared multi-tenant agent v1 tags front-door (per-box egress /32 allowlist)"
    from_port   = 8449
    to_port     = 8449
    protocol    = "tcp"
    cidr_blocks = ["200.153.25.2/32"] # bispharma SP box
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

  # PostgreSQL-from-app ingress is a STANDALONE rule below (not inline): the app SG
  # now references this SG (DB-box observability push, 3101/3102), and two inline
  # cross-references form a Terraform dependency cycle. With NO inline ingress
  # blocks here, this SG's ingress is not authoritative, so the standalone rule is
  # never revoked. (Egress stays inline.)

  egress {
    description = "OS updates and SSM via fck-nat"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-staging-db-sg" }
}

# PostgreSQL from the App EC2 only — standalone to break the app<->db SG cycle
# (see aws_security_group.db). Adopts the EXISTING live rule via import (no
# revoke/recreate, no connection blip) on the next apply.
import {
  to = aws_vpc_security_group_ingress_rule.db_postgres_from_app
  id = "sgr-032604d5e315a1ebf"
}

resource "aws_vpc_security_group_ingress_rule" "db_postgres_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from App EC2 only"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}
