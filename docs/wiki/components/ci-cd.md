---
title: CI/CD
layer: 3
owner_area: platform
last_verified: 2026-10-09
---
# CI/CD

> **Layer 3 · Components** — every GitHub Actions workflow in `.github/workflows/`: what
> triggers it, where it runs, what it gates or deploys, and how to dispatch and roll back.
> For engineers merging, deploying or debugging a red check.
> Up: [Platform & operations](../subsystems/platform.md) · The everyday procedure (branch → PR → merge → verify):
> [Branches, merging and deploying to staging](../operations/branches-and-merging.md)

## Responsibility

CI/CD is accountable for two things: nothing reaches `staging` that fails the structural,
security and correctness gates, and every commit on `staging` (or `production`) becomes the
running stack on its host with every expected service up.

## At a glance

| Item | Value |
|---|---|
| Location | `.github/workflows/` (19 files) |
| Deploy branches | `staging` → staging app host; `production` → new-stack production app host |
| Protected branch | `staging` only: ruleset "Protect staging" — PR required (0 approvals), `Validate compose files` the **only** required check, no force-push/delete, no bypass actors. The submodule repositories (private, GitHub Free) have **no** branch protection at all |
| Hosted runners | `ubuntu-latest` (metered minutes): lint, tests, gitleaks, wiki build |
| Self-hosted runners | `[self-hosted, staging, linux, arm64]` = **the staging app host itself**; `[self-hosted, production, linux, arm64]` = the production app host; per-client labels at factories |
| Serialization | `concurrency: deploy-staging` / `deploy-production`, `cancel-in-progress: false` (deploys queue, never cancel) |
| Submodules built | staging: `edge-api`, `edge-node-red`, `operator`, `csadmin`; production: `edge-api`, `operator`, `csadmin`. `front4` is a submodule but deploys from its own repo. |

## Inputs & outputs

Inputs: pushes/PRs on this repo; bot PRs from submodule repos; manual `workflow_dispatch`;
Secrets Manager (read on the self-hosted runner by the instance role); repo secrets
`AWS_ROLE_ARN`, `STAGING_INGEST_API_KEY`, `PRODUCTION_INGEST_API_KEY`; repo variable
`WIKI_S3_BUCKET`. Outputs: running containers on the hosts, artifacts (wiki site, client edge
bundles), GHCR image `ghcr.io/packiot/packiot-postgres:latest`, S3 wiki sync.

## Internal design

### Workflow catalogue

