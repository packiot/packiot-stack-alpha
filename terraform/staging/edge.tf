# ══════════════════════════════════════════════════════════════════════════════
# Edge protection — CloudFront + WAF + ACM in front of the staging nginx origin
# ══════════════════════════════════════════════════════════════════════════════
#
# Goal: put an internet-facing, defense-in-depth edge (CDN + WAF + managed TLS) in
# front of the single App EC2 whose nginx vhosts `<svc>.staging.packiot.app` by Host
# header. Today every `<svc>.staging.packiot.app` A-record points straight at the
# EIP and the App SG opens 443 to `0.0.0.0/0`. This file adds the edge layer WITHOUT
# forcing the cutover: cert + WAF + the CloudFront distribution are created eagerly
# (zero staging impact), while the two RISKY flips — repointing DNS at CloudFront
# and locking the SG down to CloudFront-only — are each gated behind a default-
# `false` variable so `terraform apply` on this branch is a safe no-op for live
# traffic.
#
# This is the staging port of terraform/production/edge.tf. Staging is SIMPLER than
# production in one way: there is no `dash.packiot.app` SAN (dash is a single cross-
# env page hosted on PROD, not a staging service), so the cert covers only the
# wildcard + apex and ALL validation records live in the staging CHILD zone — no
# cross-zone parent case.
#
# Staged rollout is documented in EDGE-PROTECTION-RUNBOOK.md. Flip order:
#   1. apply (cutover=false, lock=false)  → creates cert+WAF+CF, nothing changes
#   2. validate CF serves each vhost via --resolve
#   3. add the nginx X-Origin-Verify check on the host
#   4. edge_cutover=true                   → DNS → CloudFront
#   5. waf_managed_rules_mode="block"      → enforce the managed rule groups
#   6. edge_origin_lock=true               → SG 443 → CloudFront prefix list ONLY
#
# Provider note: CloudFront is a GLOBAL service, but its WAF web ACL (scope
# CLOUDFRONT) and its viewer ACM certificate MUST live in us-east-1. The root
# provider already defaults to us-east-1 (var.aws_region), but we pin an explicit
# `aws.us_east_1` alias (see main.tf) so these resources stay correct even if the
# region var is ever changed. Route53 + CloudFront itself are global and use the
# default provider.

# ── Edge variables (feature-local; kept here to minimise edits to variables.tf) ──

variable "edge_cutover" {
  description = <<-EOT
    RISKY FLIP #1 (default false = current behaviour). When false, the
    `<svc>.staging.packiot.app` records stay A → App EIP (traffic hits nginx
    directly, exactly as today). When true, those records become Route53 ALIAS
    records → the CloudFront distribution, cutting all service traffic through the
    edge. Flip AFTER validating CloudFront serves each vhost (runbook step (d)).
    Rollback = set back to false.
  EOT
  type        = bool
  default     = true # CUTOVER LIVE (staging) 2026-08-05 — svc records ALIAS→CloudFront
}

variable "edge_origin_lock" {
  description = <<-EOT
    RISKY FLIP #2 (default false = current behaviour). When false, the App SG
    admits 443 from 0.0.0.0/0 (world-open, as today). When true, 443 is admitted
    ONLY from the AWS-managed CloudFront origin-facing prefix list
    (var.cloudfront_prefix_list_id) — so the origin can no longer be reached by
    bypassing the edge. Flip LAST, after edge_cutover=true is proven healthy
    (runbook step (f)). Rollback = set back to false. NOTE: does NOT touch
    22 / 80 / 5671 / 8447 — see security_groups.tf.
  EOT
  type        = bool
  default     = false
}

variable "cloudfront_prefix_list_id" {
  description = "AWS-managed CloudFront origin-facing prefix list (us-east-1). Used by the SG when edge_origin_lock=true."
  type        = string
  default     = "pl-3b927c52"
}

variable "waf_enabled" {
  description = "Create + attach the WAFv2 web ACL to the CloudFront distribution. Default true."
  type        = bool
  default     = true
}

variable "waf_managed_rules_mode" {
  description = <<-EOT
    Action for the AWS managed rule groups: "count" (observe only — logs metrics,
    does not block) or "block" (enforce the groups' own block actions). Default
    "count" for a SAFE first rollout so we can watch CloudWatch/sampled-requests
    for false positives before enforcing. Flip to "block" at runbook step (e).
    NOTE: the rate-based rule always blocks regardless of this (2000/5-min per IP
    is a generous DoS guard, not a content filter).
  EOT
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "block"], var.waf_managed_rules_mode)
    error_message = "waf_managed_rules_mode must be either \"count\" or \"block\"."
  }
}

variable "waf_rate_limit" {
  description = "Rate-based rule threshold: max requests per 5-minute window per source IP before block."
  type        = number
  default     = 2000
}

variable "cloudfront_price_class" {
  description = "CloudFront price class. PriceClass_100 = NA + EU edge locations only (cheapest that covers our users)."
  type        = string
  default     = "PriceClass_100"
}

