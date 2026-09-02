# terraform/

AWS Infrastructure-as-Code for the packiot-stack-alpha **staging** and **production**
environments. Each environment is a self-contained Graviton stack: a public **App EC2**
running the whole Docker Compose stack behind Nginx, a private **DB EC2** running
TimescaleDB, a cheap **NAT instance** for private-subnet egress, and the IAM / SG /
Route53 / Secrets Manager scaffolding around them.

The design goal is a **cattle-not-pets boot**: an instance comes up empty, pulls its
secrets from AWS Secrets Manager, writes `/opt/packiot/.env`, clones the repo, and
`docker compose up`s the stack — no image registry, no config baked into the AMI, no
manual SSH. Deploys thereafter run on a **self-hosted GitHub Actions runner** that lives
on the App EC2.

Provider: `hashicorp/aws ~> 5.0`, `hashicorp/random ~> 3.6`. Terraform `>= 1.10`
(required for S3-native state locking). Region: `us-east-1`. All resources are
Graviton/arm64 on the official Amazon Linux 2023 arm64 AMI.

---

## Layout

```
terraform/
├── staging/            # staging env (staging.packiot.app) — the reference template
│   ├── main.tf              provider, S3 backend (values via tf-init), default tags
│   ├── variables.tf         all inputs + sizing rationale in comments
│   ├── outputs.tf           EIP, NS records, service URLs, SSM/runner how-to, cost
│   ├── vpc.tf               VPC, public+private subnets, IGW, route tables, App EIP
│   ├── nat.tf               t4g.nano NAT instance (fck-nat-style MASQUERADE)
│   ├── ec2.tf               App + DB EC2, IAM roles/policies/profiles, S3 init objects, disk alarm
│   ├── security_groups.tf   App SG (80/443/22/AMQPS/CPACK-8447) + DB SG (5432 from App only)
│   ├── secrets.tf           packiot/staging/* Secrets Manager entries
│   ├── dns.tf               Route53 zone + per-service A records
│   ├── cognito.tf           ADR-0034 Cognito user pool + front4 client
│   ├── appsync.tf           AppSync (see file)
│   ├── backups.tf / snapshots.tf   S3 backup bucket + AWS Backup vault/plan
│   ├── bootstrap/           run-once module that creates the S3 state bucket
│   ├── scripts/             DB backup tooling (systemd timer + backup/restore .sh)
│   └── user_data/           EC2 first-boot scripts (see "Boot sequence")
│
├── production/         # production env (prod.packiot.app) — same shape, prod sizing
│   ├── (mirror of staging: main/variables/outputs/vpc/nat/ec2/security_groups/dns/secrets)
│   ├── database.tf          dedicated r7g DB EC2 (memory-family Graviton3)
│   ├── backups.tf / snapshots.tf
│   ├── oidc.tf              GitHub OIDC IAM for deploy-production.yml
│   ├── README.md            production-specific notes + phase status
│   └── user_data/           app_bootstrap.sh, app_init.sh, nginx_setup.sh
│
└── modules/
    └── lakehouse/      # ADR-0041 S3 lake + Glue + Athena — SCAFFOLD, NOT wired to any root (apply is a no-op)
```

`staging/` is the canonical template; `production/` was forked from it (ADR-0003) and
has since grown its own dedicated DB host, OIDC deploy role, and prod sizing. See
[`production/README.md`](./production/README.md) for prod-specific status.

---

## What it provisions

### Compute (per env)
| Host | Staging | Production | Notes |
|---|---|---|---|
| **App EC2** | `t4g.large` (2 vCPU / **8 GB**) | `t4g.large` | Public subnet, static EIP, runs the whole Compose stack + Nginx + the GH Actions runner. **Recently bumped from `t4g.medium` (4 GB)**: `docker compose build` of ~10 services OOM'd / swap-thrashed on 4 GB (`npm ci` ECONNRESET, exit 137). |
| **DB EC2** | `t4g.medium` (2 vCPU / 4 GB) | **`r7g.large`** (2 vCPU / **16 GB**, Graviton3 memory-family) | Private subnet, fixed private IP `10.10.10.89` (staging). r7g over t-family because TimescaleDB cagg-refresh is memory-bound; bump to `r7g.xlarge` under real client load. On-demand only (spot interruption mid-WAL-write corrupts data). |
| **NAT EC2** | `t4g.nano` | `t4g.nano` | ~$3/mo vs ~$33/mo for a managed NAT Gateway. Kernel `ip_forward` + iptables `MASQUERADE` on `ens5`, `source_dest_check = false`. Provides egress for the private subnet. |

