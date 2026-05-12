# ── Region / AZ ───────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "az" {
  description = "Single AZ for staging (multi-AZ is a production upgrade)"
  type        = string
  default     = "us-east-1c"
}

# ── Network ────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "VPC CIDR — must not overlap existing VPCs in the account"
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet (App EC2 + fck-nat) — internet-facing, no private IPs routed here"
  type        = string
  default     = "10.10.0.0/24"
}

variable "private_subnet_cidr" {
  description = "Private subnet (DB EC2) — no direct internet route, egress via fck-nat"
  type        = string
  default     = "10.10.10.0/24"
}

# ── EC2 ────────────────────────────────────────────────────────────────────────

variable "db_instance_type" {
  description = "t4g = Graviton2 (ARM, ~20% cheaper than t3 equivalent)"
  type        = string
  default     = "t4g.medium" # 2 vCPU / 4 GB — $24/mo on-demand
}

variable "app_instance_type" {
  description = "On-demand Graviton2 — t4g.small saves ~$12/mo vs medium; upgrade if OOM"
  type        = string
  default     = "t4g.small" # 2 vCPU / 2 GB — ~$12/mo on-demand
}

variable "db_volume_size_gb" {
  type    = number
  default = 20 # gp3: $0.08/GB/mo → $1.60/mo
}

variable "app_volume_size_gb" {
  type    = number
  default = 20 # gp3 → $1.60/mo; on-box Docker builds need headroom for images/layers
}

# ── DNS / Domain ───────────────────────────────────────────────────────────────

variable "staging_domain" {
  description = "Route53 hosted zone for staging services."
  type        = string
  default     = "staging.packiot.app"
}

# Services exposed via Nginx — each gets <service>.staging.packiot.com
variable "services" {
  description = "Nginx virtual-host names; each maps to a local Docker port"
  type        = map(number)
  default = {
    api      = 8080
    hasura   = 8081
    grafana  = 3000
    nodered  = 1880
    rabbitmq = 15672 # RabbitMQ management UI
  }
}

# ── Database ───────────────────────────────────────────────────────────────────

variable "db_name" {
  type    = string
  default = "packiot"
}

variable "db_user" {
  type    = string
  default = "postgres"
}

# ── SSH access ────────────────────────────────────────────────────────────────

variable "ops_ssh_public_key" {
  description = "SSH public key for emergency/debug access to EC2 instances"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGa1heG3kozz4jYnkqPmV1oSZ/XarVFWqRb9ZfUv9VA epodesta158@gmail.com"
}

# ── GitHub Actions runner ──────────────────────────────────────────────────────

variable "github_repo" {
  description = "org/repo the self-hosted runner registers against"
  type        = string
  default     = "packiot/packiot-stack-alpha"
}
