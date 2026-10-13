# packiot-stack-alpha

The integration monorepo of the **new Packiot stack**: the in-tree services, the Docker Compose
files, Terraform, the analytics DB migrations, the local dev environment and the documentation.
Five product repos are pinned here as Git submodules, so one checkout builds and deploys the whole
stack.

Packiot is an industrial IoT / OEE platform: it reads counters, speed and state from factory PLCs
(SparkPlug B over MQTT), computes OEE (Availability × Performance × Quality) and serves it to plant
managers, machine operators and Packiot's Customer Success team. The new stack runs on **staging**
(Docker Compose on AWS EC2, TimescaleDB "analytics DB" `packiot_analytics`, RabbitMQ). Production
clients are still served by the **legacy platform** (`packiot40`, Hasura, Node-RED `oeecloud`);
new-stack production is defined in this repo but promotion is a separate, gated step.

## Repo map

| Path | What | README |
|---|---|---|
| `services/` | In-tree services (Go, plus two small Node.js programs and a Postgres extension image) | [services/README.md](services/README.md) |
| `dev/` | Local development environment (ADR-0060): Tier 0 data plane + per-service slices, anonymized seed | [dev/README.md](dev/README.md) |
| `db/` | Analytics DB layer: `db/migrations/` (applied by hand: dry-run → apply → verify; there is no runner), backfills, cutover and reconcile SQL, the Postgres image | [db/README.md](db/README.md) |
| `compose.staging.yml` | The staging app host's stack (compose project `stack`) | — |
| `compose.production.yml` | The new-stack production app host (single-flow, `public` schema; not promoted yet) | — |
| `compose.superset.yml` | Superset overlay (profile `superset`), deployed together with `compose.staging.yml` | — |
| `compose.historian-gateway.yml` | The historian gateway (not started by the deploy workflow; see its README) | [services/historian-gateway/README.md](services/historian-gateway/README.md) |
| `compose.onprem-edge.yml` | On-prem edge box: mosquitto, `sparkplug-agent`, local decoder, floor dashboard | — |
| `terraform/` | AWS infrastructure for staging and production (app EC2, DB EC2, NAT, IAM, Cognito, S3…) | [terraform/README.md](terraform/README.md) |
| `monitoring/` | Prometheus, Alertmanager, Loki, Promtail, Alloy, Tempo, exporters, RabbitMQ definitions | [monitoring/README.md](monitoring/README.md) |
| `grafana/` | File-provisioned dashboards (folders `audience/`, `library/`) and datasources | [grafana/README.md](grafana/README.md) |
| `configs/` | Config files mounted by compose (mosquitto, fan-out, Superset, CloudBeaver, pgBackRest) | — |
| `customize/` | The Customize SPA (React + Vite; in-tree, not a submodule) | — |
| `simulator/` | The Python HTTP simulator | [simulator/README.md](simulator/README.md) |
| `e2e/` | Cross-frontend Playwright suite run against staging | [e2e/README.md](e2e/README.md) |
| `tests/` | `superset/` tenant-isolation tests (run by `superset-rls-isolation.yml`); `integration/` pytest suite (not wired into any workflow) | — |
| `scripts/` | Operational and CI scripts (`build-wiki.sh`, `ci/packml-ratchet.sh`, backfills…) | — |
| `systemd/` | Timers installed on hosts (historian append, integrity monitor, data oracle, sandbox heal) | — |
| `ops/dash/` | Static internal service directory (`dash.packiot.app`) | [ops/dash/README.md](ops/dash/README.md) |
| `adminer/`, `docker/` | Adminer image (auto-login) and the derived Superset image | — |
| `docs/` | Documentation: the layered wiki, ADRs, runbooks, OpenAPI specs | [docs/README.md](docs/README.md) |
| `wiki/` | mkdocs-material config for the wiki site | — |
| `edge-api` (submodule) | NestJS control plane: admin/CS-Admin CRUD, PO control, downtimes, onboarding ([packiot/edge-api](https://github.com/packiot/edge-api)) | in the submodule |
| `front4` (submodule) | The product frontend (React) ([packiot/front4](https://github.com/packiot/front4)) | in the submodule |
| `operator` (submodule) | The operator shop-floor app ([packiot/operator4](https://github.com/packiot/operator4)) | in the submodule |
| `csadmin` (submodule) | The CS-Admin onboarding SPA ([packiot/csadmin](https://github.com/packiot/csadmin)) | in the submodule |
| `edge-node-red` (submodule) | Edge Node-RED flows ([packiot/edge-node-red](https://github.com/packiot/edge-node-red)) | in the submodule |

Every submodule tracks its own `staging` branch (`.gitmodules`).

## Service catalog

| Service | Language | What | Runs on | README | OpenAPI spec |
|---|---|---|---|---|---|
| `analytics-sync` | Go | Replays operator actions (`user_logs`) into the analytics DB; two binaries: `analytics-sync` (idle on staging) and `legacy-replicator` (CPACK twin feed from the legacy DB) | staging | [README](services/analytics-sync/README.md) | — |
| `barcode-service` | Go | Durable box-scan ingest with a server-authoritative, gapless label sequence per production order (ADR-0040) | staging | [README](services/barcode-service/README.md) | [barcode-service](docs/api/openapi/barcode-service.openapi.json) |
| `cognito-user-migration` | Node.js (AWS Lambda) | Cognito User Migration trigger: moves a Firebase user into the staging Cognito pool on first sign-in (ADR-0034) | staging (Lambda, Terraform) | [README](services/cognito-user-migration/README.md) | — |
| `edge-session-broker` | Node.js | Runs AWS `session-manager-plugin` for edge-api: SSM shell (WebSocket) and on-box web UIs (HTTP proxy) of client boxes (ADR-0057) | staging | [README](services/edge-session-broker/README.md) | — |
| `edge-transformer` | — | Not a service: leftover directory from the rename to sparkplug-decoder (one orphan test file) | — | [README](services/edge-transformer/README.md) | — |
| `historian-gateway` | PostgreSQL + pg_duckdb (SQL, shell) | One SQL surface over hot analytics-DB rows (postgres_fdw) and the cold S3 Parquet historian (DuckDB) | staging (started by hand) | [README](services/historian-gateway/README.md) | — |
| `ingest-shim` | Go | HTTPS → RabbitMQ ingress for a client's Node-RED tee: one envelope per request onto `oee` with publisher confirms | staging; prod compose | [README](services/ingest-shim/README.md) | [ingest-shim](docs/api/openapi/ingest-shim.openapi.json) |
| `mirror-worker-go` | Go | Retired legacy-production → staging mirror for CPACK (profile `legacy-comparator`, off since 2026-08-13) | staging (off) | [README](services/mirror-worker-go/README.md) | — |
| `oeecloud-fanout` | Go | Clones one tenant's decoded stream into a sandbox tenant (staging: CPACK → SBXCPACK, enterprise 2000003) | staging | [README](services/oeecloud-fanout/README.md) | — |
| `operator-gateway` | Go | HTTPS bridge: a client's own operator-app actions (Node-RED tee) → edge-api calls | staging; prod compose | [README](services/operator-gateway/README.md) | [operator-gateway](docs/api/openapi/operator-gateway.openapi.json) |
| `read-api` | Go | The read plane: tenant-scoped HTTP reads over the analytics DB for front4, operator, csadmin and integrations | staging; prod compose | [README](services/read-api/README.md) | [read-api](docs/api/openapi/read-api.openapi.json) |
| `sparkplug-decoder` | Go | SparkPlug B decoder (MQTT totalizers → increments → `oee` exchange); the same module builds the edge binaries (`sparkplug-agent`, PLC readers, simulators) | staging; prod compose; edge boxes | [README](services/sparkplug-decoder/README.md) | [sparkplug-agent](docs/api/openapi/sparkplug-agent.openapi.json), [onboard-api](docs/api/openapi/onboard-api.openapi.json) |
| `stream-engine` | Go | The OEE engine: consumes decoded envelopes, writes Bronze/Silver, runs the jobs that compute Gold OEE, events, PO runtime, UNS and reports | staging; prod compose | [README](services/stream-engine/README.md) | — |

"prod compose" means the service is defined in `compose.production.yml`; new-stack production is not
promoted yet. Services built from the submodules (edge-api, the SPAs, edge Node-RED) and third-party
containers (RabbitMQ, mosquitto, Grafana, Superset, pgbouncer…) are listed in `compose.staging.yml`.
Specs are browsable at https://api.staging.packiot.app/docs/ (behind the CS-Admin SSO); edge-api's spec
lives in the edge-api repo.

## Quick start: local development in one minute

```sh
git submodule update --init --recursive   # only the edge/SPA slices need the (private) submodules
docker login ghcr.io                      # GitHub token with read:packages (the seed image is private)
make dev                                  # Tier 0: postgres (seeded), rabbitmq, mosquitto, redis, minio
make dev SVC=grafana                      # a slice: grafana + what it depends on
FRONT4_DIR=../front4-staging make dev SVC=front4   # read-api + CORS proxy + front4 at http://localhost:5173
make dev-smoke SVC=grafana                # health + one real request per service (what CI runs)
make dev-down                             # stop (volumes kept)
```

Dev users and passwords (dev Cognito pool, tenant 3):
`aws secretsmanager get-secret-value --secret-id packiot/dev/cognito --query SecretString --output text`.
Every host port binds `127.0.0.1`; the only outbound calls are to Cognito (login). Details, every slice and
the replay pipeline: [dev/README.md](dev/README.md). `make help` lists the remaining targets (dev environment,
OpenAPI export, staging Terraform).

The previous all-in-one local harness (`compose.development.yml`, `make up`) was removed in ADR-0060 P2; its
README is archived at [docs/archive/legacy-local-harness-README.md](docs/archive/legacy-local-harness-README.md).

## Environments

```text
  development (dev/ slices, laptop or CI)  →  staging (integration + e2e)  →  production
  anonymized 7-day seed, dev Cognito pool      AWS EC2, real client data      new stack: defined, not
  make dev SVC=…                               in parallel with legacy        promoted; legacy serves clients
```

| | Development | Staging | Production |
|---|---|---|---|
| Defined in | `dev/compose.yml` (project `packiot-dev`) | `compose.staging.yml` (+ `compose.superset.yml`, `compose.historian-gateway.yml`); `terraform/staging/` | `compose.production.yml`; `terraform/production/` |
| Hosts | your machine / GitHub runners | app EC2 (the compose stack, behind nginx) + a separate DB EC2 (PostgreSQL 15 + TimescaleDB) | app EC2 + DB EC2 (same shape) |
| Deployed by | `make dev` | push to `staging` → **Deploy to Staging** (`.github/workflows/deploy-staging.yml`, self-hosted runner on the app host) | push to `production` → **Deploy to Production** (`deploy-production.yml`); changed only by a planned promotion |
| Data | anonymized seed `ghcr.io/packiot/devseed` (largest client, 7 days) | real client feeds (CPACK = enterprise 3, Bispharma = 5) and the CPACK sandbox twin (2000003) | legacy `packiot40` is the system of record for production clients |

Design: [ADR-0060](docs/adr/0060-local-development-environment-and-cpack-dev-seed.md) (dev → staging →
production ladder).

## Contributing

The full procedure is in [CONTRIBUTING.md](CONTRIBUTING.md). In short:

1. Branch off `staging`: `git switch -c <type>/<thing> origin/staging`. `staging` is the integration branch
   and every PR targets it. Do not push `main` (frozen), `development` (retired) or `production`.
2. Run the service's tests and its dev slice (`make dev SVC=… && make dev-smoke SVC=…`).
3. `gh pr create --base staging`. The ruleset "Protect staging" requires a PR and two status checks:
   **Validate compose files** (`pr-validation.yml`) and **dev slices gate** (`dev-slices.yml`). Other
   workflows run on relevant paths too (Go services vet/test/build, OpenAPI export drift, packml ratchet,
   gitleaks, dashboard lint…); merge only when every check on the head commit is green.
4. Merging to `staging` runs **Deploy to Staging**: on the app host it builds the images
   (`docker compose -f compose.staging.yml -f compose.superset.yml -p stack build`), runs `up -d --remove-orphans`
   and gates on every expected service being running/healthy.

Submodule changes are merged in the submodule's own `staging` branch; edge-api, operator4 and edge-node-red
then open a pin-bump PR here automatically. `db/migrations/` has no runner: dry-run, apply and verify on
staging, then merge.

## Where the docs live

| What | Where |
|---|---|
| Engineering wiki (layered: start here → architecture → subsystems → components → reference/ops) | source in [docs/wiki/](docs/wiki/index.md), published at **wiki.packiot.app** (behind SSO) |
| How to write docs | [docs/WIKI-STYLE.md](docs/WIKI-STYLE.md) |
| Architecture Decision Records | [docs/adr/](docs/adr/) |
| Runbooks | [docs/runbooks/](docs/runbooks/), indexed in [docs/wiki/operations/runbooks.md](docs/wiki/operations/runbooks.md) |
| HTTP API specs (OpenAPI 3.1) | [docs/api/openapi/](docs/api/openapi/) (`make openapi`); browsable at **https://api.staging.packiot.app/docs/** (behind the CS-Admin SSO) |
| Per-service READMEs | [services/README.md](services/README.md) |

<!-- wiki-links: added in cross-reference pass -->
