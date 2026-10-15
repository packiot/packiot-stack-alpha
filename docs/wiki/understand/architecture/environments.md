---
title: Environments
layer: 1
owner_area: platform
last_verified: 2026-10-13
---
# Environments

> **Layer 1 · Architecture.** Where each environment runs, how you reach it, and what is
> live where. Up: [Architecture overview](overview.md)

## Overview

| Environment | What runs | Where | Deployed by |
|---|---|---|---|
| **Local (dev)** | Service slices in Docker Compose (`dev/`, ADR-0060) on an anonymized week of CPACK data; never deployed, never synced | your machine | `make dev SVC=…`; see [Local development](../../build/develop/local-development.md) |
| **Staging** | The full new stack with real client data (CPACK tee, Bispharma live box, sandbox twin 2000003) | AWS us-east-1, EC2: app host + DB host + NAT | PR merged into `staging` → `deploy-staging.yml`; see [Branches, merging and deploying](../../build/develop/branches-and-merging.md) |
| **Production (legacy)** | `packiot40` (tsp12): Postgres + Hasura + Node-RED oeecloud, legacy APIs; front4 `master` at `go.packiot.com` | legacy production hosts | outside this repo |
| **Production (new stack)** | **Not promoted.** The `production` branch (a 2026-09-07 snapshot of the stack, old service names such as `oeecloud-worker`) runs on the prod app host against one DB `packiot` with the F3 schema in `public`; production clients are not switched to it. Defined by `compose.production.yml` and `terraform/production` (domain `prod.packiot.app`) | AWS us-east-1, production EC2 hosts (app, DB, Superset, GitHub runner, NAT) | push to `production` → `deploy-production.yml` on the self-hosted production runner. The promotion is the draft PR #1653 (`release/prod-promotion-2026-10` → `production`), waiting on go decisions |
| **Edge** | Per-factory boxes (readers, optional on-prem offline stack) | client sites; hybrid-activated SSM managed instances (`mi-…`) | edge-api Box Ops (csadmin) over AWS SSM |

Every client is served by **legacy production** today. When a page says "live", it means
staging unless it says otherwise.

## Staging hosts

| Host (Name tag) | Instance | Role |
|---|---|---|
| `packiot-staging-app` | `i-06c9547a2c7091ab7` (t4g.large) | All application containers: brokers, decoder, stream-engine, APIs, SPA containers, the shared Sparkplug agent, observability, the historian gateway; host nginx terminates TLS for every vhost. The only host allowed to read the legacy DB secret. |
| `packiot-staging-db` | `i-064bb36d1c454d861` (r7g.large, private `10.10.10.89`) | TimescaleDB container with `packiot_analytics` (and the old `packiot` DB). |
| `packiot-staging-nat` | `i-0d85d171e8e6abaeb` (t4g.nano) | NAT for the private subnets. |

Access is through **AWS SSM** (`aws ssm send-command` / Session Manager); there are no SSH
keys to share. Compose runs as project `stack`. Containers carry their compose labels;
recreate a single service from those labels rather than from memory (see
[Runbooks](../../build/operate/runbooks.md)).

## Staging URLs

| URL | What | Gate |
|---|---|---|
| `front.staging.packiot.app`, `staging.packiot.com` | front4 (AWS Amplify app, branch `staging`) | in-app Cognito login |
| `operator.staging.packiot.app`, `operator-sbx.…`, `operator-bispharma.…` | operator app for CPACK (read-only mirror) / sandbox / Bispharma | oauth2-proxy (any pool user) |
| `csadmin.staging.packiot.app`, `customize.staging.packiot.app` | CS Admin, Customization Hub | origin-verify; in-app Cognito login |
| `barcode.staging.packiot.app` | barcode app (sandbox tenant) | oauth2-proxy, `cs-admin` group |
| `api.staging.packiot.app` | edge-api under `/api/`; **API docs portal** at `/docs/` | `/api/` by API key or JWT; `/docs/` cs-admin SSO |
| `refdata.staging.packiot.app` | read-api (public carve-out; `/metrics` and `/openapi.json` return 404) | API key or Cognito Bearer |
| `scan.staging.packiot.app` | barcode-service | JWT (tenant from the verified token) |
| `bi.staging.packiot.app` | Superset | Cognito (Superset OAuth) |
| `grafana.…`, `rabbitmq.…`, `db.…` (CloudBeaver) | internal consoles | oauth2-proxy, `cs-admin` group |
| `auth.staging.packiot.app` | oauth2-proxy sign-in | — |
| `ingest.staging.packiot.app:8449` | shared raw-tag front door `POST /v1/tags` → `sparkplug-agent-shared` | `X-Ingest-Key` + per-box source /32 in the security group |
| `cpack-ingest.staging.packiot.app:8447` | CPACK raw-tag front door `POST /v2/tags` → `sparkplug-agent-shared` (nginx injects `X-Ingest-Group: CPACK`; `/v1/tags` is blackholed) | `X-Ingest-Key` |
| `wiki.packiot.app` | this wiki (served from the production app host, see [wiki pipeline](../components/wiki-pipeline.md)) | oauth2-proxy |

