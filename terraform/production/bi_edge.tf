# ══════════════════════════════════════════════════════════════════════════════
# BI edge — CloudFront + WAF + origin-lock in front of the Superset box
# ══════════════════════════════════════════════════════════════════════════════
#
# superset.tf follow-up (4). Puts an internet-facing WAF-protected CloudFront edge
# in front of `bi.prod.packiot.app` (the dedicated Superset box, EIP 3.224.168.52).
# This is a SECOND CloudFront distribution, separate from edge.tf's, because bi
# needs its OWN exact-match alias `bi.prod.packiot.app`. AWS explicitly allows an
# exact CNAME on one distribution to coexist with a wildcard (`*.prod.packiot.app`,
# carried by edge.tf's distribution) on another — the exact match wins for bi.
#
# WHY NO oauth2-proxy/Cognito IN FRONT (unlike the admin UIs on edge.tf):
# Superset serves EMBEDDED dashboards to front4 via edge-api-minted GUEST TOKENS.
# front4's embedded-sdk calls Superset's guest-token + chart-data APIs directly
# from the browser. Putting an SSO auth_request gate in front would 401 those
# embed calls. So the posture here is WAF + origin-lock ONLY: Superset's own admin
# login (AUTH_DB) gates the interactive UI, guest tokens gate the embeds, and the
# WAF + X-Origin-Verify header protect the origin. NOTHING here authenticates the
# viewer — that is Superset's job.
#
# CACHING: CachingDisabled + AllViewer for ALL paths (mirrors edge.tf). This is
# the load-bearing correctness choice for the embed: the guest-token mint, the
# embedded dashboard GETs, and the /api/v1/chart/data POSTs all carry cookies +
# Authorization + a guest-token header and must never be cached or have headers
# stripped. AllViewer forwards EVERY header (incl. Host — nginx routes by it),
# cookie, and query string; CachingDisabled guarantees no dynamic response is
# cached. Static-asset caching (/static/*) is a possible future optimisation but
# is deliberately omitted here to keep the embed path provably correct.
#
# ORIGIN-LOCK: CloudFront stamps `X-Origin-Verify: <secret>` on every origin
# request; nginx on the box 403s anything lacking it (host-managed, applied via
# SSM after the DNS cutover — same tight-pair ordering as edge.tf runbook step c).
# The secret lives in Secrets Manager (packiot/production/bi-origin-verify), not
# just a terraform output, so the box can fetch it itself and it is never printed.
#
# us-east-1: like edge.tf, the WAFv2 CLOUDFRONT-scope web ACL and the CloudFront
# viewer ACM cert MUST be us-east-1. We REUSE edge.tf's wildcard cert (its
# `*.prod.packiot.app` SAN covers `bi.prod.packiot.app`) — no second cert needed.

# ── Feature-local variables ─────────────────────────────────────────────────────

variable "bi_login_rate_limit" {
  description = <<-EOT
    Rate-based rule threshold for the Superset LOGIN path (/login*): max requests
    per 5-minute window per source IP before block. Stricter than the global
    var.waf_rate_limit because /login is a credential-stuffing / brute-force
    target and legitimate humans log in a handful of times, not hundreds. Always
    blocks (not gated by waf_managed_rules_mode).
  EOT
  type        = number
  default     = 100
}

# ── Origin-verify shared secret (Secrets Manager) ───────────────────────────────
# CloudFront injects this as X-Origin-Verify on every origin request; nginx on the
# box rejects requests lacking it. Stored in Secrets Manager (not merely a TF
# output) so superset_init.sh / an SSM step can read it on the box without the
# value ever transiting a terminal. special=false keeps it safe in an nginx `if`
# string compare.
resource "random_password" "bi_origin_verify" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "bi_origin_verify" {
  name                    = "packiot/production/bi-origin-verify"
  recovery_window_in_days = 7
  description             = "X-Origin-Verify shared secret: CloudFront (bi_edge) stamps it, the Superset box nginx requires it. Rotating = TF apply (new value) + re-run the nginx enforcement SSM step in the same window."
}

resource "aws_secretsmanager_secret_version" "bi_origin_verify" {
  secret_id = aws_secretsmanager_secret.bi_origin_verify.id
  secret_string = jsonencode({
    value = random_password.bi_origin_verify.result
  })
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. WAFv2 web ACL (scope CLOUDFRONT — us-east-1)
# ══════════════════════════════════════════════════════════════════════════════
#
# Mirrors edge.tf's ACL: default-allow, a global rate-based DoS guard (always
# blocks), the FOUR AWS managed groups gated by the shared var.waf_managed_rules_
# mode (count = observe, block = enforce), PLUS a stricter rate-limit scoped to
# /login (brute-force guard). SizeRestrictions_BODY stays in count even when the
# group enforces: Superset's /api/v1/chart/data POSTs (form_data + adhoc SQL
# filters) routinely exceed the 8 KB cap and blocking them would break embedded
# dashboards — exactly the same "don't let a body-size rule break a legitimate
# large POST" carve-out edge.tf makes for the onboarding descriptor.
locals {
  bi_waf_managed_groups = [
    { name = "AWSManagedRulesCommonRuleSet", metric = "CommonRuleSet", count_rules = ["SizeRestrictions_BODY"] },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", metric = "KnownBadInputs", count_rules = [] },
    { name = "AWSManagedRulesSQLiRuleSet", metric = "SQLiRuleSet", count_rules = [] },
    { name = "AWSManagedRulesAmazonIpReputationList", metric = "AmazonIpReputation", count_rules = [] },
  ]
}

resource "aws_wafv2_web_acl" "bi_edge" {
  count    = var.waf_enabled ? 1 : 0
  provider = aws.us_east_1
  name     = "packiot-production-bi-edge"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Global rate-based DoS guard — always blocks (priority 0).
  rule {
    name     = "RateLimitPerIP"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "packiot-prod-bi-edge-ratelimit"
      sampled_requests_enabled   = true
    }
  }

  # Stricter rate-limit scoped to the /login path — always blocks (priority 1).
  rule {
    name     = "LoginRateLimit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.bi_login_rate_limit
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "STARTS_WITH"
            search_string         = "/login"
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "packiot-prod-bi-edge-loginratelimit"
      sampled_requests_enabled   = true
    }
  }

  # AWS managed rule groups — action gated by var.waf_managed_rules_mode.
  # Priorities 2..5 (rate rules took 0..1).
  dynamic "rule" {
    for_each = { for i, g in local.bi_waf_managed_groups : g.name => merge(g, { priority = i + 2 }) }

    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = var.waf_managed_rules_mode == "block" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = var.waf_managed_rules_mode == "count" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"

          dynamic "rule_action_override" {
            for_each = toset(rule.value.count_rules)
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "packiot-prod-bi-edge-${rule.value.metric}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "packiot-prod-bi-edge-acl"
    sampled_requests_enabled   = true
  }

  tags = { Name = "packiot-production-bi-edge-waf" }
}

