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
  description = "Graviton3 r7g.large — memory-optimized (16 GB). The DB workload (caggs/comparators, bg workers) OOM'd + swapped on t4g.medium (4 GB); ops upsized out-of-band, now codified so a terraform apply can't silently revert it (2026-08-06)."
  type        = string
  default     = "r7g.large" # 2 vCPU / 16 GB — memory headroom for the DB workload
}

variable "app_instance_type" {
  description = "On-demand Graviton2 — t4g.small saves ~$12/mo vs medium; upgrade if OOM"
  type        = string
  default     = "t4g.large" # 2 vCPU / 8 GB — ~$48/mo; upgraded from t4g.medium: docker compose build of ~10 services OOM/swap-thrashed on 4GB (npm ci ECONNRESET + exit 137). 8GB removes the thrash.
}

variable "db_volume_size_gb" {
  type    = number
  default = 64 # gp3 → $5.12/mo. Grown 32 → 64 in session 64 (was 71% used). Requires SSM-side growpart + xfs_growfs post-apply.
}

variable "app_volume_size_gb" {
  type    = number
  default = 64 # gp3 → $5.12/mo. Grown from 32 → 64 after 2026-06-22 disk-full incident.
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
    api              = 8080
    hasura           = 8081
    grafana          = 3000
    edge-nodered     = 1880
    oeecloud-nodered = 1881  # OEECloud Node-RED (mapped to host port 1881, container port 1880)
    rabbitmq         = 15672 # RabbitMQ management UI
    adminer          = 8082  # PostgreSQL web UI (Adminer)
    operator         = 8083  # Dev operator SPA (Vite + nginx, container port 80)
    csadmin          = 8084  # CS-Admin SPA (staging tier; same image as prod)
  }
}

# Per-vhost oauth2-proxy auth tier, consumed by nginx_setup.sh (ADR-0034 §C).
# Drives which forward-auth block each `services` vhost gets:
#   csadmin           — origin-verify + auth_request /oauth2/auth-csadmin (cs-admin group; admin UIs + node-red editors)
#   any               — origin-verify + auth_request /oauth2/auth (any pool user; operator)
#   api               — origin-verify + cs-admin gate on /, but ~^/api/ bypasses (edge-api x-api-key)
#   none-originverify — origin-verify only, no oauth2 gate (csadmin SPA owns its own login)
# The generic staff-tier loop in nginx_setup.sh emits vhosts for tier "csadmin";
# "api"/"any"/"none-originverify" are emitted as explicit blocks. The
# deliberately-open carve-outs (mq / refdata / cpack-ingest) are NOT in the
# `services` map — they have their own explicit blocks + DNS records. Any service
# absent from this map defaults to the (gated) "csadmin" tier.
variable "service_auth" {
  description = "oauth2-proxy auth tier per nginx vhost (csadmin|any|api|none-originverify)"
  type        = map(string)
  default = {
    api              = "api"
    hasura           = "csadmin"
    grafana          = "csadmin"
    edge-nodered     = "csadmin"
    oeecloud-nodered = "csadmin"
    rabbitmq         = "csadmin"
    adminer          = "csadmin"
    operator         = "any"
    csadmin          = "none-originverify"
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
