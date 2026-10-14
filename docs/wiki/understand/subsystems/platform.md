---
title: Platform & operations
layer: 2
owner_area: platform
last_verified: 2026-10-13
---
# Platform & operations

> **Layer 2 · Subsystems** — the hosts, containers, pipelines, infrastructure code, secrets,
> edge network and monitoring that every other subsystem runs on. For on-call engineers and
> anyone who deploys or changes infrastructure.
> Up: [Environments](../architecture/environments.md) · [Architecture overview](../architecture/overview.md)

## Purpose

The platform subsystem turns the repository into running software. It owns the EC2 hosts,
the Docker Compose files that define every container, the GitHub Actions workflows that
validate and deploy them, the Terraform that creates the AWS resources, the way secrets
reach the containers, the CloudFront/WAF/nginx front door, and the
Prometheus/Loki/Tempo/Grafana stack that tells you whether all of it works. It computes no
OEE and owns no business data; it makes sure the services that do are running, reachable
and observable.

## Boundaries

| Owns | Does NOT own |
|---|---|
| `compose.*.yml`, `dev/`, `.github/workflows/`, `terraform/`, `monitoring/`, `grafana/`, `systemd/` | Service code and its config semantics (each component page owns that) |
| Host layout, Docker network and volumes, nginx vhosts (`terraform/*/user_data/nginx_setup.sh`) | Database schema and migrations ([Analytics DB](analytics-db.md)) |
| Secrets delivery (Secrets Manager → `/opt/packiot/.env`) | Tenant/user identity rules ([Identity](identity.md)) |
| Deploy gates, rollback, runbooks, the wiki pipeline | The legacy production platform (`packiot40`/tsp12, Hasura, Node-RED oeecloud) — outside this repo |
| | Client factory boxes' own OS (see [Edge](edge.md)) |

## Components

| Component | What it does | Runtime | Layer-3 page |
|---|---|---|---|
| Compose topology | Every container, network, volume, port and healthcheck per environment | Docker Compose v2 | [Compose topology](../components/compose-topology.md) |
| CI/CD | PR gates, deploys, secret scanning, sandbox self-heal | GitHub Actions (hosted + self-hosted runners) | [CI/CD](../components/ci-cd.md) |
| Terraform | VPC, EC2, IAM, Route53, CloudFront, WAF, Cognito, S3, Secrets Manager entries | Terraform ≥ 1.10, AWS provider ~> 5.0 | [Terraform](../components/terraform.md) |
| Observability | Metrics, logs, traces, alerts, dashboards | Prometheus, Loki, Tempo, Alloy, Grafana | [Observability](../components/observability.md) |
| Wiki pipeline | Builds this site and syncs it to S3; the serving box pulls it | mkdocs-material, S3 | [Wiki pipeline](../components/wiki-pipeline.md) |
| Runbooks | Step-by-step procedures | Markdown | [Runbooks](../../build/operate/runbooks.md) |
| Configuration index | Every env var in `compose.staging.yml` | — | [Configuration](../../reference/configuration.md) |

Every deployed service has a row in the [service catalog](../../reference/service-catalog.md).

## How it works

### Environments

| Environment | Definition | Hosts | Deployed by |
|---|---|---|---|
| Local | `dev/` slices (ADR-0060) on an anonymized CPACK seed | your machine | `make dev SVC=…` — see [Local development](../../build/develop/local-development.md) |
| **Staging** | `compose.staging.yml` + `compose.superset.yml` overlay, project `stack` | AWS us-east-1: app EC2, DB EC2, NAT instance | push to `staging` → `deploy-staging.yml` |
| New-stack production | `compose.production.yml` (`name: stack`), `terraform/production` | AWS us-east-1: app EC2 + DB EC2 (`10.20.10.89`) | push to `production` → `deploy-production.yml` on `[self-hosted, production, linux, arm64]` |
| Legacy production | `packiot40` (tsp12), Hasura, Node-RED oeecloud | legacy hosts | outside this repo |
| Client edge | `compose.onprem-edge.yml`, `docs/clients/edge-deployment/compose.edge.yml` bundles | factory boxes | SSM via edge-api, `client-edge-deploy.yml`, `generate-client-bundle.yml` |

!!! note "Which production?"
    **Production clients are still served by the legacy platform.** The new-stack production
    environment (`compose.production.yml`, `terraform/production`) exists but has not been
    promoted: the `production` branch was last updated 2026-09-08 and the promotion is the
    open draft PR #1653 (`release/prod-promotion-2026-10`). Everything on this page is staging
    unless it says otherwise.

### Staging hosts

