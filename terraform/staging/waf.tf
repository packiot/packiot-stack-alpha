# WAF v2 Web ACL attached to the CloudFront distribution.
# scope = CLOUDFRONT is valid only in us-east-1 — our primary provider region.
#
# Three layers of protection:
#   1. AWSManagedRulesCommonRuleSet      — OWASP Top 10 (SQLi, XSS, bad requests)
#   2. AWSManagedRulesAmazonIpReputationList — known botnets, scanners, Tor exit nodes
#   3. RateLimit                         — 2000 requests/5 min/IP (brute-force / DoS)
#
# All rules use COUNT override during the first week if you want to tune before blocking;
# switch override_action to `none {}` to enforce once you've reviewed CloudWatch metrics.

resource "aws_wafv2_web_acl" "staging" {
  name        = "packiot-staging-waf"
  description = "Packiot staging — CloudFront WAF"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "CommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "PackiotStagingCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "IpReputationList"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "PackiotStagingIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimit"
    priority = 30

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "PackiotStagingRateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "PackiotStagingWAF"
    sampled_requests_enabled   = true
  }
}
