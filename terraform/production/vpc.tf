# Production VPC — public subnet (app EC2 + NAT) + private subnet (DB EC2).
#
# W6 of the production-buildout roadmap split the DB onto its own instance:
#   - Public subnet: app EC2 (Nginx + service plane) + the NAT instance.
#   - Private subnet: the dedicated DB EC2 (database.tf), reachable only from
#     the app SG; egress via the NAT instance (nat.tf).
#   - The private subnet uses the 10.20.10.0/24 space variables.tf always
#     reserved for exactly this split.
#
# Until the compose DATABASE_URL is repointed (W1 compose-parity follow-up), the
# app box still runs its local TimescaleDB container; the DB EC2 is the
# right-sized target it migrates onto. config/plan-only — nothing applied.

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

# Private: dedicated DB EC2 (W6). No inbound from internet; egress via the NAT
# instance (nat.tf). Uses the reserved 10.20.10.0/24 space that variables.tf
# always documented for the DB split.
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.production.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.az
  tags              = { Name = "packiot-production-private" }
}

# ── Route tables ───────────────────────────────────────────────────────────────

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

# Private route: 0.0.0.0/0 → NAT instance ENI (nat.tf). The DB EC2 has no public
# IP; this is its only path to OS updates / SSM / Docker Hub / Secrets Manager.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.production.id
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }
  tags = { Name = "packiot-production-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
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