```text
                      Internet
                         │
            CloudFront + WAF (*.staging.packiot.app)     direct A-records to the EIP
                         │  X-Origin-Verify header        amqp / cpack-ingest / ingest / scan
                         ▼                                          │
 ┌─ public subnet 10.10.0.0/24 ──────────────────────────────────────▼──────────────┐
 │  packiot-staging-app  (t4g.large, 8 GB, arm64, 128 GB gp3, EIP)                  │
 │   nginx :80/:443/:5671/:8447/:8449 ──► containers (127.0.0.1 ports or bridge IP)│
 │   compose project "stack", network packiot-net 172.18.0.0/24 (~50 services)     │
 │   + historian gateway (compose.historian-gateway.yml) + GitHub self-hosted runner│
 │   + systemd timers: historian append 02:30 UTC, integrity 04:00 UTC,            │
 │     data-oracle check hourly, sandbox grace-heal every 5 min                    │
 │  packiot-staging-nat  (t4g.nano, NAT for the private subnet)                    │
 └───────────────────────────────────┬─────────────────────────────────────────────┘
                                     │ 5432 (DB SG admits the app SG only)
 ┌─ private subnet 10.10.10.0/24 ─────▼─────────────────────────────────────────────┐
 │  packiot-staging-db  (r7g.large, 16 GB, 128 GB gp3, 10.10.10.89)                │
 │   container `timescaledb` (packiot_analytics, …) + `alloy-db` agent             │
 │   agent PUSHES logs → app:3101, metrics → app:3102 (no inbound to the DB box)   │
 │   timer packiot-db-backup 02:00 UTC                                             │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

Sizes, subnets and the DB IP come from `terraform/staging/variables.tf`, `ec2.tf` and
`nat.tf`. The DB box's `timescaledb` container is started by
`terraform/staging/user_data/db_init.sh`, **not** by any compose file; the DB-box Alloy agent
is deployed by `scripts/deploy-db-agent.sh`. Timers live in `systemd/` (app host) and
`terraform/staging/scripts/` (backups).

Two checkouts of the repo exist on the app host:

| Path | Created by | Used for |
|---|---|---|
| `/opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha` | the self-hosted runner | **every deploy**; the compose `working_dir` label of running containers points here |
| `/opt/packiot/stack` | `app_init.sh` at first boot | the first `docker compose up` only |

Both symlink `.env` → `/opt/packiot/.env` and use project `stack`, so containers are named
`stack-<service>-1` unless the service pins `container_name` (most Go services and the
observability stack do; `rabbitmq`, `pgbouncer`, `mosquitto`, `edge-api`, `grafana`, `loki`,
`promtail` do not).

### Deploy flow (staging)

```text
 submodule repo (edge-api, operator4, edge-node-red)
   push to its `staging` ──► bump-stack-submodule.yml (in the submodule repo)
                               opens a bot PR on packiot-stack-alpha base=staging
   (csadmin has no bump bot: bump its pointer by hand)
                                         │
 PR into staging ──► REQUIRED: "Validate compose files" (PR Validation)
                               "dev slices gate" (Dev slices)
                     also: packml ratchet, Go Services CI, OpenAPI export, read-api
                     contract drift, Superset RLS isolation, gitleaks, dashboard-lint,
                     build-wiki (path-filtered where configured)
                                         │ merge (ruleset "Protect staging")
                                         ▼
 push to `staging` ──► deploy-staging.yml
   gate job: skip this run if `staging` has already moved past its commit
   deploy job on [self-hosted, staging, linux, arm64] (the runner IS the app host):
   checkout → submodules (edge-api edge-node-red operator csadmin) → link .env
   → self-heal .env keys → render RabbitMQ definitions → optional barcode-app GHCR pull
   → resolve COMPOSE_PROFILES (+shared-tee, +alerting if a webhook exists)
   → compose build → up -d --remove-orphans → prune → reload Prometheus/Alloy/
   Alertmanager, restart postgres-exporter/Loki when their config changed
   → SERVICE-STATE GATE (every expected service running/healthy) → diagnostics
