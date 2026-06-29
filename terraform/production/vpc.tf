# Production VPC — single public subnet, single EC2 (dry-run phase).
#
# Simpler than staging on purpose:
#   - No private subnet (the only EC2 lives in public; no DB EC2 to isolate).
#   - No NAT instance (no private subnet → nothing to NAT from).
#   - CIDR room reserved (10.20.10.0/24) for a future private subnet if/when
#     we split out the DB.
#
# The single-EC2 design is a deliberate dry-run phase choice. When the
# customer migration brings real workload, the split-out to a 2-EC2
# topology (app public + db private + NAT) is mechanical: add private
# subnet + nat.tf (copied from staging) + a second aws_instance, then
# `terraform apply`.

resource "aws_vpc" "production" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true # required for SSM Session Manager
  enable_dns_support   = true
  tags                 = { Name = "packiot-production" }
}

resource "aws_internet_gateway" "production" {
  vpc_id = aws_vpc.production.id
  tags   = { Name = "packiot-production-igw" }
}

# ── Subnet ─────────────────────────────────────────────────────────────────────

# Public: single EC2 with Nginx + all Docker services + the local empty
# TimescaleDB container. The EC2 has a public EIP for stable DNS.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.production.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.az
  map_public_ip_on_launch = false # we assign the EIP explicitly
  tags                    = { Name = "packiot-production-public" }
}

# ── Route table ────────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.production.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.production.id
  }
  tags = { Name = "packiot-production-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Elastic IP for the app EC2 ─────────────────────────────────────────────────
# EIP is free while attached; $0.005/hr only when unattached.
# Stable IP is essential — Route53 A records for prod.packiot.app point here.

resource "aws_eip" "app" {
  domain = "vpc"
  tags   = { Name = "packiot-production-app-eip" }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}
