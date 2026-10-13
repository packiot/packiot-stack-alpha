---
title: Terraform
layer: 3
owner_area: platform
last_verified: 2026-09-28
---
# Terraform

> **Layer 3 · Components** — the AWS infrastructure-as-code under `terraform/`: what each
> file creates, where state lives, how to plan and apply without hurting a live environment.
> For anyone changing AWS resources. Up: [Platform & operations](../subsystems/platform.md)

## Responsibility

Terraform is accountable for the AWS resources the stack runs on: network, EC2 hosts and their
IAM, DNS, the CloudFront/WAF edge, Cognito, Secrets Manager entries, backup buckets and plans,
and the historian's S3/Glue/Athena pieces. It does **not** deploy containers (that is
[CI/CD](ci-cd.md)) and it does not manage what happens on a host after first boot.

## At a glance

| Item | Value |
|---|---|
| Roots | `terraform/staging` (reference template), `terraform/production` (forked per ADR-0003) |
| Module | `terraform/modules/lakehouse` — ADR-0041 scaffold, **not referenced by any root** |
| Run-once | `terraform/staging/bootstrap` — creates the S3 state bucket (its own local state, gitignored) |
| Versions | Terraform `>= 1.10` (S3-native locking); providers `hashicorp/aws ~> 5.0`, `random ~> 3.6`, `archive ~> 2.4` |
| Region | `us-east-1`; an aliased `aws.us_east_1` provider pins CloudFront certs and WAF |
| Account | one AWS account holds staging and new-stack production (separate VPCs, secret prefixes, domains) |
| State backend | partial `backend "s3" {}`; bucket `packiot-terraform-state-<account-id>`, keys `staging/terraform.tfstate` and `production/terraform.tfstate`, `use_lockfile=true`, `encrypt=true` |
| Default tags | `Project=packiot`, `Environment=<env>`, `ManagedBy=terraform` |
| AMI | latest Amazon Linux 2023 arm64 (data source); instances ignore AMI drift |

## Inputs & outputs

Inputs: `variables.tf` defaults (no `.tfvars` is committed), plus `-var` overrides at plan
time. Outputs (`outputs.tf`): app EIP, DB private IP, Route53 name servers, service URLs,
SSM connect commands, runner next-steps, Cognito pool/client/issuer/JWKS, CloudFront
distribution id and domain, WAF ARN, historian bucket/Glue DB/Athena workgroup, a monthly cost
estimate. `edge_origin_verify_secret` is `sensitive`.

## Internal design

### Boot model (why hosts are "cattle")

EC2 `user_data` is a tiny bootstrapper (`user_data/*_bootstrap.sh`) that downloads the real
init script from S3 (`aws_s3_object.app_init`, `nginx_setup`, `db_init`; user_data has a
16 KB limit). `app_init.sh` installs Docker, nginx, certbot, Go, the SSM agent and the
GitHub runner, fetches secrets, writes `/opt/packiot/.env` (only if absent), clones the repo
to `/opt/packiot/stack`, and runs `docker compose up`. Instances carry
`lifecycle { ignore_changes = [ami, user_data] }`, so **editing an init script never changes a
running host**; it only affects a replacement.

### terraform/staging, by file

