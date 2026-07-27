# packiot.app is registered through Route53 — AWS owns both registrar and DNS.
# No manual NS delegation needed: Terraform wires the staging child zone into
# the parent packiot.app zone automatically.

# Parent zone — created by Route53 when packiot.app was registered.
data "aws_route53_zone" "packiot_app" {
  name         = "packiot.app."
  private_zone = false
}

# Child zone for staging.packiot.app
resource "aws_route53_zone" "staging" {
  name = var.staging_domain
}

# Delegate staging.packiot.app → child zone NS records in the parent zone.
# This is the "glue" that makes DNS resolution work end-to-end without any
# manual steps — Route53 looks up the NS records here and forwards queries.
resource "aws_route53_record" "staging_ns" {
  zone_id = data.aws_route53_zone.packiot_app.zone_id
  name    = var.staging_domain
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.staging.name_servers
}

# One A record per service → App EC2 static EIP.
# Nginx on the App EC2 routes each hostname to its local Docker port.
resource "aws_route53_record" "services" {
  for_each = var.services
  zone_id  = aws_route53_zone.staging.zone_id
  name     = "${each.key}.${var.staging_domain}"
  type     = "A"
  ttl      = 60
  records  = [aws_eip.app.public_ip]
}

# Dedicated DNS name for the AMQPS TCP proxy (port 5671).
# Not in var.services because stream-proxy (TCP) doesn't need an HTTP vhost.
# Factory edge clients connect to: amqps://amqp.staging.packiot.app:5671
resource "aws_route53_record" "amqp" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = "amqp.${var.staging_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}

# RabbitMQ management HTTP API — exposed via Nginx HTTPS proxy (port 443).
# Used by factory edges that lack amqplib: they POST to this endpoint to publish
# SparkPlug messages. No nginx basic auth — RabbitMQ handles its own auth.
# Client user must have the 'management' tag to access this endpoint.
resource "aws_route53_record" "mq" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = "mq.${var.staging_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}

# Authentik SSO login page — browser entry point for all staging SSO flows.
# No Nginx auth_request on this vhost (it IS the authentication endpoint).
resource "aws_route53_record" "auth" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = "auth.${var.staging_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}

# CPACK agent ingest front-door (ADR-0042 P1) — cpack-ingest.staging.packiot.app.
# Not in var.services because it's a dedicated port-8447 TLS reverse-proxy for
# the sparkplug-agent /v1/tags endpoint (not a standard 443 HTTP vhost). Nginx
# on the App EC2 (terraform/staging/user_data/nginx_setup.sh) terminates TLS and
# proxies to sparkplug-agent-cpack; the App EC2 SG admits 8447 from CPACK's
# egress /32 only (security_groups.tf).
resource "aws_route53_record" "cpack_ingest" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = "cpack-ingest.${var.staging_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}
