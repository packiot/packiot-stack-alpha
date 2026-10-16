# ADR-0064 — staging mirrors production for a tenant after its production go-live.
#
# staging's prod-reflector (compose.staging.yml) reads the PRODUCTION database as the SELECT-only role
# prod_reflector_ro (db/migrations/t-prod-reflector-roles) and converges staging's copy of that tenant every minute.
# The production DB is private (DB SG: 5432 from the production app SG only), so the path is a VPC peering
# staging (10.10.0.0/16) ↔ production (10.20.0.0/16), same account and region, plus exactly one DB ingress: 5432 from
# the staging app EC2's private IP. Nothing else crosses: no route to production's public subnet from staging's
# private one, no other port, and the login is read-only by role (default_transaction_read_only, SELECT grants).
#
# OFF by default (staging_mirror_enabled = false → zero resources, plan = no-op). Turn on at T-1 of the go-live:
#   1. terraform apply here with -var staging_mirror_enabled=true        (peering + prod route + DB SG rule)
#   2. terraform/staging apply with -var prod_mirror_peering_id=<output staging_mirror_peering_id>  (staging route)
# Rollback: the reverse (staging var empty, then this var false).

data "aws_vpc" "staging_mirror" {
  count = var.staging_mirror_enabled ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [var.staging_mirror_vpc_name]
  }
}

resource "aws_vpc_peering_connection" "staging_mirror" {
  count       = var.staging_mirror_enabled ? 1 : 0
  vpc_id      = aws_vpc.production.id
  peer_vpc_id = data.aws_vpc.staging_mirror[0].id
  auto_accept = true # same account + region
  tags        = { Name = "packiot-production-staging-mirror" }
}

output "staging_mirror_peering_id" {
  description = "VPC peering id for terraform/staging var prod_mirror_peering_id (ADR-0064); empty when off"
  value       = var.staging_mirror_enabled ? aws_vpc_peering_connection.staging_mirror[0].id : ""
}
