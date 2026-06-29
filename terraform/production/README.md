# terraform/production/

Production environment Terraform workspace. **Status: WIP — foundation files only.**

Companion to [`terraform/staging/`](../staging/). Built on the staging template; differences documented in [ADR-0003](../../docs/adr/0003-production-deployment-parent-stack.md).

## Current state (as of 2026-06-29 — Phase 1A COMPLETE)

| File | Status | Notes |
|---|---|---|
| `main.tf` | ✅ Done | Provider, backend (values via `tf-init`), default tags |
| `variables.tf` | ✅ Done | All inputs with documented defaults + sizing rationale |
| `vpc.tf` | ✅ Done | Single public subnet (no private, no NAT — dry-run design) |
| `ec2.tf` | ✅ Done | Single `aws_instance.app` (`t4g.medium`) + IAM role + EBS + CloudWatch disk alarm |
| `security_groups.tf` | ✅ Done | Single SG (HTTP/HTTPS/SSH ingress); no db-app pair, no AMQPS |
| `secrets.tf` | ✅ Done | `packiot/production/*` namespace, 7 secrets, 7-day recovery window |
| `dns.tf` | ✅ Done | Route53 zone `prod.packiot.app` + per-service A records + Authentik vhost |
| `backups.tf` | ✅ Done | S3 bucket for future pg_dump (zero objects in dry-run) + IAM writer on app role |
| `snapshots.tf` | ✅ Done | AWS Backup vault + plan, daily snapshots, 30-day retention |
| `outputs.tf` | ✅ Done | EIP, NS records, service URLs, SSM connect, runner activation, cost estimate |
| `user_data/app_bootstrap.sh` | ✅ Done | Tiny user_data script (fetches app_init.sh from S3 at first boot) |
| `user_data/app_init.sh` | ✅ Done | The heavy lifter — adapted from staging, drops db-EC2 refs, uses local postgres via pgbouncer, no Node-RED secrets, production branch + compose |
| `user_data/nginx_setup.sh` | ✅ Done | Adapted from staging — ACM certs for `prod.packiot.app`, vhost configs, no AMQPS / no mq.* vhost |

**`terraform plan` SHOULD work now**, assuming the parent hosted zone `packiot.app` exists in this AWS account.

## What's still pending (separate PRs)

| Item | PR | Status |
|---|---|---|
| `compose.production.yml` | #92 (planned) | Pending — Phase 1B |
| `.github/workflows/deploy-production.yml` + OIDC IAM | #93 (planned) | Pending — Phase 1C/1D |
| `db/seed-production-dryrun-schema.sql` | — | Deferred — see `project_tsp12_pgdump_blocked.md` memory; using staging-style migrations instead |

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
