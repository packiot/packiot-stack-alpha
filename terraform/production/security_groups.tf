# ── App EC2 SG ────────────────────────────────────────────────────────────────
# Single EC2 hosts everything in the dry-run phase, so there's only ONE SG
# (vs staging's app+db pair). HTTP/HTTPS open to internet — Nginx + Authentik
# provide the access control layer. SSH kept open for emergency ops.
#
# When production gets split out (phase 3 — separate DB EC2), copy staging's
# `aws_security_group.db` pattern here and add the PostgreSQL-from-app
# ingress rule. The local-postgres-in-Docker today doesn't need that.

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

  # NOTE: AMQPS port 5671 deliberately ABSENT vs staging — production doesn't
  # run an MQTT/AMQP broker exposed to factories from this stack. Factory PCs
  # publish via their existing edge-nodered path (not through this env).
  # If/when the new prod stack starts receiving factory traffic, add the
  # 5671 ingress rule then.

  egress {
    description = "All outbound - Docker Hub pulls, GitHub, AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-production-app-sg" }
}
