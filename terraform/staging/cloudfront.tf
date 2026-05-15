# Single CloudFront distribution for all staging services.
#
# Architecture:
#   Browser → HTTPS → CloudFront → HTTP:80 → EC2 Nginx → Docker service
#
# Why HTTP origin (not HTTPS)?
#   CloudFront HTTPS-to-origin requires a cert valid for the origin hostname. The
#   LE wildcard cert covers *.staging.packiot.app — so using origin.staging.packiot.app
#   (defined in dns.tf) as the origin domain makes LE cert-based HTTPS-to-origin
#   possible, but adds circular DNS complexity. For staging, HTTP origin (traffic
#   stays within AWS network, SG restricts to CloudFront prefix list) is acceptable.
#   Production should use HTTPS origin + ACM cert on the ALB.
#
# CloudFront secret header:
#   CloudFront injects X-CloudFront-Secret on every origin request. Nginx rejects
#   requests without this header — prevents bypassing CloudFront via direct EC2 IP
#   access (defense-in-depth on top of the security group restriction).
#
# Caching: disabled (CachingDisabled managed policy) — all services are dynamic.
# AllViewer origin request policy: forwards all headers/cookies/QS from viewer to
#   origin, including the Authorization header for Nginx basic auth and the Host
#   header for Nginx virtual hosting.

locals {
  cf_aliases = [for svc in keys(var.services) : "${svc}.${var.staging_domain}"]
}

resource "aws_cloudfront_distribution" "staging" {
  enabled      = true
  comment      = "packiot-staging — all services"
  http_version = "http2and3"
  # PriceClass_100: US/Canada/Europe PoPs — cheapest, sufficient for staging.
  price_class = "PriceClass_100"
  web_acl_id  = aws_wafv2_web_acl.staging.arn
  aliases     = local.cf_aliases

  origin {
    origin_id = "packiot-staging-ec2"
    # origin.staging.packiot.app → EIP A record (defined in dns.tf).
    # Not a CF alias — a direct A record so CF can resolve without circular DNS.
    domain_name = "origin.${var.staging_domain}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Shared secret — Nginx rejects requests missing this header.
    # Only CloudFront knows the value; EC2 Nginx reads it from Secrets Manager at boot.
    custom_header {
      name  = "X-CloudFront-Secret"
      value = random_password.cloudfront_secret.result
    }
  }

  default_cache_behavior {
    target_origin_id = "packiot-staging-ec2"
    # All HTTP verbs — needed for Node-RED editor (PUT/DELETE) and NestJS APIs (POST).
    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD"]

    # CachingDisabled (4135ea2d-…) — all origin responses pass through uncached.
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    # AllViewer (216adef6-…) — forwards all headers (incl. Authorization, Host),
    # all cookies, and all query strings to origin.
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"

    # Viewers must use HTTPS; plain HTTP requests are 301-redirected to HTTPS.
    viewer_protocol_policy = "redirect-to-https"

    # WebSocket support — CloudFront passes Upgrade: websocket through natively.
    # Grafana live dashboards and Node-RED socket.io both rely on this.
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.staging_wildcard.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.staging_wildcard]
}