| Workflow | Trigger | Runner | Does | Gate? |
|---|---|---|---|---|
| `deploy-staging.yml` | push `staging`, dispatch | `gate`: ubuntu · `deploy`: self-hosted staging | `gate` skips the run when `staging` already moved past its commit (#1642); `deploy` builds + deploys the staging stack, post-deploy gate and diagnostics | deploy fails red if any service is down |
| `deploy-production.yml` | push `production`, dispatch | self-hosted production | `compose.production.yml build` + `up -d --remove-orphans`; diagnostic `ps` + ERROR-log count | no hard gate |
| `pr-validation.yml` | PR → `staging`/`development`, dispatch | ubuntu | `Validate compose files`: `docker compose config --no-interpolate -q`; `packml ratchet (ADR-0061)`: `scripts/ci/packml-ratchet.sh` (per-file shrink-only baseline of PackML references; exceptions in `scripts/ci/packml-allowlist.txt`) | compose: **required**; ratchet: hard, not required |
| `dev-slices.yml` | PR → `staging` touching `dev/**`, `db/migrations/**`, `services/**`, `customize/**`, `grafana/**`, broker configs, a submodule pin, `Makefile`; dispatch | ubuntu (matrix) | boots the dev environment per slice (`tier0-grafana`, `pipeline`, `barcode`, `edge`) from the published dev seed and runs `make dev-smoke`; `edge` needs repo secret `DEV_SUBMODULES_TOKEN` and is **skipped (still green)** without it — see [Local development](../operations/local-development.md) | hard, not required |
| `dev-seed-build.yml` | dispatch only | self-hosted staging (reads staging read-only) | builds + publishes the anonymized dev seed `ghcr.io/packiot/devseed` (extract → anonymize → leak gate → package → validate) | — |
| `emergency-db-restore.yml` | dispatch only (typed confirmation) | self-hosted staging | **staging** emergency restore: `terraform/staging/scripts/restore-db.sh` (side DB → verify gate → rename swap), stops and restarts the writers. Runbook `docs/runbooks/emergency-db-restore.md`; see [DBA guide](../operations/dba-guide.md) | — |
| `gitleaks.yml` | every PR, push `staging` | ubuntu | pinned gitleaks 8.21.2, full history, `.gitleaks.toml` | blocks merge on a finding |
| `superset-rls-isolation.yml` | PR → `staging`, dispatch | ubuntu | ephemeral Postgres; 2-tenant RLS isolation on `bi.*` views; overlay is profile-gated | intended required check (fails, never skips: `SUPERSET_GATE_REQUIRE=1`) |
| `go-services.yml` | PR → `staging`/`development` touching `services/{mirror-worker-go,stream-engine,ingest-shim,operator-gateway,sparkplug-decoder,read-api,analytics-sync}/**` | ubuntu | per service `go vet`, `go test -race`, `go build`; govulncheck + golangci-lint soft; stream-engine golden SQL fixtures vs Postgres 15 | hard for vet/test/build; not yet a required check |
| `refdata-contract-drift.yml` | PR → `staging`/`development` (path filter), dispatch | ubuntu | `contract-selfcheck`: read-api dataset/route contract vs golden; `live-drift` (dispatch only): SELECT-only diff against prod via SSM on the app EC2 | self-check on PRs |
| `dashboard-lint.yml` | PR touching `grafana/dashboards/**` etc.; push `staging`/`production` | ubuntu + self-hosted staging | structure lint (datasource uids, no phantom metrics); **hardproof**: every Prometheus tile returns data from the live staging Prometheus | lint hard; hardproof `continue-on-error` |
| `customization-flow-lint.yml` | PR → `staging`/`development` touching `clients/**/customizations/**` | ubuntu | self-tests the linter, then lints governed Node-RED customization flows | hard (glob currently empty → passes) |
| `build-wiki.yml` | push `staging`/`production` or PR touching docs/wiki paths; dispatch | ubuntu | mkdocs build → artifact; on push, OIDC → `aws s3 sync` | build must succeed — see [wiki pipeline](wiki-pipeline.md) |
| `build-postgres.yml` | push `main` touching `db/**`, dispatch | ubuntu (QEMU arm64) | builds + pushes `ghcr.io/packiot/packiot-postgres:latest` | — |
| `sandbox-selfheal.yml` | cron `0 6 * * *` (06:00 UTC), dispatch | self-hosted staging | `SANDBOX_LOCAL=1 bash scripts/provision-sandbox-tenant.sh --heal` (re-clone ent 3 config into 2000003, wipe test transactions) | — |
| `inject-counter-fixture.yml` | dispatch (`value`) | self-hosted staging | builds `cmd/inject-counter-fixture`, publishes NBIRTH+NDATA for group `E2EFIXTURE`, diffs `calc_*` metrics | diagnostic |
| `inspect-edge-transformer.yml` | dispatch | self-hosted staging | read-only dump of `sparkplug-decoder` env, logs, health, metrics | diagnostic |
| `client-edge-deploy.yml` | dispatch (`client`, `target` staging/production, `edge_model` nodered/reader, `confirm`) | `[self-hosted, <client>]` runner **at the factory** | deploys `compose.edge.yml` bundle; verifies agent `/healthz`, uplink connected, unmapped tags not growing | fails red on data-continuity loss |
| `generate-client-bundle.yml` | dispatch | self-hosted production | builds a per-client edge bundle artifact; signs a client mTLS cert with the prod CA from Secrets Manager, shreds the CA key | — |

Workflows that live in **other** repositories but drive this one: `edge-api`, `operator4` and
`edge-node-red` each have `bump-stack-submodule.yml` (verified 2026-10-09; **`csadmin` has none** —
its pin is bumped by hand in a PR). On a push to the submodule's `staging` it opens a bot PR here
(`chore(submodule): bump <name> to <sha> (staging) (auto)`) and enables auto-merge (squash). A push
to the submodule's `development` targets this repo's **retired** `development` branch, which is
unprotected, so the bot merges it directly. It authenticates with the submodule repo's
`PARENT_REPO_TOKEN` secret (needs contents + pull-requests write on this repo).

!!! warning "Bump PRs wait only for the required check"
    Auto-merge fires once `Validate compose files` passes; `dev-slices`, `go-services` and the other
    checks on the bump PR do not block it. The submodule repository's own CI is the effective gate.

### deploy-staging.yml step by step

Runs on `[self-hosted, staging, linux, arm64]` in
`/opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha`.

| # | Step | What it does | Fails deploy? |
|---|---|---|---|
| 1 | Checkout main repo | `submodules: false`, `persist-credentials: false` (so the repo-scoped token is not used for private submodules) | yes |
| 2 | Fetch submodules | `git submodule foreach 'git reset --hard'` (self-heal hand edits), then `sync` + `update --init --force` for `edge-api edge-node-red operator csadmin` via the PAT rewrite in `/root/.gitconfig` | yes |
| 3 | Link .env | `ln -sf /opt/packiot/.env .env` | yes |
| 4 | Ensure `ALLOY_GATEWAY_BIND` | appends the host's private `10.*` IP if absent | yes (non-10.* IP) |
| 5 | Ensure `HIST_GW_SVC_PASSWORD` | mirrors `packiot/staging/historian-svc` into `.env` if absent | warns only |
| 6 | Generate RabbitMQ definitions | template + admin creds from `.env` + `stream-engine`/`sparkplug-decoder` passwords from Secrets Manager → `/opt/packiot/rabbitmq/definitions.json` (atomic `mv`) | yes |
| 7 | Materialize Alertmanager Slack webhook | writes `monitoring/alertmanager/slack_api_url` if `packiot/staging/app.slack_api_url` is set | yes (only on AWS error) |
| 7a | Pull barcode-app from GHCR | optional; inert until its secret exists | no |
| 7b | Resolve compose profiles | `.env` `COMPOSE_PROFILES` + `shared-tee` | yes |
| 8 | Build images | `docker compose -f compose.staging.yml -f compose.superset.yml -p stack build` | yes |
| 9 | Deploy | `… -p stack up -d --remove-orphans` | yes |
| 10 | Prune | `docker image prune -f`; `docker builder prune -f --keep-storage 5GB` | yes |
| 11 | Reload Prometheus | `POST /-/reload` via `--network container:prometheus` | no |
| 12 | Reload Alloy | `POST :12345/-/reload` | no |
| 13 | Restart postgres-exporter | only if `monitoring/postgres-exporter/` changed since `github.event.before` (always on dispatch) | no |
| 13b | Restart Loki | only if its config changed (Loki reads config at startup only; #1559) | no |
| 14 | Reload Alertmanager | only if running | no |
| 15 | **Service-state gate** | enumerates services from `compose config`; one-shots must be `exited(0)`, others `running` (+`healthy` if they have a HC); 300 s deadline; prints last 40 log lines per failure. Runs even if step 9 failed (`if: !cancelled()`) | **yes** |
| 16 | Inject synthetic Sparkplug counter | group `E2EFIXTURE` on mosquitto; never a real tenant group | no |
| 17 | Inspect sparkplug-decoder | env, logs, health, `calc_/mqtt_/shadowpub_/outbox_` metrics | no |
| 18 | Extend RMQ perms for `edge-transformer` | idempotent PUT on the management API (legacy user) | no |
| 19 | DB schema audit | SELECT-only report: table sizes, hypertables, caggs, roles, Hasura tracked tables | no |
| 20 | F3 int-overflow sentinel | `stream-engine --identity-sentinel`; `IDENTITY_SENTINEL_ENFORCE=false` → warn only | no (while `false`) |
| 21 | Chaos test | **stops `stack-rabbitmq-1`**, injects 5 messages, restarts it, checks the decoder outbox drains to 0 | no |

!!! warning "Every staging deploy briefly stops RabbitMQ"
    Step 21 stops and restarts the broker on every run (tens of seconds). Durable producers
    queue in their outboxes; this is the durability contract being tested, but expect a short
    ingest gap in dashboards around each deploy.

Rendering note: the gate uses the same `-f compose.staging.yml -f compose.superset.yml -p
stack` composition as build/deploy, so profile-gated services only count when their profile is on.

### Self-hosted runner model

- The staging runner is installed by `terraform/staging/user_data/app_init.sh` into
  `/opt/actions-runner` with labels `self-hosted,staging,linux,arm64`. A single runner means
  jobs on it are serialized, and CI jobs share CPU/RAM with the running stack (t4g.large).
- Its checkout is **persistent, mutable state**. Hand edits there (especially in submodules)
  used to wedge every deploy (2026-08-19). Do not `git clean -fdx` it: `.env` symlink and
  staged certs live there.
- **GitHub Free plan gotcha:** org-level self-hosted runners show online but never receive
  jobs from private repos. Runners must be registered **per repository** (proven 2026-08-12).
  Wiring a repo to a runner = register a repo-level runner **and** set `runs-on` labels.
- Production has two extra boxes in `terraform/production`: `github_runner.tf`
  (`packiot-production-github-runner`, repo-level runners for edge-api/back4-api) and
  `ci_runner.tf` (`packiot-ci-runner`, labels `self-hosted,linux,x64,packiot-ci`). See
  `docs/ci-selfhosted-runner-runbook.md`.

## Configuration

| Setting | Where | Effect |
|---|---|---|
| `IDENTITY_SENTINEL_ENFORCE` | `deploy-staging.yml` env | `"true"` makes the overflow sentinel fail the deploy |
| `WIKI_S3_BUCKET` (var), `AWS_ROLE_ARN` (secret) | repo settings | enable the wiki S3 sync job |
| `STAGING_INGEST_API_KEY`, `PRODUCTION_INGEST_API_KEY` | repo secrets | ingest key written into client edge `.env` |
| `PARENT_REPO_TOKEN` | each submodule repo | lets bump bots open PRs here |
| `GITLEAKS_VERSION` | `gitleaks.yml` | pinned scanner version |
| Ruleset "Protect staging" | repo settings | requires PR + `Validate compose files` |

## Data & invariants

- Deploys never cancel each other. A queued run whose commit `staging` has already moved past is skipped by the `gate` job, so the newest commit always deploys last (before #1642 an older run could finish last and roll code back).
- The deploy does not trust `up -d`'s exit code; it re-derives state from `ps`.
- Secrets never enter hosted CI: prod DB drift checks run on the host via SSM; the prod CA key
  is used on the production runner and shredded.
- Fixtures publish only to the synthetic `E2EFIXTURE` group (the staging broker carries live
  client data).

## Observability

- Actions UI: deploy log sections per step; the gate prints `OK <svc>` lines and `::error`
  annotations.
- `gh run list --workflow deploy-staging.yml --limit 5` and `gh run view <id> --log-failed`.
- After a deploy, verify effects (metrics present, containers recreated after merge time),
  not just a green run.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Submodule checkout conflict | red at "Fetch submodules" | dirty runner checkout | now self-healing (step 2); if persists: `git reset --hard` + `git submodule update --init --recursive --force` in the runner dir |
| Bump PR never appears | submodule merged, nothing deploys | `PARENT_REPO_TOKEN` expired/invalid (broken 2026-09-01; operator4 broken ≥2026-09-14, fixed 2026-09-25) | rotate the token; bump manually with a PR |
| Two deploys for one change | duplicate runs | push event arrived late and someone dispatched by hand | wait a few minutes before dispatching |
| "Phantom merge" | PR merged but behaviour unchanged | PR carried docs, not the code (2026-09-20, #1332/#1333) | verify merged diff, and container `Created` time vs merge time |
| Gate: service `created` | red at gate | compose start race | `up -d --no-deps <svc>` then re-run |
| Job queued forever | self-hosted job never starts | runner offline, or org-level runner on Free plan | check runner status in repo settings; register repo-level |
| Hosted jobs stop | "minutes limit" | GitHub-hosted minutes exhausted | self-hosted deploys still work; front4's Amplify can be started via `aws amplify start-job` |
| Build OOM on runner | runner killed mid-build | builds share 8 GB with the stack | swap exists (4 GB); avoid parallel heavy builds |

## Operating it

Dispatch a deploy (re-deploy current `staging` HEAD):

```bash
gh workflow run deploy-staging.yml --ref staging
gh run watch "$(gh run list --workflow deploy-staging.yml --limit 1 --json databaseId -q '.[0].databaseId')"
```

Rollback (staging): there is no image registry or tag to roll back to; the deploy builds from
source. Roll back by **reverting the commit on `staging`** through a PR (the revert merges and
deploys like any change). For a submodule, revert its bump PR (the gitlink returns to the
previous SHA). For an urgent single-service rollback on the host, check out the previous
revision's service directory in the runner checkout and recreate only that service — then
land the revert so the next deploy does not undo you.

Production deploy: merge to `production` (or dispatch `deploy-production.yml`). Production
branch changes follow `docs/adr/reference/production-recut-runbook.md` and need user sign-off.

## Tests

The gates are the tests: `pr-validation.yml`, `go-services.yml` (unit + golden),
`superset-rls-isolation.yml`, `refdata-contract-drift.yml`, `dashboard-lint.yml`,
`customization-flow-lint.yml`, `gitleaks.yml`; post-deploy: service-state gate, sentinel,
chaos test.

## Source map

| Path | What's there |
|---|---|
| `.github/workflows/deploy-staging.yml` | staging deploy (step order above) |
| `.github/workflows/deploy-production.yml` | new-stack production deploy |
| `.github/workflows/pr-validation.yml`, `gitleaks.yml`, `go-services.yml`, `superset-rls-isolation.yml`, `refdata-contract-drift.yml`, `dashboard-lint.yml`, `customization-flow-lint.yml` | PR gates |
| `.github/workflows/build-wiki.yml` | docs site |
| `.github/workflows/client-edge-deploy.yml`, `generate-client-bundle.yml` | client edge delivery |
| `.github/workflows/sandbox-selfheal.yml` | nightly sandbox reset |
| `.github/workflows/inject-counter-fixture.yml`, `inspect-edge-transformer.yml`, `build-postgres.yml` | diagnostics, DB image |
| `.gitleaks.toml` | secret-scan allowlist |
| `monitoring/rabbitmq/definitions.template.json` | broker users/permissions template |
| `terraform/staging/user_data/app_init.sh` | runner install + first boot |
| `docs/ci-selfhosted-runner-runbook.md` | org CI runner runbook |
