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
  description = "Graviton2 app host — upgrade if OOM"
  type        = string
  default     = "t4g.large" # 2 vCPU / 8 GB — ~$48/mo; upgraded from t4g.medium: docker compose build of ~10 services OOM/swap-thrashed on 4GB. 8GB removes the thrash.
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
    csadmin  = 8084 # CS-Admin SPA (Vite + nginx, container port 80)
  }
}

# Per-vhost oauth2-proxy auth tier, consumed by nginx_setup.sh (ADR-0034 §C).
# Drives which forward-auth block each `services` vhost gets:
#   csadmin          — origin-verify + auth_request /oauth2/auth-csadmin (cs-admin group; admin UIs)
#   any              — origin-verify + auth_request /oauth2/auth (any pool user; operator)
#   api              — origin-verify + cs-admin gate on /, but ~^/api/ bypasses (edge-api x-api-key)
#   none-originverify — origin-verify only, no oauth2 gate (csadmin SPA owns its own login)
# The generic staff-tier loop in nginx_setup.sh emits vhosts for tier "csadmin";
# "api"/"any"/"none-originverify" are emitted as explicit blocks. Any service
# absent from this map defaults to the (gated) "csadmin" tier.
variable "service_auth" {
  description = "oauth2-proxy auth tier per nginx vhost (csadmin|any|api|none-originverify)"
  type        = map(string)
  default = {
    api      = "api"
    hasura   = "csadmin"
    grafana  = "csadmin"
    rabbitmq = "csadmin"
    adminer  = "csadmin"
    operator = "any"
    csadmin  = "none-originverify"
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

# ── Dedicated DB EC2 (W6 — split DB off the app box) ──────────────────────────
#
# The production-buildout roadmap (docs/adr/reference/production-buildout-roadmap.md
# §W6) flags the app-box t4g.medium + *local* TimescaleDB container as fatal for
# a real client: TimescaleDB continuous-aggregate refresh is memory-hungry and
# staging already swap-died on the same class. W6.1 splits the DB onto its own
# EC2 in the reserved 10.20.10.0/24 private subnet; W6.2 right-sizes it onto a
# MEMORY-family instance (not t4g). This is the greenfield single-flow F3-native
# DB (ADR-0032): ONE database whose `public` schema *is* the F3 schema — no
# packiot_shadow, no F1/F2 legs, no comparator schemas.
#
# NOTE: config/plan-only. Standing this up + rewiring the compose DATABASE_URL
# from the local container to this instance is the W1 compose-parity follow-up.

variable "private_subnet_cidr" {
  description = "Private subnet for the dedicated DB EC2 — reserved 10.20.10.0/24, no direct internet route (egress via NAT)"
  type        = string
  default     = "10.20.10.0/24"
}

variable "db_instance_type" {
  description = <<-EOT
    Dedicated DB EC2 instance type. MEMORY-family Graviton3 (r7g) — NOT t4g.
    r7g.large = 2 vCPU / 16 GB (arm64, matches the AL2023 arm64 AMI). Bump to
    r7g.xlarge (4 vCPU / 32 GB) if cagg-refresh memory pressure appears under a
    real client's load. r7g is chosen over t-family because TimescaleDB's
    background cagg refresh is a sustained (not bursty) memory+CPU workload —
    burst credits are the wrong model and the staging swap incident proved it.
  EOT
  type        = string
  default     = "r7g.large"
}

variable "db_volume_size_gb" {
  description = "Dedicated DB EC2 gp3 root volume — holds the F3 TimescaleDB data dir + WAL"
  type        = number
  default     = 100
}

variable "db_iops" {
  description = "Provisioned gp3 IOPS for the DB volume (gp3 free baseline is 3000; TimescaleDB WAL+cagg writes benefit from headroom)"
  type        = number
  default     = 4000
}

variable "db_throughput_mbps" {
  description = "Provisioned gp3 throughput MB/s for the DB volume (gp3 free baseline is 125)"
  type        = number
  default     = 250
}

variable "db_private_ip" {
  description = "Static private IP for the DB EC2 in the private subnet (stable target for the app's DATABASE_URL / pgbouncer upstream)"
  type        = string
  default     = "10.20.10.89"
}

# ── Ingest front-door (W2 — ADR-0042 mTLS SparkPlug uplink) ────────────────────
#
# The client-edge bundle (PR #624, ADR-0042 §6) ships a per-tenant sparkplug-agent
# that publishes SparkPlug B over mTLS to `ssl://<ingest-host>:8883`. New-prod is
# the LANDING ZONE for that uplink — a public mosquitto TLS listener that
# terminates mTLS, uses the client cert CN as identity, and a CN-keyed ACL scopes
# each tenant to `spBv1.0/<CN>/#` (ADR-0042 §6: "the client never spells its
# tenant on the wire; the mTLS CN does, and the broker ACL enforces it").
#
# Unlike staging's ADR-0042 P1 path (nginx TLS :8447 → sparkplug-agent HTTP
# /v1/tags), this is a broker-terminated mTLS listener: the SG opens 8883
# straight to mosquitto — nginx is NOT in this path.

variable "ingest_subdomain" {
  description = "Left label of the prod ingest hostname (<ingest_subdomain>.prod.packiot.app → app EIP). The client agent connects ssl://<this>:8883."
  type        = string
  default     = "ingest"
}

variable "ingest_mqtts_port" {
  description = "mTLS SparkPlug uplink port the mosquitto TLS listener binds and the app SG admits (client-edge bundle #624 dials ssl://…:8883)"
  type        = number
  default     = 8883
}

variable "client_ingest_egress_cidrs" {
  description = <<-EOT
    Allow-list of client factory-edge PUBLIC egress /32s permitted to reach the
    8883 mTLS ingest listener. NOT world-open (mirrors staging's CPACK /32 gate),
    just parameterized. Each entry is the client factory's PUBLIC internet egress
    IP (what `curl https://checkip.amazonaws.com` returns FROM the factory box) —
    NOT its private/VPN address (there is no VPN into this VPC; the factory reaches
    prod over the public internet to the EIP). Port stays effectively closed to
    everyone else. ⚠ If a client's ISP egress is DYNAMIC, this /32 breaks on IP
    change — confirm it's static (or re-apply on change).
  EOT
  type        = list(string)
  # CPACK factory public egress /32 (confirmed from the factory box 2026-08-03).
  default = ["179.162.112.58/32"]
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

# ── Dedicated org-level CI runner (ci_runner.tf) ──────────────────────────────
# Separate box from the prod app/db EC2s. Gives the org unlimited free Actions
# minutes (GitHub Free's 2,000-min pool halts CI org-wide when exhausted).
# See docs/ci-selfhosted-runner-runbook.md.

variable "github_org" {
  description = "GitHub org the CI runner registers against at ORG scope (--url https://github.com/<org>)"
  type        = string
  default     = "packiot"
}

variable "ci_runner_instance_type" {
  description = <<-EOT
    CI runner instance type. t3.medium (2 vCPU / 4 GB) MINIMUM — a 2 GB box OOMs
    on the front4 Vite build. x86_64 (t3, NOT t4g) so the AL2023 x86_64 AMI +
    the x64 actions-runner tarball match. Bump to t3.large (8 GB) if builds get
    heavier. Spot is a cost lever (see runbook) — safe here because an
    interruption only kills the in-flight job, which GitHub re-queues.
  EOT
  type        = string
  default     = "t3.medium" # 2 vCPU / 4 GB — ~$30/mo on-demand, ~$9/mo spot
}

variable "ci_runner_volume_size_gb" {
  description = "CI runner gp3 root volume — holds the OS, Docker layer cache, npm cache, and the runner work dir"
  type        = number
  default     = 40 # gp3 → ~$3.20/mo. Docker layers + node_modules churn need headroom.
}

variable "ci_runner_subnet_cidr" {
  description = "Dedicated public subnet for the CI runner — isolated from the prod app (10.20.0.0/24) and DB (10.20.10.0/24) subnets"
  type        = string
  default     = "10.20.20.0/24"
}

variable "ci_runner_version" {
  description = "Pinned actions-runner release (github.com/actions/runner/releases). Bump deliberately; a stale runner still works but nags."
  type        = string
  default     = "2.334.0"
}

variable "ci_runner_labels" {
  description = <<-EOT
    Labels the runner self-registers with. Workflows opt in via
    `runs-on: [self-hosted, linux, packiot-ci]`. Keep `packiot-ci` as the
    discriminator so only workflows that explicitly want THIS runner land on it.
  EOT
  type        = list(string)
  default     = ["self-hosted", "linux", "x64", "packiot-ci"]
}

variable "ci_runner_ephemeral" {
  description = <<-EOT
    If true, the runner registers with --ephemeral (one job then it deregisters,
    for a clean environment per job) — but a NEW registration is needed for the
    next job, so ephemeral requires an auto-reprovision mechanism (JIT config or
    an instance-replace loop). If false (RECOMMENDED for the first long-lived
    runner) the runner stays registered and picks up job after job — simpler,
    at the cost of no per-job isolation. See the runbook's ephemeral trade-off.
  EOT
  type        = bool
  default     = false
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
