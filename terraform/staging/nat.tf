# fck-nat — single t4g.nano acting as NAT for the private subnet.
# Cost: ~$3/mo vs $33/mo for AWS Managed NAT Gateway.
# Production upgrade path: delete this module and add aws_nat_gateway + EIP.
#
# Source: https://github.com/AndrewGuenther/fck-nat (MIT)

module "fck_nat" {
  source  = "AndrewGuenther/fck-nat/aws"
  version = "~> 1.3.0"

  name      = "packiot-staging-nat"
  vpc_id    = aws_vpc.staging.id
  subnet_id = aws_subnet.public.id

  # Allow all VPC-internal traffic to route through the NAT instance.
  # The fck-nat AMI handles iptables MASQUERADE internally.
  ha_mode        = false # single instance for staging
  use_default_sg = false
}