# ══════════════════════════════════════════════════════════════════════════════
# 2. CloudFront distribution (exact alias bi.prod.packiot.app)
# ══════════════════════════════════════════════════════════════════════════════
#
# Reuses edge.tf's Managed-CachingDisabled + Managed-AllViewer data sources and
# the edge wildcard ACM cert (covers bi.prod.packiot.app).
resource "aws_cloudfront_distribution" "bi_edge" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "packiot production BI edge — WAF + TLS in front of the Superset box (bi-origin.prod.packiot.app → Superset EIP)"
  price_class     = var.cloudfront_price_class

  # EXACT alias — coexists with edge.tf's `*.prod.packiot.app` wildcard on the
  # other distribution (AWS: exact match wins over wildcard).
  aliases = ["${var.superset_subdomain}.${var.production_domain}"]

  # Single origin — the Superset box, reached over its OWN (non-fronted) hostname
  # bi-origin.prod.packiot.app so the box EIP is never a CloudFront alias (avoids a
  # resolution loop). https-only; the box's certbot wildcard *.prod.packiot.app
  # cert covers bi-origin.prod.packiot.app for the origin TLS SNI. AllViewer
  # forwards the viewer Host (bi.prod.packiot.app) which nginx routes by.
  origin {
    domain_name = "bi-origin.${var.production_domain}"
    origin_id   = "prod-superset-origin"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 30
    }

    # Shared secret CloudFront stamps on every origin request; nginx enforces it
    # (host-managed, via SSM) so direct-to-EIP callers get 403.
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.bi_origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id       = "prod-superset-origin"
    viewer_protocol_policy = "redirect-to-https"
    # Full method set — Superset is an interactive app + API (POST chart-data,
    # guest-token mint, PUT/PATCH/DELETE for saved objects), not a static site.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    # CachingDisabled + AllViewer = never cache, forward every header (incl. Host)
    # + cookies + Authorization + querystring. Load-bearing for the guest-token
    # embed + admin login (see file header).
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  web_acl_id = var.waf_enabled ? aws_wafv2_web_acl.bi_edge[0].arn : null

  restrictions {
    geo_restriction {
      restriction_type = var.cloudfront_geo_restriction_type
      locations        = var.cloudfront_geo_restriction_locations
    }
  }

  # Reuse edge.tf's validated wildcard cert — *.prod.packiot.app covers bi.prod.
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.edge.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "packiot-production-bi-edge-cf" }
}

# ══════════════════════════════════════════════════════════════════════════════
# 3. DNS — origin record (SAFE) + bi.prod cutover (this REPLACES superset.tf's A)
# ══════════════════════════════════════════════════════════════════════════════

# SAFE — the NON-fronted hostname CloudFront dials as its origin. Must always
# resolve to the Superset EIP or CloudFront has nowhere to send traffic. Mirrors
# edge.tf's origin.prod record.
resource "aws_route53_record" "superset_bi_origin" {
  zone_id = aws_route53_zone.production.zone_id
  name    = "bi-origin.${var.production_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.superset.public_ip]
}

# NOTE: the bi.prod.packiot.app cutover (A → ALIAS → this distribution) is done by
# MUTATING aws_route53_record.superset_bi IN PLACE in superset.tf (allow_overwrite
# atomic UPSERT), not by a second record here — keeping one resource for one name
# avoids an A/ALIAS collision. See superset.tf.

# ══════════════════════════════════════════════════════════════════════════════
# 4. Outputs
# ══════════════════════════════════════════════════════════════════════════════

output "bi_edge_cloudfront_domain_name" {
  description = "BI CloudFront distribution domain (the ALIAS target bi.prod.packiot.app points at)."
  value       = aws_cloudfront_distribution.bi_edge.domain_name
}

output "bi_edge_cloudfront_distribution_id" {
  description = "BI CloudFront distribution id (for cache invalidations / console lookups)."
  value       = aws_cloudfront_distribution.bi_edge.id
}

output "bi_edge_waf_web_acl_arn" {
  description = "WAFv2 web ACL ARN attached to the BI CloudFront distribution (null when waf_enabled=false)."
  value       = var.waf_enabled ? aws_wafv2_web_acl.bi_edge[0].arn : null
}

output "bi_origin_verify_secret_arn" {
  description = "Secrets Manager ARN holding the X-Origin-Verify secret (value NOT exported — read it on the box via the IAM role)."
  value       = aws_secretsmanager_secret.bi_origin_verify.arn
}
