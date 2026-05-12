resource "aws_vpc" "staging" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true # required for SSM Session Manager
  enable_dns_support   = true
  tags                 = { Name = "packiot-staging" }
}

resource "aws_internet_gateway" "staging" {
  vpc_id = aws_vpc.staging.id
  tags   = { Name = "packiot-staging-igw" }
}

# ── Subnets ────────────────────────────────────────────────────────────────────

# Public: App EC2 (Nginx + all Docker services) and fck-nat.
# App EC2 has a public EIP; fck-nat has its own public IP.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.staging.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.az
  map_public_ip_on_launch = false # we assign EIPs explicitly
  tags                    = { Name = "packiot-staging-public" }
}

# Private: DB EC2 only. No inbound from internet; egress via fck-nat.
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.staging.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.az
  tags              = { Name = "packiot-staging-private" }
}

# ── Route tables ───────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.staging.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.staging.id
  }
  tags = { Name = "packiot-staging-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private route: 0.0.0.0/0 → NAT instance ENI.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.staging.id
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }
  tags = { Name = "packiot-staging-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── Elastic IP for App EC2 ─────────────────────────────────────────────────────
# EIP is free while attached; $0.005/hr only when unattached.
# A static IP is important because Route53 A records point to it.

resource "aws_eip" "app" {
  domain = "vpc"
  tags   = { Name = "packiot-staging-app-eip" }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}