variable "cloudfront_geo_restriction_type" {
  description = "CloudFront geo restriction type: none | whitelist | blacklist. Default none."
  type        = string
  default     = "none"
}

variable "cloudfront_geo_restriction_locations" {
  description = "ISO 3166-1-alpha-2 country codes for the geo restriction (only used when restriction_type != none)."
  type        = list(string)
  default     = []
}

# ── Origin-verify shared secret ────────────────────────────────────────────────
# CloudFront injects this as the `X-Origin-Verify` header on every origin request.
# nginx on the host is then configured (host-managed — see runbook step (c)) to
# 403 any request that lacks it, so a caller who discovers the EIP and hits :443
# directly (before the SG lock lands, and as belt-and-suspenders after) is refused.
# `special = false` keeps the value safe to paste into an nginx `if` string compare.
resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. ACM certificate (us-east-1 — CloudFront viewer certs must be us-east-1)
# ══════════════════════════════════════════════════════════════════════════════
#
# One DNS-validated cert covering the wildcard + the apex. The wildcard
# `*.staging.packiot.app` matches api/hasura/grafana/... and origin.staging; the
# apex `staging.packiot.app` is the one explicit SAN. Unlike production there is NO
# dash SAN — dash lives on prod — so every validation record lands in the staging
# child zone (no parent-zone case).
resource "aws_acm_certificate" "edge" {
  provider    = aws.us_east_1
  domain_name = "*.${var.staging_domain}"
  subject_alternative_names = [
    var.staging_domain, # staging.packiot.app (apex)
  ]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "packiot-staging-edge-acm" }
}

# DNS validation records. ACM emits one validation CNAME per distinct domain — but
# the wildcard `*.staging.packiot.app` and the apex `staging.packiot.app` share ONE
# validation record (identical name+value), so keying the for_each by domain_name
# with allow_overwrite=true is the canonical de-dupe (HashiCorp ACM example).
#
# All records validate in the `staging` CHILD zone — there is no dash/parent-zone
# case to route around (that's the one simplification over production).
resource "aws_route53_record" "edge_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.edge.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = aws_route53_zone.staging.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "edge" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.edge.arn
  validation_record_fqdns = [for r in aws_route53_record.edge_cert_validation : r.fqdn]
}

# ══════════════════════════════════════════════════════════════════════════════
# 2. WAFv2 web ACL (scope CLOUDFRONT — must be us-east-1)
# ══════════════════════════════════════════════════════════════════════════════
#
# Default-allow ACL with, in priority order: a rate-based DoS guard (always
# blocks) then four AWS managed rule groups. The managed groups' action is gated
# by var.waf_managed_rules_mode ("count" = observe, "block" = enforce) so we can
# roll out in count mode, watch CloudWatch for false positives, then flip to block.
locals {
  # Ordered → priorities 1..N are derived from list index (rate rule takes 0).
  # `count_rules` = sub-rules kept in COUNT even when the group is enforced
  # (block). SizeRestrictions_BODY caps request bodies at 8 KB — but the
  # onboarding descriptor POST (/api/onboarding/generate + descriptor save) is
  # ~23 KB, so blocking it would break CS-Admin onboarding. Keep it observe-only;
  # the rest of CommonRuleSet + the other three groups enforce normally.
  waf_managed_groups = [
    { name = "AWSManagedRulesCommonRuleSet", metric = "CommonRuleSet", count_rules = ["SizeRestrictions_BODY"] },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", metric = "KnownBadInputs", count_rules = [] },
    { name = "AWSManagedRulesSQLiRuleSet", metric = "SQLiRuleSet", count_rules = [] },
    { name = "AWSManagedRulesAmazonIpReputationList", metric = "AmazonIpReputation", count_rules = [] },
  ]
}

resource "aws_wafv2_web_acl" "edge" {
  count    = var.waf_enabled ? 1 : 0
  provider = aws.us_east_1
  name     = "packiot-staging-edge"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Rate-based DoS guard — always blocks (not gated by the count/block mode).
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
      metric_name                = "packiot-staging-edge-ratelimit"
      sampled_requests_enabled   = true
    }
  }

  # AWS managed rule groups — action gated by var.waf_managed_rules_mode.
  # override_action `none {}` = use each group's own (block) actions;
  # override_action `count {}` = force every rule in the group to count only.
  dynamic "rule" {
    for_each = { for i, g in local.waf_managed_groups : g.name => merge(g, { priority = i + 1 }) }

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

          # Force selected sub-rules to COUNT even when the group enforces
          # (block) — see local.waf_managed_groups.count_rules rationale.
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
        metric_name                = "packiot-staging-edge-${rule.value.metric}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "packiot-staging-edge-acl"
    sampled_requests_enabled   = true
  }

  tags = { Name = "packiot-staging-edge-waf" }
}

