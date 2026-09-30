---
title: Platform & operations
layer: 2
owner_area: platform
last_verified: 2026-09-28
---
# Platform & operations

> **Layer 2 · Subsystems** — the hosts, containers, pipelines, infrastructure code, secrets,
> edge network and monitoring that every other subsystem runs on. For on-call engineers and
> anyone who deploys or changes infrastructure.
> Up: [Environments](../architecture/environments.md) · [Architecture overview](../architecture/overview.md)

## Purpose

The platform subsystem turns the repository into running software. It owns the EC2 hosts,
the Docker Compose files that define every container, the GitHub Actions workflows that build
and deploy them, the Terraform that creates the AWS resources, the way secrets reach the
containers, the CloudFront/WAF/nginx front door, and the Prometheus/Loki/Tempo/Grafana
stack that tells you whether all of it works. It does not compute OEE or own any business
data; it makes sure the services that do are running, reachable and observable.

## Boundaries

| Owns | Does NOT own |
|---|---|
| `compose.*.yml`, `.github/workflows/`, `terraform/`, `monitoring/`, `grafana/`, `systemd/` | Service code and its config semantics (each component page owns that) |
| Host layout, Docker networks and volumes, nginx vhosts (via `terraform/*/user_data/nginx_setup.sh`) | Database schema and migrations ([Analytics DB](analytics-db.md)) |
| Secrets delivery (Secrets Manager → `/opt/packiot/.env`) | Tenant/user identity rules ([Identity](identity.md)) |
| Deploy gates, rollback, runbooks | The legacy production platform (`packiot40`/tsp12, Hasura, Node-RED oeecloud) — outside this repo |
| The wiki build pipeline | Client factory boxes' own OS (see [Edge](edge.md)) |

## Components

| Component | What it does | Runtime | Layer-3 page |
|---|---|---|---|
| Compose topology | Defines every container, network, volume, port and healthcheck per environment | Docker Compose v2 | [compose-topology.md](../components/compose-topology.md) |
| CI/CD | Builds, validates and deploys; secret scanning; nightly sandbox reset | GitHub Actions (hosted + self-hosted runners) | [ci-cd.md](../components/ci-cd.md) |
| Terraform | VPC, EC2, IAM, Route53, CloudFront, WAF, Cognito, S3, Secrets Manager entries | Terraform ≥ 1.10, AWS provider ~> 5.0 | [terraform.md](../components/terraform.md) |
| Observability | Metrics, logs, traces, alerts, dashboards | Prometheus, Loki, Tempo, Alloy, Grafana | [observability.md](../components/observability.md) |
| Wiki pipeline | Builds this site and ships it to the box that serves it | mkdocs-material, S3, cron | [wiki-pipeline.md](../components/wiki-pipeline.md) |
| Runbooks | Step-by-step procedures | Markdown | [runbooks.md](../operations/runbooks.md) |
| Configuration index | Every env var in `compose.staging.yml` | — | [configuration.md](../reference/configuration.md) |

## How it works

### Environments

| Environment | Definition | Hosts | Deployed by |
|---|---|---|---|
| Local | `compose.development.yml` (includes its own `postgres`, Hasura, simulator, `tests`) | your machine | `make up` (wraps `docker compose -f compose.development.yml`) |
| **Staging** | `compose.staging.yml` + `compose.superset.yml` overlay, project name `stack` | AWS us-east-1: app EC2, DB EC2, NAT instance | push to `staging` → `deploy-staging.yml` |
| New-stack production | `compose.production.yml` (top-level `name: stack`) | AWS us-east-1: app EC2 + DB EC2 (`terraform/production`) | push to `production` → `deploy-production.yml` |
| Legacy production | `packiot40` (tsp12), Hasura, Node-RED oeecloud | legacy hosts | outside this repo |
| Client edge | `compose.onprem-edge.yml`, `compose.edge.yml` bundles | factory boxes | `client-edge-deploy.yml`, `generate-client-bundle.yml`, SSM |