EBS: gp3, encrypted, `delete_on_termination = false` (protects data on accidental
termination). Root volumes grown 32 → 64 GB after a 2026-06-22 disk-full lockout;
a CloudWatch alarm fires at 75% root usage.

### Network
Single-AZ (`us-east-1c`). VPC `10.10.0.0/16` (staging) — public subnet `10.10.0.0/24`
(App + NAT, explicit EIPs, no auto-assign), private subnet `10.10.10.0/24` (DB only,
egress via NAT). IGW on public route table; private route `0.0.0.0/0 → NAT ENI`.

### Security groups
- **App SG**: 80/443 world-open (Nginx basic-auth + Authentik are the access-control
  layer), 22 world-open (key-pair only, emergency ops), 5671 AMQPS (factory edge →
  RabbitMQ via Nginx TLS proxy), and **8447 restricted to CPACK's egress /32**
  (ADR-0042 CPACK Node-RED tee → sparkplug-agent). All egress open.
- **DB SG**: 5432 **from the App SG only** (no CIDR); egress open (OS updates + SSM via NAT).

### IAM (least-privilege, per host)
- **`packiot-<env>-app`** role/profile: `AmazonSSMManagedInstanceCore`; Secrets Manager
  read scoped to `packiot/<env>/*` (+ `databaseCredentials-??????` for the prod-mirror
  worker); S3 `GetObject` on `scripts/*` only (cannot read state files in the same
  bucket) + bucket-level `ListBucket` gated to `scripts/*`; Route53 (Certbot DNS-01
  challenge); `cloudwatch:PutMetricData` (CWAgent disk/mem metrics).
- **`packiot-<env>-db`** role/profile: SSM core; Secrets Manager read scoped to
  `packiot/<env>/db*` + `github-pat*`; S3 `scripts/*` read (fetches `db_init.sh`).
- No ECR — images are **built on-box** from the repo, not pulled (avoids needing a
  `packages:read` PAT scope). *(VERIFY: no ECR read policy exists in either env.)*

### Other
Route53 hosted zones (`staging.packiot.app` / `prod.packiot.app`) + per-service A
records → App EIP; Secrets Manager namespace `packiot/<env>/*`; S3 backup bucket +
AWS Backup vault/plan (daily snapshots, 30-day retention); staging adds Cognito
(ADR-0034) + AppSync; production adds a GitHub OIDC deploy role (`oidc.tf`).

---

## Boot sequence (how an empty EC2 becomes a running stack)

EC2 `user_data` has a hard **16 KB** limit, and the real init scripts exceed it. So
`ec2.tf` renders the heavy scripts with `templatefile()` and uploads them to S3
(`aws_s3_object.app_init` / `nginx_setup` / `db_init`), and `user_data` is only a tiny
bootstrapper that fetches and `exec`s the real one.

**App EC2:**
1. `user_data/app_bootstrap.sh` — waits for the EIP association / internet, waits for
   IAM S3 access, installs the SSM agent, then `aws s3 cp scripts/app_init.sh` and `exec`s it.
