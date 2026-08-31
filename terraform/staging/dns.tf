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
#
# Edge cutover (edge.tf, var.edge_cutover): when the flag is FALSE (default) this
# stays the live path — A → EIP, exactly as before. When TRUE, the for_each goes
# empty and the parallel `aws_route53_record.services_edge` (edge.tf) takes over
# with ALIAS → CloudFront. One variable flips the whole service plane.
resource "aws_route53_record" "services" {
  for_each = var.edge_cutover ? {} : var.services
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

# RETIRED (infra audit 2026-08-23): mq.staging.packiot.app — the RabbitMQ
# management HTTP proxy vhost. The ungated console was closed in PR #876 and the
# nginx server block for `mq.staging` was removed (only rabbitmq.staging remains,
# oauth2-gated). The A record served no live nginx vhost (edges publish over
# AMQPS:5671 / cpack-ingest:8447), so the dangling record + its exposed hostname
# were deleted from Route53 and this resource removed. Do NOT reintroduce an
# ungated management vhost — go through rabbitmq.staging (cs-admin oauth2 gate).

# Authentik SSO login page — browser entry point for all staging SSO flows.
# No Nginx auth_request on this vhost (it IS the authentication endpoint).
resource "aws_route53_record" "auth" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = "auth.${var.staging_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}

# Superset BI vhost — bi.staging.packiot.app. NOT in var.services because it uses a
# bespoke nginx block (superset.conf: origin-verify + scoped CORS, NO oauth2 gate —
# a cookie forward-auth would break the iframe embed + Cognito OIDC redirect), not
# the generic csadmin-tier vhost loop. Mirrors the services record's edge_cutover
# flip: A→App EIP while direct; goes dormant (count 0) when the parallel
# ALIAS→CloudFront copy `bi_edge` (edge.tf) takes over. `bi` already matches the
# distribution's `*.staging.packiot.app` alias, so no cert/alias change is needed.
resource "aws_route53_record" "bi" {
  count   = var.edge_cutover ? 0 : 1
  zone_id = aws_route53_zone.staging.zone_id
  name    = "bi.${var.staging_domain}"
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

# bispharma agent ingest front-door — bispharma-ingest.staging.packiot.app.
# Dedicated port-8448 TLS reverse-proxy for sparkplug-agent-bispharma /v1/tags
# (mirror of cpack_ingest above). Nginx on the App EC2 terminates TLS; the App
# EC2 SG admits 8448 from the bispharma box egress /32 only (security_groups.tf).
resource "aws_route53_record" "bispharma_ingest" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = "bispharma-ingest.${var.staging_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}

# barcode-service box-scan ingest — scan.staging.packiot.app.
# Not in var.services because that map's vhosts get the oauth2-proxy SSO gate;
# barcode-service does its OWN fail-closed Cognito-JWT auth (tenant from the
# signed custom:id_enterprise claim), so it needs the "deliberately open, own
# auth" vhost in nginx_setup.sh (scan.conf) — same posture as refdata. Direct
# A-record to the App EC2 EIP; nginx terminates TLS on 443 and reverse-proxies
# the exact /v1/scans paths to barcode-service (172.18.0.36:8446). 443 is already
# open to 0.0.0.0/0 in the App EC2 SG (the JWT is the gate, not the SG).
resource "aws_route53_record" "scan" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = "scan.${var.staging_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}
