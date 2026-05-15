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