| File | Creates |
|---|---|
| `main.tf` | providers (default + `us_east_1` alias), S3 backend stub, caller/region data |
| `variables.tf` | sizing and names: VPC `10.10.0.0/16`, public `10.10.0.0/24`, private `10.10.10.0/24`, AZ `us-east-1c`; app `t4g.large` 64 GB; DB `r7g.large` 128 GB; domain `staging.packiot.app`; `services` vhost→port map; `service_auth` tier map |
| `vpc.tf` | VPC, IGW, subnets, route tables, app EIP + association |
| `nat.tf` | `t4g.nano` NAT instance (fck-nat-style MASQUERADE) + SG |
| `security_groups.tf` | app SG: 80, 443 (world, or CloudFront prefix list when `edge_origin_lock`), 5671 and 8447 (CPACK egress /32), 8449 (per-box /32 allowlist), 3101/3102 (from DB SG); DB SG: 5432 from app SG only |
| `ec2.tf` | S3 init objects, IAM roles/policies/profiles for app and DB (`app_custom` statements: read/write staging secrets, read init scripts, certbot DNS challenge, CloudWatch metrics, CS-Admin Cognito user management, SSM SendCommand to the shared agent; other policies such as edge SSM control and historian write are attached separately), key pair, `aws_instance.db` (private IP `10.10.10.89`), `aws_instance.app` (tag `managed-by=packiot-edge-api`, required by edge-api's SendCommand policy), CloudWatch `app_disk_used_percent` alarm |
| `secrets.tf` | `packiot/staging/{db,hasura,app,agent-ingest,nodered-auth,nginx-auth,authentik,github-runner,ec2-rescue}` with generated passwords; `recovery_window_in_days = 0` |
| `dns.tf` | child zone `staging.packiot.app` delegated from `packiot.app`; per-service A records (only when `edge_cutover=false`); `amqp`, `auth`, `bi`, `cpack-ingest`, `ingest`, `scan` records |
| `edge.tf` | ACM wildcard cert + validation, WAFv2 web ACL (rate limit + managed groups), CloudFront distribution (CachingDisabled, AllViewer), `origin` record, ALIAS records for services, `bi`, `operator-sbx`, `operator-bispharma` (an `import {}` block adopts the hand-made `operator-sbx` record) |
| `cognito.tf` | user pool `packiot-staging` (custom attrs `id_enterprise`, `firebase_uid`), client `front4-amplify`, hosted-UI domain, `oauth2-proxy-*` clients |
| `cognito_migration_lambda.tf` | JIT user-migration Lambda (Firebase → Cognito) + `packiot/staging/firebase-web-api-key` secret |
| `appsync.tf` | near-empty Cognito-authed GraphQL API (`_ping` only) + dev API key |
| `historian.tf` | bucket `packiot-staging-historian-<account>`, lifecycle, Glue DB `packiot_historian_staging` with `equipment_values` / `equipment_events` / `production_orders` tables, Athena workgroup, write policy for the app role |
| `historian-gateway.tf` | IAM user `svc-historian-gateway` with read-only policy `historian-ro` (static key, rotated by `scripts/rotate-historian-s3-key.sh`) |
| `backups.tf` | bucket `packiot-staging-db-backups-<account>`, lifecycle guard, writer policy |
| `snapshots.tf` | AWS Backup vault + plan (daily 03:00 UTC, delete after 7 days) selecting the app EC2 |
| `outputs.tf` | see above |
| `scripts/` | DB backup/restore scripts and `packiot-db-backup.{service,timer}` for the DB host |
| `user_data/` | `app_bootstrap.sh`, `app_init.sh`, `nginx_setup.sh`, `db_bootstrap.sh`, `db_init.sh` |
| `EDGE-PROTECTION-RUNBOOK.md` | staged CloudFront/WAF rollout |

Current edge settings in `edge.tf`: `edge_cutover = true` (since 2026-08-05),
`waf_managed_rules_mode = "block"`, `waf_rate_limit = 2000`, `edge_origin_lock = false`,
`PriceClass_100`, no geo restriction.

### terraform/production, by file

Same shape as staging with prod sizing and `prod.packiot.app`:

| File | Creates / differs |
|---|---|
| `variables.tf` | VPC `10.20.0.0/16`; app `t4g.large`; DB `r7g.large` at `10.20.10.89`; runner labels `self-hosted,production,linux,arm64` |
| `database.tf` | dedicated DB EC2 + IAM + disk alarm + AWS Backup selection |
| `ec2.tf`, `vpc.tf`, `nat.tf`, `security_groups.tf`, `dns.tf`, `edge.tf`, `backups.tf`, `snapshots.tf` | as staging; `edge.tf` adds a `dash.packiot.app` record |
| `secrets.tf` | `packiot/production/{db,hasura,app,rabbitmq-oeecloud-creds,rabbitmq-edge-transformer-creds,refdata-query-keys,nginx-auth,authentik,github-runner,ec2-rescue}` (7-day recovery). A comment documents a durability gap: the DB `host` in the secret is not reconciled if the DB instance is replaced |
| `oidc.tf` | IAM role for GitHub OIDC, trust scoped to this repo + `production` branch/dispatch (reuses the account's existing OIDC provider) |
| `github_runner.tf` | `packiot-production-github-runner` box + `github-runner-pat` secret |
| `ci_runner.tf` | `packiot-ci-runner` (x64, labels `packiot-ci`) + `packiot/production/ci-runner-github-pat` |

!!! warning "The `production` branch is authoritative for production Terraform"
    On 2026-09-28, `origin/production:terraform/production/` contains `bi_edge.tf`,
    `historian.tf` and `superset.tf`, which are **not** on `staging`/`main`; `staging` has
    `ci_runner.tf`, which `production` does not. Planning prod from the wrong branch shows
    destroys of live resources. Run production Terraform only from a worktree of
    `origin/production`.

### modules/lakehouse

S3 lake bucket `packiot-lake-<env>`, Glue databases `bronze`/`gold`, Athena workgroup with a
bytes-scanned cap. Scaffold only (ADR-0041 P0); activation would add a `module "lakehouse"`
block in a root. Merging changes here provisions nothing.

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `app_instance_type` / `db_instance_type` | `t4g.large` / `r7g.large` | host sizing (codified after out-of-band upsizes) |
| `app_volume_size_gb` / `db_volume_size_gb` | 64 / 128 | EBS size; **never lower** (EBS cannot shrink) |
| `edge_cutover` | `true` (staging) | service DNS via CloudFront instead of the EIP |
| `edge_origin_lock` | `false` | restrict 443 to the CloudFront prefix list |
| `waf_managed_rules_mode` | staging `block`; production default `count` | managed rule groups enforce or only count |
| `services`, `service_auth` | see `variables.tf` | nginx vhosts and their oauth2 tier (consumed by `nginx_setup.sh` at first boot) |
| `github_repo` | `packiot/packiot-stack-alpha` | runner registration target |

## Data & invariants

- Instances: `ignore_changes = [ami, user_data]` (+ `associate_public_ip_address` on app).
  Root volumes `delete_on_termination = false`.
- Secrets: every `aws_secretsmanager_secret_version` has `ignore_changes = [secret_string]`.
  Terraform creates the first value; later values set by CLI stick, and a new key added to
  the Terraform JSON **does not** reach an existing secret.
- The DB host is on-demand (spot interruption during a write can corrupt WAL).
- Security-group descriptions must be ASCII (an em dash fails with `InvalidParameterValue`).

## Observability

CloudWatch alarm `app_disk_used_percent` (and `db_disk_used_percent` in production); AWS
Backup job history; `terraform plan` itself is the drift detector.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Planned destroy of live resources | plan shows `destroy` of boxes/DNS | resources were `-target`-applied from uncommitted config (Superset box 2026-08-10, historian 2026-08-12) | commit the config, re-plan to 0 destroy; never `-target`-create without committing in the same change |
| Silent downsize | DB instance type reverted | `-target` apply touched an out-of-band upsize | sizes now codified; read the **full** plan |
| Phantom WAF diff on prod | block→count change in plan | planning prod with default `waf_managed_rules_mode` | plan prod with `-var 'waf_managed_rules_mode=block'`; never apply without it |
| "Provider configuration not present" | plan errors on WAF/ACM | stale branch missing `edge.tf` / the `us_east_1` alias | plan from the right branch |
| Hand-made record conflicts | create fails "already exists" | resource created in console/CLI | `import {}` block (see `operator_tenant_edge`) |
| New secret key never appears on host | service missing a var | `ignore_changes` + `.env` never regenerated | add to the live secret by CLI and append to `/opt/packiot/.env` (or a deploy self-heal step) |

## Operating it

Safe plan/apply (staging):

```bash
make tf-init            # init with -backend-config bucket/key/region/use_lockfile/encrypt
make tf-plan            # = cd terraform/staging && terraform plan
# read EVERY line; stop on any destroy/replace of aws_instance, aws_route53_*, aws_security_group*,
# aws_cloudfront_distribution, aws_s3_bucket you did not intend
terraform -chdir=terraform/staging plan -out=tfplan   # save the reviewed plan
terraform -chdir=terraform/staging apply tfplan      # apply exactly what you reviewed
```

Production:

```bash
git worktree add ../prod-tf origin/production
cd ../prod-tf/terraform/production
terraform init -backend-config="bucket=packiot-terraform-state-<account-id>" \
  -backend-config="key=production/terraform.tfstate" -backend-config="region=us-east-1" \
  -backend-config="use_lockfile=true" -backend-config="encrypt=true"
terraform plan -var 'waf_managed_rules_mode=block'
```

Rules: prefer committing config then a full apply over `-target`; use `-target` only to
sequence inside already-committed config; codify every CLI change (or import it); growing a
volume is done with `aws ec2 modify-volume` + on-host `growpart`/`xfs_growfs`, then the
variable is raised to match.

## Tests

`make tf-validate` (runs `terraform fmt -recursive` + `terraform validate` on staging). There is
no CI job that plans Terraform.

## Source map

| Path | What's there |
|---|---|
| `terraform/README.md` | layout overview (partly stale on production status) |
| `terraform/staging/*.tf` | staging resources (table above) |
| `terraform/staging/user_data/` | first-boot scripts incl. nginx vhosts |
| `terraform/staging/bootstrap/` | state-bucket creation |
| `terraform/staging/EDGE-PROTECTION-RUNBOOK.md`, `terraform/production/EDGE-PROTECTION-RUNBOOK.md` | CloudFront/WAF rollout |
| `terraform/production/` | new-stack production (authoritative copy on `origin/production`) |
| `terraform/production/README.md` | production phase history (dated 2026-06-29) |
| `terraform/modules/lakehouse/` | unwired lakehouse scaffold |
| `Makefile` (`tf-*` targets) | init/plan/apply wrappers for staging |
