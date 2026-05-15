# ACM wildcard certificate for *.staging.packiot.app — required by CloudFront for
# viewer-facing HTTPS. CloudFront only accepts ACM certs from us-east-1, which is
# already our primary provider region so no aliased provider is needed.
#
# Route53 DNS-01 validation is fully automated: Terraform writes the CNAME
# validation record into the staging child zone, then waits for ACM to confirm.

resource "aws_acm_certificate" "staging_wildcard" {
  domain_name               = "*.${var.staging_domain}"
  subject_alternative_names = [var.staging_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.staging_wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.staging.zone_id
}

resource "aws_acm_certificate_validation" "staging_wildcard" {
  certificate_arn         = aws_acm_certificate.staging_wildcard.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}