2. `user_data/app_init.sh` (the heavy lifter, idempotent):
   - System prep: `dnf update`, 4 GB swap file (absorbs Go-build OOM spikes), Docker +
     Compose v2 plugin.
   - **Fetches all secrets** from Secrets Manager (`packiot/<env>/{db,app,hasura,
     nodered-auth,authentik}`, plus optional `agent-ingest`, `ec2-rescue`, rabbitmq
     client creds) and **writes `/opt/packiot/.env`** — the single env-file every
     Compose service reads. `.env` generation is **guarded** (skips if present) so a
     re-run never rotates `NODE_RED_CREDENTIAL_SECRET` and orphan Node-RED creds.
   - Configures GitHub PAT auth (HTTPS URL rewrite for all `packiot/*` repos), clones
     `packiot-stack-alpha` @ `staging`, inits submodules, symlinks `.env` into the repo.
   - Runs `nginx_setup.sh` (Nginx vhosts + Certbot/Let's Encrypt DNS-01 certs).
   - Installs the **GitHub Actions self-hosted runner** binaries + writes
     `/opt/packiot/register-runner.sh` (registers the runner once you populate the
     `github-runner` secret — see the `github_runner_next_step` output).
   - Sets a Serial-Console rescue root password, installs a weekly `docker-prune` timer
     (`--volumes=false`, so it never nukes named-volume state), and finally
     `docker compose -f compose.<env>.yml up -d --build`.
   - Provisions RabbitMQ users/exchanges (edge client + edge-transformer least-priv topology).

**DB EC2:** `db_bootstrap.sh` → `db_init.sh` — same S3-fetch pattern; builds the custom
TimescaleDB + pg_cron image locally from `db/Dockerfile` and runs it via Docker.

Both instances carry `lifecycle { ignore_changes = [ami, user_data, ...] }` so a
rendered-script change or an AMI refresh does **not** silently replace a running box —
you roll it deliberately.

---

## How to use it

State lives in **S3**: bucket `packiot-terraform-state-<account_id>`, key
`<env>/terraform.tfstate`, with **S3-native locking** (`use_lockfile=true`, needs TF
`>= 1.10` — no DynamoDB table). The bucket is versioned + SSE + public-access-blocked
and is created by the run-once `bootstrap/` module.

The `Makefile` `tf-*` targets wrap the workflow. **Note: they currently point at
`terraform/staging` only** (`TF_DIR = terraform/staging` in the Makefile). Production
is driven with raw `terraform` commands from `terraform/production/` until per-env
targets land (see `production/README.md`).

```bash
# One-time per AWS account — create the state bucket:
make tf-bootstrap        # cd terraform/staging/bootstrap && terraform init && apply

# One-time per developer — wire the remote backend:
make tf-init             # terraform init with -backend-config for the S3 bucket/key/region/lock

# Everyday:
make tf-fmt              # terraform fmt -recursive (formats staging/)
make tf-validate         # tf-fmt, then terraform validate
make tf-plan             # terraform plan  (review BEFORE applying)
make tf-apply            # terraform apply (prompts to confirm)
make tf-output           # print outputs: App EIP, DB IP, NS records, service URLs,
                         #   SSM connect commands, runner activation steps, cost estimate
make tf-destroy          # DANGER — destroys the whole staging env

# Production (until Makefile targets exist):
cd terraform/production && terraform init -backend-config=... && terraform plan
```

Useful outputs after an apply: `route53_nameservers` (manual delegation step at the
registrar), `ssm_connect_app` / `ssm_connect_db` (shell in via SSM — no SSH/bastion),
and `github_runner_next_step` (activate the deploy runner).

---

## Safety & contributing

- **`terraform apply` here is production-affecting.** Always `make tf-plan` and read the
  diff first. `tf-destroy` tears down a whole environment — never run it against
  production. Prod DB EBS is `delete_on_termination = false`, but that is a backstop, not
  a policy.
- **Codify live changes or they drift.** Anything changed by hand via the AWS CLI/console
  (an instance resize, an SG rule, a volume grow) **must** be reflected back into these
  `.tf` files, or the next `apply` will revert it. The `app_instance_type` bump to
  `t4g.large` and the 32→64 GB volume grows are examples of live fixes that were codified
  here — follow that pattern. Volume grows also need an in-place `growpart` + `xfs_growfs`
  over SSM after the apply.
- **Branch flow.** Changes go through the standard `feature → development → staging` PR
  flow — see the repo root [CONTRIBUTING.md](https://github.com/packiot/packiot-stack-alpha/blob/staging/CONTRIBUTING.md).
  Never push directly to `main`/`master` in any Packiot repo.
- **The `modules/lakehouse` module is a scaffold** (ADR-0041) — not referenced by any
  root, so applying either env is a no-op for it. Do not wire it up without ADR sign-off.

## Cost envelope

Roughly **~$41/mo staging** / **~$37/mo production** (single-EC2 dry-run baseline; the
prod number rises with the dedicated r7g DB). Breakdown lives in each env's
`outputs.tf` `estimated_monthly_cost`. The design deliberately trades HA for cost:
single-AZ, a NAT *instance* not a Gateway, standard (not unlimited) CPU credits on
staging. The production HA upgrade path (ASG + mixed spot/on-demand app fleet,
`aws_nat_gateway`, multi-AZ) is noted inline in the relevant `.tf` files.
