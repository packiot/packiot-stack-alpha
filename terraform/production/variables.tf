# ── Region / AZ ───────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all production resources (matches staging today; can split later)"
  type        = string
  default     = "us-east-1"
}

variable "az" {
  description = "Single AZ for production-dryrun (multi-AZ HA is a phase-3 upgrade once writes are cut over)"
  type        = string
  default     = "us-east-1c"
}

# ── Network ────────────────────────────────────────────────────────────────────
#
# Production VPC CIDR is deliberately 10.20.0.0/16 — non-overlapping with:
#   - staging  10.10.0.0/16
#   - legacy AWS default VPCs (typically 172.31.0.0/16)
# Leaves room to add private subnet + 2nd EC2 (when we split out DB) without
# CIDR conflict; reserved space documented for future engineering.

variable "vpc_cidr" {
  description = "VPC CIDR — must not overlap existing VPCs in the account"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet — single EC2 (all services) + future fck-nat if/when we split"
  type        = string
  default     = "10.20.0.0/24"
}

# Reserved for future use:
#   10.20.10.0/24 — private subnet (if we split out DB to its own EC2)
# Not provisioned today (single-EC2 dry-run architecture).

# ── EC2 ────────────────────────────────────────────────────────────────────────
#
# Single-instance design for the dry-run phase.
# Empirical sizing from staging (which runs the same compose stack minus
# the local TimescaleDB, edge-nodered, and simulator — both excluded here):
# staging on t4g.medium (4 GB) sits at ~2.7 GB used + 760 MB swap. Without
# edge-nodered (~400 MB) + simulator (~100 MB) + the local TimescaleDB
# being EMPTY (no real workload), we're well within t4g.medium's envelope.
# Bump to t4g.large later if observability stack memory creeps up.

variable "app_instance_type" {
  description = "Single t4g.medium handles the full dry-run stack — see sizing comment above"
  type        = string
  default     = "t4g.medium" # 2 vCPU / 4 GB — ~$24/mo on-demand
}

variable "app_volume_size_gb" {
  description = "Single EBS volume holds all containers + the local empty TimescaleDB + logs"
  type        = number
  default     = 64 # gp3 → $5.12/mo. Matches staging app EC2.
}

# ── DNS / Domain ───────────────────────────────────────────────────────────────

variable "production_domain" {
  description = "Route53 subdomain for production services (symmetric with staging.packiot.app)"
  type        = string
  default     = "prod.packiot.app"
}

# Services exposed via Nginx — each gets <service>.prod.packiot.app
# Same shape as staging's `services` map.
# Edge-nodered + oeecloud-nodered + simulator deliberately ABSENT — those
# are not part of the production-side compose (per the deployment scope:
# edge-nodered runs per-factory; oeecloud-nodered is decommissioned; the
# simulator is a staging-only synthetic PLC).
variable "services" {
  description = "Nginx virtual-host names; each maps to a local Docker port"
  type        = map(number)
  default = {
    api      = 8080
    hasura   = 8081
    grafana  = 3000
    rabbitmq = 15672
    adminer  = 8082
    operator = 8083
  }
}

# ── Database (LOCAL container only — for dry-run boot) ─────────────────────────
#
# This DB is the local empty TimescaleDB on the same EC2, used purely so the
# stack can boot + healthcheck against a real schema. The real prod DB
# (tsp12-*) is NOT connected from this stack in phase 1. Phase 2 will swap
# the connection string to point at tsp12 via Secrets Manager.

variable "db_name" {
  description = "Database name for the local prod-dryrun postgres container"
  type        = string
  default     = "packiot"
}

variable "db_user" {
  description = "Superuser for the local prod-dryrun postgres container"
  type        = string
  default     = "postgres"
}

# ── SSH access ────────────────────────────────────────────────────────────────

variable "ops_ssh_public_key" {
  description = "SSH public key for emergency/debug access (mirrors staging's key for now; rotate per-env later)"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGa1heG3kozz4jYnkqPmV1oSZ/XarVFWqRb9ZfUv9VA epodesta158@gmail.com"
}

# ── GitHub Actions runner ──────────────────────────────────────────────────────

variable "github_repo" {
  description = "org/repo the self-hosted runner registers against"
  type        = string
  default     = "packiot/packiot-stack-alpha"
}

variable "runner_labels" {
  description = "Labels applied when the runner self-registers — must match deploy-production.yml's runs-on"
  type        = list(string)
  default     = ["self-hosted", "production", "linux", "arm64"]
}

# ── Backup retention ──────────────────────────────────────────────────────────
#
# Longer retention than staging (7d) because the prod-dryrun env will
# eventually carry real customer data (post phase-3 cutover). Cheap to
# extend now and avoid re-engineering the backup plan later.

variable "ec2_backup_retention_days" {
  description = "AWS Backup retention for the production EC2's EBS snapshots"
  type        = number
  default     = 30
}
