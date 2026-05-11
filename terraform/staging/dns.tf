# Route53 hosted zone for staging.packiot.com.
#
# ⚠️  MANUAL STEP AFTER APPLY:
#   Terraform outputs the NS records for this zone (see outputs.tf).
#   Log in to register.it and add them as NS records for the subdomain
#   "staging.packiot.com" pointing at these nameservers.
#   DNS delegation propagates in 24-48h.

resource "aws_route53_zone" "staging" {
  name = var.staging_domain
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
