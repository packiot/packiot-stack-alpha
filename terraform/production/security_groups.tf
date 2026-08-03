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

  ingress {
    description = "HTTPS - all production service endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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

  # ADR-0042 Mode-A (as-built) — HTTPS ingest-shim front door on :8444.
  # The CPACK Node-RED tee POSTs SparkPlug-JSON here (X-Ingest-Key); the shim
  # republishes onto RabbitMQ → worker → F3. Same client-egress /32 gate as the
  # :8883 rule above; the two coexist (shim path today, agent+mTLS path is the
  # tracked durability follow-up). NOT world-open — the shim TLS-terminates and
  # refuses any request without the ingest key even inside the /32.
  ingress {
    description = "ADR-0042 HTTPS SparkPlug ingest-shim (client-edge tee to :8444; client egress /32 only)"
    from_port   = var.ingest_https_port
    to_port     = var.ingest_https_port
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

  egress {
    description = "OS updates, SSM, Docker pulls, Secrets Manager via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-production-db-sg" }
}