# ══════════════════════════════════════════════════════════════════════════════
# 3. CloudFront distribution
# ══════════════════════════════════════════════════════════════════════════════
#
# AWS-managed policies: CachingDisabled (this is an API/SSO origin, never cache)
# + AllViewer origin-request (forward EVERY header — incl. Host — cookie, and
# querystring to nginx). Forwarding Host is CRITICAL: nginx routes vhosts by Host
# header; forwarding cookies + Authorization keeps Cognito/Authentik SSO working.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "edge" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "packiot staging edge — WAF + TLS in front of nginx origin (origin.staging.packiot.app → App EIP)"
  price_class     = var.cloudfront_price_class

  # Wildcard alias covers api/hasura/grafana/edge-nodered/oeecloud-nodered/rabbitmq/
  # adminer/operator/auth.staging. No dash alias (dash lives on prod).
  aliases = ["*.${var.staging_domain}"]

  # Single origin — the nginx host, reached over its OWN (non-fronted) hostname
  # origin.staging.packiot.app so the App EIP is never a CloudFront alias (avoids a
  # resolution loop). https-only to origin; the host's letsencrypt wildcard
  # *.staging.packiot.app cert covers origin.staging.packiot.app.
  origin {
    domain_name = "origin.${var.staging_domain}"
    origin_id   = "staging-nginx-origin"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 30
    }

    # Shared secret CloudFront stamps on every origin request; nginx enforces it
    # (host-managed, runbook step (c)) so direct-to-EIP callers get 403.
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id       = "staging-nginx-origin"
    viewer_protocol_policy = "redirect-to-https"
    # Full method set — these are APIs (POST/PUT/PATCH/DELETE), not a static site.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  # Attach the WAF only when enabled (count-gated resource).
  web_acl_id = var.waf_enabled ? aws_wafv2_web_acl.edge[0].arn : null

  restrictions {
    geo_restriction {
      restriction_type = var.cloudfront_geo_restriction_type
      locations        = var.cloudfront_geo_restriction_locations
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.edge.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "packiot-staging-edge-cf" }
}

# ══════════════════════════════════════════════════════════════════════════════
# 4. Origin record (SAFE) + DNS cutover (RISKY, var-gated)
# ══════════════════════════════════════════════════════════════════════════════

# SAFE — always created. origin.staging.packiot.app → App EIP is the NON-fronted
# hostname CloudFront dials as its origin. It is deliberately NOT in the cutover
# set: it must always resolve to the EIP or CloudFront has nowhere to send traffic.
resource "aws_route53_record" "origin" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = "origin.${var.staging_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}

# RISKY (var.edge_cutover) — parallel ALIAS records for the service vhosts. When
# edge_cutover=true these ALIAS `<svc>.staging.packiot.app` → CloudFront; the A→EIP
# copies in dns.tf go dormant (their for_each becomes empty). Z2FDTNDATAQYW2 is
# CloudFront's fixed global alias hosted-zone id.
resource "aws_route53_record" "services_edge" {
  for_each = var.edge_cutover ? var.services : {}

  zone_id = aws_route53_zone.staging.zone_id
  name    = "${each.key}.${var.staging_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.edge.domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

# RISKY (var.edge_cutover) — Superset BI ALIAS, the CloudFront counterpart of the
# `aws_route53_record.bi` A→EIP record in dns.tf. `bi` is NOT in var.services (it
# has a bespoke nginx block), so it needs its own edge record rather than riding the
# services_edge for_each. The superset.conf vhost includes origin-verify, so the
# bi hostname MUST enter via CloudFront (matched by the `*.${staging_domain}` alias)
# once edge_cutover=true — a direct-to-EIP hit would 403.
resource "aws_route53_record" "bi_edge" {
  count   = var.edge_cutover ? 1 : 0
  zone_id = aws_route53_zone.staging.zone_id
  name    = "bi.${var.staging_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.edge.domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# 5. Outputs
# ══════════════════════════════════════════════════════════════════════════════

output "edge_cloudfront_domain_name" {
  description = "CloudFront distribution domain (the ALIAS target the service records point at when edge_cutover=true)."
  value       = aws_cloudfront_distribution.edge.domain_name
}

output "edge_cloudfront_distribution_id" {
  description = "CloudFront distribution id (for cache invalidations / console lookups)."
  value       = aws_cloudfront_distribution.edge.id
}

output "edge_waf_web_acl_arn" {
  description = "WAFv2 web ACL ARN attached to CloudFront (null when waf_enabled=false)."
  value       = var.waf_enabled ? aws_wafv2_web_acl.edge[0].arn : null
}

output "edge_acm_certificate_arn" {
  description = "ACM certificate ARN (us-east-1) used as the CloudFront viewer certificate."
  value       = aws_acm_certificate.edge.arn
}

output "edge_origin_verify_secret" {
  description = "Shared secret CloudFront sends as X-Origin-Verify; configure nginx to require it (runbook step (c))."
  value       = random_password.origin_verify.result
  sensitive   = true
}
