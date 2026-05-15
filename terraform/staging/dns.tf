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
resource "aws_route53_record" "staging_ns" {
  zone_id = data.aws_route53_zone.packiot_app.zone_id
  name    = var.staging_domain
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.staging.name_servers
}

# origin.staging.packiot.app → EC2 EIP directly.
# This is the CloudFront origin hostname — NOT a user-facing URL.
# Using a named subdomain (not raw IP) allows CloudFront to resolve it and
# avoids the "IP address as origin domain" CloudFront validation restriction.
# The security group ensures only CloudFront can reach port 80 on this IP.
resource "aws_route53_record" "app_origin" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = "origin.${var.staging_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}

# Service subdomains → CloudFront distribution (ALIAS records, no TTL).
# CloudFront handles TLS termination, WAF filtering, and forwards to the
# EC2 origin over HTTP. Nginx virtual hosting routes each hostname to its
# local Docker port.
#
# CloudFront hosted zone ID Z2FDTNDATAQYW2 is a fixed AWS constant —
# the same for ALL CloudFront distributions in all regions.
resource "aws_route53_record" "services" {
  for_each = var.services
  zone_id  = aws_route53_zone.staging.zone_id
  name     = "${each.key}.${var.staging_domain}"
  type     = "A"

  alias {
    name                   = aws_cloudfront_distribution.staging.domain_name
    zone_id                = aws_cloudfront_distribution.staging.hosted_zone_id
    evaluate_target_health = false
  }
}