Source: `terraform/staging/variables.tf` (`services`, `service_auth`), `terraform/staging/dns.tf`,
`terraform/staging/user_data/nginx_setup.sh`. The ingest doors are not behind CloudFront.

## Data sources per tenant (staging)

| Tenant | Telemetry | POs and operator actions |
|---|---|---|
| CPACK (3) | CPACK factory Node-RED tee → `cpack-ingest` → shared agent | legacy replication only; edge-api refuses ent-3 PO, downtime and shift writes (403 `MIRROR_TENANT_WRITE_BLOCKED`) |
| Bispharma (5) | live Bispharma box (thin reader) → `ingest` → shared agent | the apps (operator, csadmin) **until Bispharma's production go-live**; from then on a **read-only mirror of production** ([ADR-0064](../../adr/0064-staging-mirror-of-production-after-go-live.md)): `prod-reflector` copies everything except the raw series from production every minute, every write is refused (403 `MIRROR_TENANT_WRITE_BLOCKED`, "make this change in production"), the enterprise is named **Bispharma (mirror)**. Switch: `PROD_MIRROR_ENTERPRISES=5`; runbook `docs/runbooks/staging-mirror-of-production.md` |
| Sandbox (2000003) | copy of CPACK (`oeecloud-fanout` → `SBXCPACK`, when enabled) | replication of CPACK into the sandbox + test writes; held during a hands-on session, then reset to CPACK 4 h after the last change (and a nightly tidy heal); see [Sandbox twin](../components/sandbox-twin.md) |
| Incoplast (4) | HTTPS tee path through `ingest-shim` (`sparkplug.data.incoplast`) | — |

## Which environment to test in

| Environment | Enterprise | Use |
|---|---|---|
| Pack4 production | C-PACK (legacy 1) | source of truth for expected behaviour; never test here |
| CPACK-Staging | 3 | read-only mirror of production; operator writes refused with `MIRROR_TENANT_WRITE_BLOCKED` |
| Bispharma (mirror) | 5 | after Bispharma's production go-live: read-only mirror of the **new** production; every write refused; test Bispharma flows in production's own staging-like checks or the sandbox, never here |
| SANDBOX-CPACK | 2000003 | where write flows are tested; resets completely to CPACK-Staging (barcode scans included) |

Testers: [Sandbox for testing](../../use/sandbox-for-testing.md). Product and management:
[Test environments, explained](../../learn/test-environments.md).

## Gotchas

- Required checks on a PR into `staging` are **"Validate compose files"** and **"dev slices
  gate"**; the deploy runs after the merge.
- GitHub push events can reach Actions several minutes late; wait before dispatching a deploy
  by hand, or you will deploy twice.
- The historian gateway (`compose.historian-gateway.yml`) is not started by the deploy
  workflow; recreate it with its own env file (see
  [historian gateway](../components/historian-gateway.md)).
- Alertmanager runs only under the `alerting` compose profile, which the deploy adds only when
  the Slack webhook key exists in Secrets Manager; without it, alerts fire in Prometheus but
  page nobody.
- Never run heavy Docker operations (large commits, storage-driver changes) on the shared app
  host; sandbox simulator boxes run as containers there.
