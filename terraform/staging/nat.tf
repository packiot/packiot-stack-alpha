# NAT instance — single t4g.nano providing egress for the private subnet.
# Cost: ~$3/mo (t4g.nano spot) vs $33/mo for AWS Managed NAT Gateway.
# Production upgrade path: replace aws_instance.nat + aws_route in vpc.tf
# with aws_nat_gateway + an EIP.
#
# This replicates fck-nat behaviour (github.com/AndrewGuenther/fck-nat) without
# the module dependency: ip_forward sysctl + iptables MASQUERADE on ens5.
# source_dest_check = false is the critical flag — without it, the hypervisor
# drops forwarded packets because their source IP doesn't match the instance.
# NOTE: AL2023 Graviton (t4g) uses ens5, not eth0. iptables is not pre-installed
# on AL2023 — install iptables-nft before adding masquerade rules.

resource "aws_security_group" "nat" {
  name        = "packiot-staging-nat"
  description = "Allow VPC-internal traffic through the NAT instance"
  vpc_id      = aws_vpc.staging.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
    description = "VPC internal"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "packiot-staging-nat" }
}

resource "aws_instance" "nat" {
  # Reuse the AL2023 ARM64 AMI already defined in ec2.tf.
  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = "t4g.nano" # 2 vCPU / 0.5 GB — plenty for NAT
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nat.id]
  associate_public_ip_address = true

  # CRITICAL: disables the hypervisor check that drops packets whose source IP
  # doesn't match the instance's own IP — required for any forwarding/NAT role.
  source_dest_check = false

  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    # Enable kernel IP forwarding.
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-nat.conf
    sysctl -p /etc/sysctl.d/99-nat.conf
    # Install iptables BEFORE adding rules — AL2023 ships with nftables only.
    # iptables-nft provides the iptables CLI backed by nftables.
    dnf install -y iptables-nft iptables-services
    # AL2023 Graviton (ENA): interface is ens5, not eth0.
    iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
    # Persist across reboots.
    service iptables save
    systemctl enable iptables
  USERDATA
  )

  tags = { Name = "packiot-staging-nat" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
