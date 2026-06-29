# packiot.app is registered through Route53 (parent zone owned by AWS).
# This file delegates `prod.packiot.app` as a child zone and wires per-service
# A records to the production EC2's EIP. Same pattern as staging's dns.tf.

# Parent zone — created by Route53 when packiot.app was registered.
data "aws_route53_zone" "packiot_app" {
  name         = "packiot.app."
  private_zone = false
}

# Child zone for prod.packiot.app
resource "aws_route53_zone" "production" {
  name = var.production_domain
}

# Delegate prod.packiot.app → child zone NS records in the parent zone.
# This is the "glue" that makes DNS resolution work end-to-end with zero
# manual steps — Route53 looks up the NS records here and forwards queries.
resource "aws_route53_record" "production_ns" {
  zone_id = data.aws_route53_zone.packiot_app.zone_id
  name    = var.production_domain
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.production.name_servers
}

# One A record per service → App EC2 static EIP.
# Nginx on the App EC2 routes each hostname to its local Docker port.
resource "aws_route53_record" "services" {
  for_each = var.services
  zone_id  = aws_route53_zone.production.zone_id
  name     = "${each.key}.${var.production_domain}"
  type     = "A"
  ttl      = 60
  records  = [aws_eip.app.public_ip]
}

# Authentik SSO login page — browser entry point for all production SSO flows.
# No Nginx auth_request on this vhost (it IS the authentication endpoint).
resource "aws_route53_record" "auth" {
  zone_id = aws_route53_zone.production.zone_id
  name    = "auth.${var.production_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}

# NOTE: staging's `amqp.staging.packiot.app` + `mq.staging.packiot.app` records
# are deliberately ABSENT from production. AMQPS + RabbitMQ-management vhosts
# exist in staging because factory edges publish to staging's broker for
# testing. Production doesn't run an exposed broker for factories — they
# publish via their existing edge-nodered path. Re-add these records if/when
# the production stack starts ingesting factory traffic.
