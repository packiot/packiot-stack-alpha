# terraform/production/

Production environment Terraform workspace. **Status: WIP — foundation files only.**

Companion to [`terraform/staging/`](../staging/). Built on the staging template; differences documented in [ADR-0003](../../docs/adr/0003-production-deployment-parent-stack.md).

## Current state (as of 2026-06-29)

| File | Status | Notes |
|---|---|---|
| `main.tf` | ✅ Done | Provider, backend (values via `tf-init`), default tags |
| `variables.tf` | ✅ Done | All inputs with documented defaults + sizing rationale |
| `vpc.tf` | ✅ Done | Single public subnet (no private, no NAT — dry-run design) |
| `ec2.tf` | ⏳ Next session | Will reference `aws_instance.app` already used in vpc.tf |
| `security_groups.tf` | ⏳ Next session | Simpler than staging (no db-app SG pair needed) |
| `secrets.tf` | ⏳ Next session | `packiot/production/*` namespace |
| `dns.tf` | ⏳ Next session | Route53 records for `prod.packiot.app` |
| `backups.tf` | ⏳ Next session | S3 bucket for the local-DB pg_dump pipeline |
| `snapshots.tf` | ⏳ Next session | AWS Backup, 30d retention |
| `outputs.tf` | ⏳ Next session | EIP, SSM connect strings, runner registration hint |

**Do NOT run `terraform plan` against this workspace until all files land** — `vpc.tf` references `aws_instance.app` from the not-yet-written `ec2.tf`.

## Design summary

Per [ADR-0003 + the 2026-06-29 dry-run conversation](../../docs/adr/0003-production-deployment-parent-stack.md):

- **Single EC2** (`t4g.medium`, ~$24/mo) — all services + local empty TimescaleDB
- **No mirror-worker-go, no simulator, no edge-nodered** in `compose.production.yml`
- **No real prod DB connection** (the existing `tsp12-*` is NOT configured) — dry-run boot only
- **Same AWS account as staging** (`639178078294`) — separate VPC + Secrets Manager namespace
- **Single public subnet** (`10.20.0.0/24` in VPC `10.20.0.0/16`) — no private subnet, no NAT
- **`prod.packiot.app`** as the domain (symmetric with `staging.packiot.app`)

When the customer migration date is set, the upgrade path to a 2-EC2 topology (split out the DB) is mechanical — add `private_subnet_cidr`, `nat.tf`, a second `aws_instance.db`, and `terraform apply`.

## Cost envelope

```
t4g.medium EC2:           ~$24/mo
64 GB EBS gp3:            ~$5/mo
Route53 hosted zone:       ~$0.50/mo
ACM cert:                  free
Secrets Manager (~7):      ~$2.80/mo
AWS Backup (30d retain):  ~$5/mo
                          ────────
Total:                    ~$37/mo
```

(Compare staging at ~$36/mo for similar resources.)

## How to bootstrap (when the rest of the files land)

```bash
# One-time per developer:
cd terraform/production/
make tf-init    # writes backend.tfvars pointing at packiot-terraform-state-639178078294 / production/terraform.tfstate

# Verify before applying:
terraform plan

# Provision (will take ~5 min for EC2 + 30s for everything else):
terraform apply
```

The `Makefile` targets for production (`tf-plan-production`, `tf-apply-production`, etc.) will be added in a follow-up alongside the rest of the .tf files.