!!! note "Which production?"
    `compose.production.yml` and `terraform/production` describe the **new-stack** production
    environment (`prod.packiot.app`), which was born "single-flow" (one DB, `public` schema =
    analytics schema; no mirrors or comparators). Most paying clients are still served by the
    **legacy** platform. Everything on this page is staging unless it says otherwise.

### Staging hosts

```text
                      Internet
                         │
            CloudFront + WAF (*.staging.packiot.app)     direct A-records for TLS ports
                         │  X-Origin-Verify header        amqp / cpack-ingest / ingest / scan
                         ▼                                          │
 ┌─ public subnet 10.10.0.0/24 ──────────────────────────────────────▼──────────────┐
 │  packiot-staging-app  (t4g.large, 8 GB, arm64, EIP)                             │
 │   nginx :80/:443/:5671/:8447/:8449 ──► 127.0.0.1:<port> containers               │
 │   Docker project "stack", network stack_packiot-net 172.18.0.0/24 (~50 services) │
 │   + hist-gateway (separate compose project) + GitHub self-hosted runner         │
 │   + systemd timers: historian append 02:30 UTC, integrity monitor 04:00 UTC     │
 │  packiot-staging-nat  (t4g.nano, MASQUERADE NAT for the private subnet)         │
 └───────────────────────────────────┬─────────────────────────────────────────────┘
                                     │ 5432 (DB SG admits app SG only)
 ┌─ private subnet 10.10.10.0/24 ─────▼─────────────────────────────────────────────┐
 │  packiot-staging-db  (r7g.large, 16 GB, 10.10.10.89)                             │
 │   container `timescaledb` (DBs packiot_analytics, packiot) + `alloy-db` agent   │
 │   agent PUSHES logs → app:3101, metrics → app:3102 (no inbound to the DB box)   │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

Instance types, subnets and the DB IP are from `terraform/staging/variables.tf` and
`terraform/staging/ec2.tf`. The DB box's `timescaledb` container is started by
`terraform/staging/user_data/db_init.sh`, **not** by any compose file; the DB-box Alloy agent
is deployed by `scripts/deploy-db-agent.sh`.

Two checkouts of the repo exist on the app host:

| Path | Created by | Used for |
|---|---|---|
| `/opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha` | the self-hosted runner | **every deploy**; the compose `working_dir` label of running containers points here |
| `/opt/packiot/stack` | `app_init.sh` at first boot | the first `docker compose up` only |

Both symlink `.env` → `/opt/packiot/.env` and use project name `stack`, so containers are
named `stack-<service>-1` unless the service pins `container_name` (most Go services and
the observability stack do; `rabbitmq`, `pgbouncer`, `mosquitto`, `edge-api`, `grafana`,
`loki`, `promtail` do not).

### Deploy flow (staging)

```text
 submodule repo (edge-api, operator4, csadmin, edge-node-red)
   push to its `staging` ──► bump-stack-submodule.yml (lives in the submodule repo)
                               opens bot PR on packiot-stack-alpha base=staging
                                         │
 PR into staging ──► PR Validation (compose config) · gitleaks · Superset RLS gate
                     · Go CI / lint gates (path-filtered)
                                         │ auto-merge (squash)
                                         ▼
 push to `staging` ──► deploy-staging.yml on [self-hosted, staging, linux, arm64]
                       (the runner IS the staging app host)
   checkout → submodules → link .env → self-heal .env keys → render RabbitMQ definitions
   → compose build → compose up -d --remove-orphans → prune → hot-reload Prometheus/
   Alloy/Alertmanager → SERVICE-STATE GATE (every service running/healthy) → diagnostics
