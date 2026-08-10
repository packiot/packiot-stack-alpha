# ── App EC2 SG ────────────────────────────────────────────────────────────────
# App EC2 hosts the service plane + (until W6 lands) the local TimescaleDB.
# HTTP/HTTPS open to internet — Nginx + Authentik provide the access control
# layer. SSH kept open for emergency ops. Two rules are NOT world-open: the
# 8883 mTLS ingest listener (W2, client egress /32 only) below, and the DB SG's
# PostgreSQL rule (W6, from this SG only).

resource "aws_security_group" "app" {
  name   = "packiot-production-app"
  vpc_id = aws_vpc.production.id

  ingress {
    description = "SSH - emergency/debug access (key pair only, no password)"
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
      description = "HTTPS - all production service endpoints (world-open; pre origin-lock)"
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

  # ADR-0042 §6 (W2) — per-tenant mTLS SparkPlug uplink landing zone.
  # The client-edge sparkplug-agent (bundle #624) dials ssl://ingest.prod…:8883.
  # mosquitto terminates mTLS on 8883 directly (NOT nginx — broker-terminated),
  # uses the client-cert CN as identity, and a CN-keyed ACL scopes each tenant
  # to spBv1.0/<CN>/#. This rule is NOT world-open: it admits ONLY the client
  # factory-edge egress /32(s) in var.client_ingest_egress_cidrs (mirrors
  # staging's CPACK /32 gate). Inline block (not a standalone
  # aws_security_group_rule) so it stays in this SG's authoritative rule set —
  # mixing the two forms makes Terraform revoke the standalone rule on apply.
  #
  # NOTE: staging's world-open AMQPS 5671 rule is deliberately NOT copied —
  # prod's factory uplink is mTLS-CN-scoped 8883, not an open AMQP broker.
  ingress {
    description = "ADR-0042 mTLS SparkPlug uplink (client-edge #624 to mosquitto :8883; client egress /32 only)"
    from_port   = var.ingest_mqtts_port
    to_port     = var.ingest_mqtts_port
    protocol    = "tcp"
    cidr_blocks = var.client_ingest_egress_cidrs
  }

  egress {
    description = "All outbound - Docker Hub pulls, GitHub, AWS APIs, DB EC2"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-production-app-sg" }
}

# ── DB EC2 SG (W6 — dedicated DB instance) ────────────────────────────────────
# Only accepts PostgreSQL from the App EC2 SG (no CIDR — SG-referencing rule, so
# it tracks the app instance even across replacement). Egress via the NAT
# instance for OS updates, SSM, Docker pulls, Secrets Manager. Mirrors staging's
# `aws_security_group.db`. Used by the dedicated DB EC2 in database.tf.
resource "aws_security_group" "db" {
  name   = "packiot-production-db"
  vpc_id = aws_vpc.production.id

  ingress {
    description     = "PostgreSQL from App EC2 only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  # Superset metadata DB + bi.* views connect UPSTREAM-DIRECT to the r7g
  # (compose.superset.yml: POSTGRES_HOST_UPSTREAM). This adopts the rule
  # applied out-of-band at Superset bring-up (superset.tf follow-up 1). It
  # MUST match the live rule (sgr-0a45147c78615a67d) exactly so terraform
  # reconciles to a no-op rather than creating a duplicate.
  ingress {
    description     = "PostgreSQL from Superset box (metadata + bi.* views)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.superset.id]
  }

  egress {
    description = "OS updates, SSM, Docker pulls, Secrets Manager via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-production-db-sg" }
}