```

The "Protect staging" ruleset requires a PR, the two status checks above, no force-push and
no deletion; merge, squash and rebase are all allowed. Wait for CI on the PR's head commit
before merging. Step-by-step detail and rollback: [CI/CD](../components/ci-cd.md#deploy-stagingyml-step-by-step).
front4 is **not** deployed by this workflow (AWS Amplify builds it from its own repo).

### Secrets path

```text
 AWS Secrets Manager  packiot/staging/*  (+ legacy `databaseCredentials`)
        │  app_init.sh at FIRST boot only (skips if /opt/packiot/.env exists)
        │  deploy-staging.yml self-heals a few keys when absent
        ▼
 /opt/packiot/.env  ──symlink──►  <checkout>/.env  ──►  compose ${VAR} substitution + env_file
        │
        └─ some services read Secrets Manager themselves at runtime (RABBITMQ_SECRET_ID,
           PG_SECRET_ID) using the app instance role
```

Because `app_init.sh` never rewrites an existing `.env`, **a new key added to Secrets Manager
does not reach a running box by itself**. Either the deploy workflow adds it (done for
`ALLOY_GATEWAY_BIND` and `HIST_GW_SVC_PASSWORD`) or someone appends it by hand. Rotation:
[Secrets rotation](../../build/operate/secrets-rotation.md).

| Secret (Secrets Manager) | Holds (by name, never values) | Consumed by |
|---|---|---|
| `packiot/staging/db` | analytics DB credentials | `.env` `POSTGRES_*` (admin; no Go service on staging uses it any more) |
| `packiot/staging/operator-gateway-db-creds` | `operator_gateway` login (least privilege, `t-operator-gateway-role`): `{host, port, user, password, name}` | operator-gateway via `PG_SECRET_ID`; created on the app host by `scripts/ops/provision-db-role.py --service operator-gateway` |
| `packiot/staging/barcode-service-db-creds` | `barcode_service` login (least privilege, `t-barcode-service-role`): `{host: pgbouncer, port, user, password, name}` | barcode-service via `PG_SECRET_ID`; created on the app host by `scripts/ops/provision-db-role.py --service barcode-service` |
| `packiot/staging/stream-engine-db-creds` | `stream_engine` login (least privilege, `t-stream-engine-role`): `{host: 10.10.10.89, port, user, password, name}` | stream-engine via `PG_SECRET_ID`; created on the app host by `scripts/ops/provision-db-role.py --service stream-engine` |
| `packiot/staging/app` | app keys: API keys, oauth2-proxy client/cookie secrets, Superset secrets, optional `slack_api_url` | `app_init.sh`; deploy step "Materialize Alertmanager Slack webhook" |
| `packiot/staging/rabbitmq-stream-engine-creds` | AMQP user for stream-engine | stream-engine, oeecloud-fanout, RabbitMQ definitions |
| `packiot/staging/rabbitmq-sparkplug-decoder-creds` | AMQP user for the decoder | sparkplug-decoder, ingest-shim, RabbitMQ definitions |
| `packiot/staging/historian-svc` | `historian_svc` gateway login | deploy step → `.env` `HIST_GW_SVC_PASSWORD` |
| `packiot/staging/agent-ingest` | agent ingest key | `app_init.sh` → `.env` |
| `packiot/staging/ghcr-read` (optional) | GHCR read token | deploy step "Pull barcode-app from GHCR" |
| `packiot/staging/e2e-test-creds` | QA Cognito users for E2E | `e2e/` |
| `packiot/staging/github-runner`, `ec2-rescue`, `nginx-auth`, `nodered-auth` | runner token, serial-console password, legacy basic-auth | `app_init.sh`, `nginx_setup.sh` |
| `databaseCredentials` | SELECT-only login on the legacy `packiot40` DB | legacy-replicator (`.env` `LEGACY_DB_PASSWORD`), audit scripts |

Terraform creates most `packiot/staging/*` entries (`terraform/staging/secrets.tf`) with
`ignore_changes = [secret_string]`, so values set out-of-band stick. The `rabbitmq-*-creds`
secrets were created by hand.

### Front door (DNS, CloudFront, WAF, nginx)

| Hostname (staging) | Path in | Auth tier (`service_auth`) |
|---|---|---|
| `api.` | CloudFront (WAF) → nginx → edge-api | `/api/*` and `/session*` bypass the gate (edge-api auth); `/` and `/docs/` (API portal) need `cs-admin` |
| `grafana.`, `rabbitmq.`, `db.`, `barcode.` | CloudFront → nginx → container | oauth2 `cs-admin` group |
| `operator.`, `operator-sbx.`, `operator-bispharma.` | CloudFront → nginx → operator containers | oauth2 any pool user; tenant key injected by the container |
| `csadmin.`, `customize.` | CloudFront → nginx | origin-verify only (in-app Cognito login) |
| `bi.` | CloudFront → nginx → Superset | Superset auth / guest tokens |
| `refdata.` | CloudFront → nginx → read-api | no gate (read-api auth); `/metrics`, `/openapi.json` → 404 |
| `scan.` | nginx → barcode-service (exact paths) | no gate (Cognito Bearer in the service) |
| `auth.` | nginx → oauth2-proxy :4180 | the sign-in endpoint itself |
| `amqp.` :5671, `cpack-ingest.` :8447, `ingest.` :8449 | direct A-record to the EIP | source-IP /32 allowlist in the app security group + service key; 5671 is marked retiring |

`terraform/staging/edge.tf`: `edge_cutover = true` (live 2026-08-05: service records ALIAS →
CloudFront), `waf_managed_rules_mode = "block"`, rate limit 2000 requests / 5 min / IP, and
`edge_origin_lock = false` (443 on the origin is still world-open; nginx checks
`X-Origin-Verify`). The staged rollout is in `terraform/staging/EDGE-PROTECTION-RUNBOOK.md`.
nginx changes: [nginx config changes](../../build/operate/nginx-config-changes.md).

### Observability

Prometheus scrapes the Go services, edge-api, the exporters (node, cAdvisor, Postgres,
Redis, RabbitMQ, blackbox). Two job names were kept across renames for dashboard
continuity: `oeecloud-worker` is stream-engine and `edge-transformer` is sparkplug-decoder.
Promtail ships container logs to Loki; services send OTLP traces to Tempo (some via Alloy);
the DB box pushes through Alloy relays. Grafana has an `audience/` folder (start here) and a
`library/` folder. `monitoring/prometheus/rules.yml` holds 40 alert rules; Alertmanager →
Slack runs only when the `alerting` profile is on, which the deploy enables once a
`slack_api_url` has been materialised. See [Observability](../components/observability.md).

## Interfaces

| Direction | Interface | Producer → consumer |
|---|---|---|
| Inbound | HTTPS 443 via CloudFront | browsers → nginx → containers |
| Inbound | HTTPS 8447 / 8449, AMQPS 5671 (direct, /32 allowlist) | factory tees and boxes → sparkplug agents / RabbitMQ |
| Inbound | Loki push 3101, Prometheus remote-write 3102 (DB SG only) | DB-box Alloy → app-box Alloy |
| Inbound | GitHub → self-hosted runner (long poll) | Actions → staging app host |
| Outbound | Secrets Manager, S3, SSM, Cognito, GHCR/Docker Hub | app instance role |
| Outbound | Postgres 5432 to legacy `packiot40` (SELECT-only) | legacy-replicator, legacy-replicator-sbx |
| Operator access | AWS SSM (Session Manager / send-command); no inbound SSH rule | engineers → app/DB hosts |

## Data it owns

| Artifact | Lifecycle |
|---|---|
| Docker named volumes (`rabbitmq-data`, `mosquitto-data`, `prom-data`, `loki-data`, `tempo-data`, outbox volumes, …) | survive container recreate; lost only on `docker volume rm` or host rebuild |
| `/opt/packiot/.env` | written once by `app_init.sh`; appended by deploy self-heal steps; hand edits persist |
| `/opt/packiot/rabbitmq/definitions.json` | re-rendered every deploy from `monitoring/rabbitmq/definitions.template.json` + Secrets Manager |
| Prometheus TSDB | 15 days or 2 GB, whichever first (`compose.staging.yml`) |
| Loki logs | 72 h, enforced by the compactor (`monitoring/loki/loki-local-config.yaml`) |
| Tempo traces | 48 h (`monitoring/tempo/tempo.yaml`) |
| EBS snapshots of both staging hosts (app and DB) | AWS Backup daily 03:00 UTC, 7-day retention (`terraform/staging/snapshots.tf`; DB selection verified 2026-10-13) |
| DB and historian dumps | S3 via `packiot-db-backup.timer` (02:00 UTC) and `packiot-historian-backup.timer` (04:30 UTC); see [Backups and restore](../../build/operate/backups-and-restore.md) |
| Terraform state | S3 backend with native locking (`use_lockfile`), separate keys for staging and production |

## Configuration that matters

| Knob | Where | Effect |
|---|---|---|
| `COMPOSE_PROFILES` | `/opt/packiot/.env` | profile-gated services: `superset`, `cpack-tee`, `alerting`, `plc-sim`, `s7`, `legacy-sim`, `legacy-comparator` (`shared-tee` is always added by the deploy) |
| `-p stack` / `name: stack` | deploy workflows, both compose files | project name; building or starting under another name creates a **second** set of containers fighting over the same subnet |
| `ALLOY_GATEWAY_BIND` | `.env` (self-healed by deploy) | must be the app host's private IP or the DB box's logs/metrics are refused |
| `edge_cutover`, `edge_origin_lock`, `waf_managed_rules_mode` | `terraform/staging/edge.tf` | DNS via CloudFront, origin lockdown, WAF enforcement |
| `IDENTITY_SENTINEL_ENFORCE` | `deploy-staging.yml` | `false` = the int-overflow sentinel only warns |
| `app_instance_type`, `db_instance_type`, `*_volume_size_gb` | `terraform/staging/variables.tf` | host sizing (EBS volumes can only grow) |

Retired services stay in `compose.staging.yml` behind profiles that are off:
`mirror-worker-go` (`legacy-comparator`, retired 2026-08-13) and `edge-nodered` + `simulator`
(`legacy-sim`, retired 2026-08-16).

## Failure modes & signals

| Failure | How you notice | Where to look / fix |
|---|---|---|
| Deploy red at **Fetch submodules** ("local changes would be overwritten") | Actions log | someone hand-edited a submodule in the runner checkout; the workflow now `git reset --hard`s submodules first. Never `git clean -fdx` there |
| An older commit's deploy rolls a newer one back | merged fix not running though both runs are green (2026-10-08) | fixed: the `gate` job skips runs that `staging` has moved past |
| A recreated service left in `created` state | service-state gate fails with the container's last log lines | compose create→start race; re-run `up -d <svc>` ([runbooks](../../build/operate/runbooks.md#recreate-a-single-service)) |
| RabbitMQ exits 127 after a host reboot | `IngestSilent` / `WritePathDry`; `stack-rabbitmq-1` exited | definitions file used to live in the runner workspace (2026-09-25); now rendered to `/opt/packiot/rabbitmq/` |
| Decoder "healthy" but publishing nothing after reboot | ingest counters flat | started before RabbitMQ; retry-then-exit since #1447 |
| Host OOM / thrash at 02:30 UTC | `node_memory_MemAvailable` cliff, SSM ConnectionLost | nightly historian DuckDB job; now cgroup-capped (#1448) |
| Disk filling on the app host | `HostDiskFilling` / CloudWatch `packiot-staging-app-disk-used-percent` | build cache (deploy runs `docker builder prune --keep-storage 5GB`); Loki retention not applied until Loki restarts (2026-10-06, disk 97 % → volume 128 GB, #1562; deploy now restarts Loki on config change) |
| DB-box logs missing in Loki | `DbBoxMetricsMissing`; alloy-db "error sending batch" | `ALLOY_GATEWAY_BIND` unset → relays bound to loopback (fixed #1405) |
| Config edit "deployed" but not loaded | metric/rule absent despite green deploy | single-file bind mounts pin the old inode (#1406); mount directories and reload |
| Merged code but nothing deployed | no new run on `staging` | submodule bump token (`PARENT_REPO_TOKEN`) invalid, or push events late — wait before a manual dispatch |
| Two container sets / "Pool overlaps" | duplicate containers, network error | built or started under a different project name; always `-p stack` |

## History & decisions

- ADR-0003 (production parent stack), ADR-0005 (per-factory self-hosted runners), ADR-0006
  (workflow refactor), ADR-0016/0032 (single-flow consolidation), ADR-0034 (Cognito +
  oauth2-proxy), ADR-0049/0057 (SSM as the box-access substrate), ADR-0060 (local dev
  environment) — see the [ADR index](../../reference/adr-index.md).
- 2026-06-22: app disk full → volume 32→64 GB, weekly `docker-prune.timer`.
- 2026-07-10: plugin enable recreated RabbitMQ with fresh Mnesia and lost users → `load_definitions`.
- 2026-08-05: CloudFront/WAF cutover for staging.
- 2026-08-10 and 2026-08-12: `terraform -target` creations without committed config nearly
  destroyed prod resources on the next full plan (see [Terraform](../components/terraform.md#failure-modes)).
- 2026-09-25: app host OOM and reboot incident.
- 2026-10-06: Loki retention no-op filled the disk; app volume grown to 128 GB.
- 2026-10-08: out-of-order deploy runs → `gate` job.
- 2026-10-13: refdata `/metrics` and `/openapi.json` closed publicly; API docs portal at
  `api.staging.packiot.app/docs/`.

## Go deeper

- [Compose topology](../components/compose-topology.md) — every container
- [CI/CD](../components/ci-cd.md) — every workflow and the deploy step order
- [Terraform](../components/terraform.md) — every AWS resource and how to plan safely
- [Observability](../components/observability.md) — metrics, logs, traces, alerts, dashboards
- [Wiki pipeline](../components/wiki-pipeline.md) — how this site is built and served
- [Runbooks](../../build/operate/runbooks.md) · [Deploy](../../build/operate/deploy.md) ·
  [Configuration reference](../../reference/configuration.md) ·
  [Service catalog](../../reference/service-catalog.md)