```

Details, including the order of every step and how to roll back, are in
[ci-cd.md](../components/ci-cd.md#deploy-stagingyml-step-by-step). `front4` is **not**
deployed by this workflow: it has its own repository pipeline (AWS Amplify).

### Secrets path

```text
 AWS Secrets Manager  packiot/staging/*  (+ legacy `databaseCredentials`)
        │  app_init.sh at FIRST boot only (skips if /opt/packiot/.env exists)
        │  deploy-staging.yml self-heals a few keys when absent
        ▼
 /opt/packiot/.env  ──symlink──►  <checkout>/.env  ──►  compose ${VAR} substitution + env_file
        │
        └─ some services read Secrets Manager themselves at runtime (RABBITMQ_SECRET_ID,
           PG_SECRET_ID, PROD_DB_SECRET_ID) using the app instance role
```

Because `app_init.sh` never rewrites an existing `.env`, **a new key added to Secrets Manager
does not reach a running box by itself**. Either the deploy workflow adds it (this is done
for `ALLOY_GATEWAY_BIND` and `HIST_GW_SVC_PASSWORD`) or someone appends it by hand. See
[Failure modes](#failure-modes-signals).

| Secret (Secrets Manager) | Holds (by name, never values) | Consumed by |
|---|---|---|
| `packiot/staging/db` | analytics DB credentials | `.env` `POSTGRES_*`; stream-engine / operator-gateway / analytics-sync `PG_SECRET_ID` |
| `packiot/staging/app` | app keys: API keys, oauth2-proxy client/cookie secrets, Superset secrets, `slack_api_url` | `app_init.sh`, deploy step "Materialize Alertmanager Slack webhook" |
| `packiot/staging/rabbitmq-stream-engine-creds` | least-privilege AMQP user `stream-engine` | stream-engine, oeecloud-fanout, RabbitMQ definitions |
| `packiot/staging/rabbitmq-sparkplug-decoder-creds` | AMQP user `sparkplug-decoder` | sparkplug-decoder, ingest-shim, RabbitMQ definitions |
| `packiot/staging/historian-svc` | `historian_svc` gateway login | deploy step → `.env` `HIST_GW_SVC_PASSWORD` |
| `packiot/staging/historian-gateway-s3` | scoped read-only S3 key for the gateway | historian gateway `.env.historian-gateway` |
| `packiot/staging/agent-ingest` | CPACK agent ingest key | `.env` `AGENT_INGEST_API_KEY` |
| `packiot/staging/e2e-test-creds` | QA Cognito users for E2E | `e2e/` (`npm run creds`) |
| `packiot/staging/github-runner`, `packiot/staging/ec2-rescue`, `packiot/staging/nginx-auth`, `packiot/staging/nodered-auth` | runner token, serial-console root password, legacy basic-auth | `app_init.sh`, `nginx_setup.sh` |
| `databaseCredentials` | SELECT-only login on the legacy `packiot40` DB | legacy-replicator, mirror-worker-go, audit scripts |

Terraform creates most `packiot/staging/*` entries (`terraform/staging/secrets.tf`) with
`ignore_changes = [secret_string]`, so values set out-of-band stick. The two
`rabbitmq-*-creds` secrets were created by hand as a manual prerequisite of the service
renames (see the comments in `deploy-staging.yml`).

### Front door (DNS, CloudFront, WAF, nginx)

| Hostname (staging) | Path in | Auth tier |
|---|---|---|
| `api.`, `grafana.`, `rabbitmq.`, `db.`, `barcode.`, `operator.`, `csadmin.`, `customize.` `.staging.packiot.app` | CloudFront (WAF) → nginx :443 → `127.0.0.1:<port>` | per `service_auth` map: `csadmin` group, `any` pool user, `api` (x-api-key on `/api/`), or origin-verify only |
| `operator-sbx.`, `operator-bispharma.`, `bi.` | CloudFront → nginx bespoke vhosts | tenant key injected by nginx / Superset guest token |
| `auth.staging.packiot.app` | nginx → oauth2-proxy :4180 | Cognito hosted UI |
| `refdata.`, `scan.` | nginx, deliberately no oauth2 gate | the service's own key/JWT auth |
| `amqp.` :5671, `cpack-ingest.` :8447, `ingest.` :8449 | **direct A-record to the EIP**, nginx TLS stream/proxy | source-IP allowlist in the app security group + ingest key |

`terraform/staging/edge.tf` has `edge_cutover = true` (live since 2026-08-05: service records
are ALIAS → CloudFront), WAF managed rules in `block` mode, rate limit 2000 req/5 min/IP, and
`edge_origin_lock = false` (443 on the origin is still world-open; nginx checks the
`X-Origin-Verify` header). The staged rollout is in
`terraform/staging/EDGE-PROTECTION-RUNBOOK.md`.

### Observability

Prometheus scrapes every Go service's metrics port, the exporters (node, cAdvisor, Postgres,
Redis, RabbitMQ, blackbox); Promtail ships all container logs to Loki; services send OTLP
traces to Tempo (some via Alloy); the DB box pushes through Alloy relays. Grafana has an
`audience/` folder (start here) and a `library/` folder (deep dives). 30+ alert rules exist;
Alertmanager → Slack is **parked** behind the `alerting` compose profile until a webhook is
configured. See [observability.md](../components/observability.md).

## Interfaces

| Direction | Interface | Producer → consumer |
|---|---|---|
| Inbound | HTTPS 443 via CloudFront | browsers, frontends → nginx → containers |
| Inbound | HTTPS 8447 / 8449, AMQPS 5671 | factory boxes → sparkplug agents / RabbitMQ (IP-allowlisted) |
| Inbound | Loki push 3101, Prometheus remote-write 3102 (private IP only) | DB-box Alloy → app-box Alloy |
| Inbound | GitHub → self-hosted runner (long poll) | Actions → staging app host |
| Outbound | Secrets Manager, S3, SSM, Cognito, ECR/Docker Hub | app instance role |
| Outbound | Postgres 5432 to legacy `packiot40` (SELECT-only) | legacy-replicator, mirror-worker-go |
| Operator access | AWS SSM Session Manager | engineers → app/DB hosts (no SSH keys shared) |

## Data it owns

| Artifact | Lifecycle |
|---|---|
| Docker named volumes (`rabbitmq-data`, `mosquitto-data`, `prom-data`, `loki-data`, `tempo-data`, outbox volumes, …) | Survive container recreate; lost only on `docker volume rm` or host rebuild |
| `/opt/packiot/.env` | Written once by `app_init.sh`; appended by deploy self-heal steps; hand edits persist |
| `/opt/packiot/rabbitmq/definitions.json` | Re-rendered every deploy from `monitoring/rabbitmq/definitions.template.json` + Secrets Manager |
| Prometheus TSDB | 15 days or 2 GB, whichever first (`--storage.tsdb.retention.*` in `compose.staging.yml`) |
| Loki logs | 72 h (`monitoring/loki/loki-local-config.yaml`) |
| Tempo traces | 48 h (`monitoring/tempo/tempo.yaml`) |
| EBS snapshots of the app host | AWS Backup, daily 03:00 UTC, 7-day retention (`terraform/staging/snapshots.tf`) |
| DB dumps | S3 backup bucket + `packiot-db-backup.timer` on the DB host (`terraform/staging/scripts/`) |
| Terraform state | S3 bucket `packiot-terraform-state-<account>`, keys `staging/terraform.tfstate`, `production/terraform.tfstate`, native S3 locking |

## Configuration that matters

| Knob | Where | Effect |
|---|---|---|
| `COMPOSE_PROFILES` | `/opt/packiot/.env` | Turns on profile-gated services: `superset`, `cpack-tee`, `shared-tee`, `alerting`, `plc-sim`, `s7`, `legacy-sim`, `legacy-comparator` |
| `-p stack` / `name: stack` | deploy workflows, `compose.production.yml` | Project name. Building or recreating under another name creates a **second** set of containers fighting over the same subnet |
| `ALLOY_GATEWAY_BIND` | `.env` (self-healed by deploy) | Must be the app host's private IP or the DB box's logs/metrics are refused |
| `edge_cutover`, `edge_origin_lock`, `waf_managed_rules_mode` | `terraform/staging/edge.tf` | DNS via CloudFront, origin lockdown, WAF enforcement |
| `IDENTITY_SENTINEL_ENFORCE` | `deploy-staging.yml` | `false` = the F3 int-overflow sentinel only warns |
| `app_instance_type`, `db_instance_type`, volume sizes | `terraform/staging/variables.tf` | Host sizing (volumes can only grow) |

## Failure modes & signals

| Failure | How you notice | Where to look / fix |
|---|---|---|
| Deploy red at **Fetch submodules** ("local changes would be overwritten") | Actions log | Someone hand-edited a submodule in the runner checkout (2026-08-19). The workflow now `git reset --hard`s submodules first. Never `git clean -fdx` there. |
| A recreated service left in `created` state | Service-state gate fails with the container's last 40 log lines | Compose create→start race (task #67). Re-run `up -d <svc>`; see [runbooks](../operations/runbooks.md#recreate-a-single-service) |
| RabbitMQ exits 127 after a host reboot | `IngestSilent` / `WritePathDry` alerts; `stack-rabbitmq-1` exited | Definitions file used to live in the runner workspace; a later checkout deleted it and dockerd created a directory there (2026-09-25). Now rendered to `/opt/packiot/rabbitmq/`. |
| Decoder "healthy" but publishing nothing after reboot | Ingest counters flat | Started before RabbitMQ; fixed with retry-then-exit (#1447, 2026-09-25). `docker restart sparkplug-decoder`. |
| Host OOM / thrash at 02:30 UTC | `node_memory_MemAvailable` cliff, SSM ConnectionLost, APIs down | Nightly historian DuckDB job had no memory limit (2026-09-25); now cgroup-capped (#1448) |
| Disk filling on the app host | `HostDiskFilling` / CloudWatch `app_disk_used_percent` | Build cache (22 GB on 2026-06-22, 15.4 GB on 2026-09-24). Deploy now runs `docker builder prune --keep-storage 5GB` |
| DB-box logs missing in Loki | `DbBoxMetricsMissing`; alloy-db "error sending batch" | `ALLOY_GATEWAY_BIND` unset → relays bound to loopback (≥2026-09-14 to 2026-09-24, fixed #1405) |
| Config edit "deployed" but not loaded | Metric/rule absent despite green deploy | Single-file bind mounts pin the old inode (#1406). Mount directories and reload. |
| Merged code but nothing deployed | No new run on `staging` | Submodule bump token (`PARENT_REPO_TOKEN`) invalid (operator4 broken ≥2026-09-14, fixed 2026-09-25); or GitHub push events arriving late — wait a few minutes before a manual dispatch, or you deploy twice |
| Two container sets / "Pool overlaps" | Duplicate containers, network error | Built or started under a different compose project name. Always use `-p stack` (staging). |

## History & decisions

- ADR-0003 (production parent stack), ADR-0005 (per-factory self-hosted runners), ADR-0006
  (workflow infrastructure refactor), ADR-0016/0032 (single-flow consolidation),
  ADR-0034 (Cognito + oauth2-proxy), ADR-0049/0057 (SSM as the box-access substrate) — see the
  [ADR index](../reference/adr-index.md).
- 2026-06-22: app disk full → volume 32→64 GB, weekly `docker-prune.timer`.
- 2026-07-10: plugin enable recreated RabbitMQ with fresh Mnesia and lost users → `load_definitions`.
- 2026-08-05: CloudFront/WAF cutover for staging.
- 2026-08-10 and 2026-08-12: `terraform -target` creations without committed config nearly
  destroyed prod resources on the next full plan (see [terraform.md](../components/terraform.md#failure-modes)).
- 2026-09-25: app host OOM and reboot incident (above).

## Go deeper

- [Compose topology](../components/compose-topology.md) — every container
- [CI/CD](../components/ci-cd.md) — every workflow and the deploy step order
- [Terraform](../components/terraform.md) — every AWS resource and how to plan safely
- [Observability](../components/observability.md) — metrics, logs, traces, alerts, dashboards
- [Wiki pipeline](../components/wiki-pipeline.md) — how this site is built and served
- [Runbooks](../operations/runbooks.md) · [Configuration reference](../reference/configuration.md)
