---
title: Repositories
layer: 4
owner_area: platform
last_verified: 2026-10-13
---
# Repositories

> **Layer 4 · Reference** — every GitHub repository in the `packiot` organisation that matters to the
> platform: what it is for, where its README is, which branch deploys where, what CI runs and whether a bump
> bot moves it into the stack. For any engineer about to push somewhere. Up: [Reference](index.md)

How to *work* in these repositories (branching, waiting for checks, merging) is in
[Branches, merging and deploying to staging](../build/develop/branches-and-merging.md). The workflows of the
stack itself are explained in [CI/CD](../understand/components/ci-cd.md). Services *inside* the stack (Go
services, brokers, databases) are listed in the [Service catalog](service-catalog.md), not here.

Verified 2026-10-13 from `.gitmodules`, each repository's `.github/workflows/` on the branches named below
(`gh api repos/packiot/<repo>/contents/.github/workflows?ref=<branch>`), repository settings, and the AWS
Amplify app settings (read-only).

!!! danger "Customer-facing branches"
    Several branches below deploy straight to environments **factories use today** (legacy line):
    `edge-api` `development` and `master`, `front4` `master` and `development`, `back4-api` `main` and `dev`.
    New-stack work never targets them. Branches marked "customer" in the tables are **do not push**.

## At a glance

```text
                         packiot-stack-alpha  (default branch: staging)
                         ├─ edge-api/       submodule → packiot/edge-api        bump bot
  submodules,            ├─ edge-node-red/  submodule → packiot/edge-node-red   bump bot
  all track `staging`    ├─ operator/       submodule → packiot/operator4       bump bot
  (.gitmodules)          ├─ csadmin/        submodule → packiot/csadmin         bumped by hand
                         └─ front4/         submodule → packiot/front4          pin unused by deploys

  separate repos used by staging:  barcode-scanner-v2 (image pulled from GHCR)
  legacy platform (production):    back4-api, oeecloud-node-red, front4 master, edge-api master
```

| Repository | Role | Default branch | In the stack as | Staging gets it by |
|---|---|---|---|---|
| [`packiot-stack-alpha`](#packiot-stack-alpha) | The platform monorepo (this repository) | `staging` | — | `deploy-staging.yml` on push to `staging` |
| [`edge-api`](#edge-api) | NestJS control-plane API (CS Admin, factory, operator writes) | `master` | submodule `edge-api/` | bump bot PR → stack deploy |
| [`edge-node-red`](#edge-node-red) | Node-RED: Sparkplug ingest and edge flows | `main` | submodule `edge-node-red/` | bump bot PR → stack deploy |
| [`operator4`](#operator4) | Operator app (React SPA) | `master` | submodule `operator/` | bump bot PR → stack deploy |
| [`csadmin`](#csadmin) | CS Admin console (React + Vite) | `main` | submodule `csadmin/` | **manual** bump PR → stack deploy |
| [`front4`](#front4) | Product frontend (React SPA) | `master` | submodule `front4/` (stale pin) | AWS Amplify builds `staging` directly |
| [`barcode-scanner-v2`](#barcode-scanner-v2) | Barcode scanner station app | `main` | not a submodule | GHCR image `barcode-edge:staging` pulled at deploy |
| [`back4-api`](#back4-api) | Legacy backend API | `main` | — | not used by staging |
| [`oeecloud-node-red`](#oeecloud-node-red) | Legacy cloud Node-RED (Sparkplug → TimescaleDB) | `main` | — | not used by staging |

## The stack

### packiot-stack-alpha

The platform monorepo: Docker Compose stacks (`compose.staging.yml`, `compose.production.yml`,
`compose.superset.yml`, …), Go services under `services/`, Terraform under `terraform/`, database migrations
under `db/`, Grafana dashboards, the dev environment (`dev/`) and this wiki. README:
[`README.md`](https://github.com/packiot/packiot-stack-alpha/blob/staging/README.md). The repository is
**public**; the submodule repositories are private.

| Branch | Deploys | Protection |
|---|---|---|
| `staging` (default) | **Staging stack** — `deploy-staging.yml` on every push, self-hosted runner on the staging app host | Ruleset "Protect staging": PR required (0 approvals), required checks **`Validate compose files`** and **`dev slices gate`**, no force-push, no deletion |
| `production` | **New-stack production** — `deploy-production.yml` on push (self-hosted runner labelled `production`). Promotion only | none — do not touch |
| `development` | nothing (its `deploy-staging.yml` copy triggers on `staging` only). Retired, last commit 2026-08-18 | none |
| `main` | nothing. Frozen legacy anchor, last commit 2026-05-19 | none |

CI on PRs into `staging` (full list and what each gates: [Branches and merging](../build/develop/branches-and-merging.md#4-the-checks)):
`pr-validation.yml`, `dev-slices.yml`, `go-services.yml`, `gitleaks.yml`, `superset-rls-isolation.yml`,
`refdata-contract-drift.yml`, `build-wiki.yml`, `dashboard-lint.yml`, `customization-flow-lint.yml`.
Other workflows on `staging`: `deploy-staging.yml`, `deploy-production.yml`, `emergency-db-restore.yml`,
`dev-seed-build.yml`, `sandbox-selfheal.yml`, `openapi-export.yml`, `build-postgres.yml`,
`client-edge-deploy.yml`, `generate-client-bundle.yml`, `inject-counter-fixture.yml`,
`inspect-edge-transformer.yml`.

Merge methods allowed: squash, merge, rebase; auto-merge enabled (the bump bots rely on it).

## Submodules

All five submodules track `staging` (`branch = staging` in `.gitmodules`). The staging deploy fetches and builds
four of them: `edge-api`, `edge-node-red`, `operator`, `csadmin` (`git submodule update --init --force` in
`deploy-staging.yml`). The `front4` pin is not built by any deploy.

None of the submodule repositories has branch protection: they are private repositories on a plan where
GitHub rulesets and protection are unavailable. Nothing technically stops a push to a customer branch.

### edge-api

NestJS + TypeScript API: CS Admin CRUD, factory control plane (production orders, downtimes, shifts),
operator writes, onboarding. Component page: [edge-api](../understand/components/edge-api.md). README:
[`README.md`](https://github.com/packiot/edge-api/blob/staging/README.md).

| Branch | Deploys | Audience |
|---|---|---|
| `staging` | bump bot → stack `staging` PR → staging stack | new stack |
| `master` (default) | `deploy-main.yml`: image to ECR `production/edge-api` → Elastic Beanstalk `edge-api-prod-docker-env` (`edge.api4.packiot.com`) | **customer** (legacy production) |
| `development` | `deploy-dev.yml`: image to ECR `development/edge-api` → Elastic Beanstalk `edge-api-dev-docker-env` (`edge-dev.api4.packiot.com`); **also** a bump PR into the stack's retired `development` | **customer** (legacy, used by factories) |
| `production` | nothing on push (no deploy workflow triggers on it) | — |

- CI: `pullrequests.yml` ("Pull Requests Validation", self-hosted runner `packiot-ci`) on PRs into
  `master`, `development`, `staging`: commit lint, unit tests with coverage, e2e tests, linter, Codecov upload.
  `packml-ratchet.yml` on the same PRs. `new-relic-change-tracking.yml` on push to `master`.
- Bump bot: `bump-stack-submodule.yml` on push to `staging` or `development`.
- Merge method: **merge commit only** (squash and rebase are disabled).
- Its knex migrations (`edge-api/migrations/`) run automatically at every staging deploy.

### edge-node-red

Node-RED edge service: Sparkplug B PLC ingest, GCP Pub/Sub publish, AMQP out. Component page:
[edge-node-red](../understand/components/edge-node-red.md). README:
[`README.md`](https://github.com/packiot/edge-node-red/blob/staging/README.md).

| Branch | Deploys | Audience |
|---|---|---|
| `staging` | bump bot → stack `staging` PR → staging stack (built from source, `build: ./edge-node-red`) | new stack |
| `main` (default) | `build.yml`: publishes Docker Hub image `devpackiot/edge-node-red:<sha>` (not used by staging) | per-client deploys |
| `development` | bump PR into the stack's retired `development` | — |

- CI: `ci.yml` ("Validate Node-RED flows": JSON validity, no hard-coded credentials or client URLs, Sparkplug
  subflow check) on pushes and PRs; `lint-flows.yml` on PRs into `staging`/`development` and pushes to `staging`.
- Per-client deploys: `enterprise-test-deploy.yml`, `enterprise-neopac-wil-deploy.yml` — manual
  (`workflow_dispatch`), through `deploy-template.yml` on a self-hosted runner labelled per client.
- Bump bot: `bump-stack-submodule.yml` on push to `staging` or `development`.

### operator4

The operator app (React SPA) that machine operators use on the factory floor; checked out at `operator/` in
the stack. Component page: [Operator app](../understand/components/operator-app.md). README:
[`README.md`](https://github.com/packiot/operator4/blob/staging/README.md).

| Branch | Deploys | Audience |
|---|---|---|
| `staging` | bump bot → stack `staging` PR → staging stack (`operator.staging.packiot.app`) | new stack |
| `master` (default) | `build.yml`: publishes Docker Hub image `devpackiot/operator4:<sha>` | per-client deploys |
| `development` | bump PR into the stack's retired `development` | — |

- CI: `pr-validation.yml` ("Lint, test, build"; lint is non-blocking) on PRs into `staging`/`development`;
  `packml-ratchet.yml` on PRs into `master`, `staging`, `development`.
- Per-client deploys: `cpack-enterprise-deploy.yml`, `enterprise-test-deploy.yml`,
  `neopac-wil-enterprise-deploy.yml` — manual, through `deploy-template.yml` on self-hosted runners labelled
  per client.
- Bump bot: `bump-stack-submodule.yml` on push to `staging` or `development`.

### csadmin

The CS Admin console (React + TypeScript + Vite, Tailwind) used by Customer Success to onboard and configure
clients. Component page: [csadmin](../understand/components/csadmin.md). README:
[`README.md`](https://github.com/packiot/csadmin/blob/staging/README.md).

| Branch | Deploys | Audience |
|---|---|---|
| `staging` | **no bump bot** — bump the stack's pin by hand ([how](../build/develop/branches-and-merging.md#6-what-deploys-and-how)); built by the stack (`context: ./csadmin`) | new stack |
| `main` (default) | nothing (no workflows on `main`; last commit 2026-05-21) | — |
| `production` | nothing on push | — |

- CI: **only** `packml-ratchet.yml` (PRs into `main`, `staging`). There is no test CI: run the tests and the
  type-check yourself and say so in the PR.
- Not to be confused with `csAdmin4`, the older CS Admin (Amplify app `csAdmin4`, branch `master`).

### front4

The product frontend (React SPA): Mission Control, dashboards, settings. Component page:
[front4](../understand/components/front4.md). README:
[`README.md`](https://github.com/packiot/front4/blob/staging/README.md).

front4 is deployed by **AWS Amplify** (app `front4`), not by the stack. The stack's `front4/` pin is stale and
only used as the dev environment's default source (`dev/services/front4.yml`; set `FRONT4_DIR` to a fresh
clone instead).

| Branch | Deploys | Audience |
|---|---|---|
| `staging` | Amplify auto-build → `front.staging.packiot.app` and `staging.packiot.com`; the `staging.yml` workflow also builds and FTP-syncs to `/staging.packiot.com/` | new stack |
| `production` | Amplify auto-build → `front.prod.packiot.app` | new-stack production |
| `master` (default) | `master.yml` workflow: triggers an Amplify deploy (`scripts/amplify-deploy.sh`, Amplify auto-build is off for this branch) **and** FTP-syncs a production build to `/go.packiot.com/` → `go.packiot.com` | **customer** (legacy production) |
| `development` | `development.yml` workflow → Amplify deploy (auto-build off) → `dev.packiot.com` | **customer-visible** legacy dev |

- CI: `ci.yml` on PRs and pushes to `staging`/`production`: "Typecheck, build & tests" (blocking) and
  "Lint (ESLint + react-hooks)" (non-blocking).
- No bump bot (nothing needs one: no deploy reads the pin).

## Separate repositories the new stack uses

### barcode-scanner-v2

Barcode scanner station app (React + TypeScript + Vite). Not a submodule. Component page:
[barcode-app](../understand/components/barcode-app.md). README:
[`README.md`](https://github.com/packiot/barcode-scanner-v2/blob/staging/README.md).

| Branch | Publishes | Used by |
|---|---|---|
| `staging` | `build-edge.yml`: `ghcr.io/packiot/barcode-edge:staging` (+ `:staging-<sha>`) | staging: `deploy-staging.yml` pulls it and retags it `barcode-app:staging`, **only if** Secrets Manager `packiot/staging/ghcr-read` exists; otherwise the host keeps a hand-built image |
| `main` (default) | `build-edge.yml`: `ghcr.io/packiot/barcode-edge:main` | on-box barcode deploys |

- CI: `ci.yml` on PRs and pushes to `staging`/`main`. No bump bot (the stack does not pin it).
- `barcode-scanner-v1` is the superseded app (no workflows).

### client-access-gateway

Company-to-company access to client networks (site-to-site VPN, SSM relay, laptop kit). Not part of the
Packiot product. README: [`README.md`](https://github.com/packiot/client-access-gateway/blob/main/README.md).
Branch `main` only; CI `ci.yml` (`make check`: fmt, validate, tflint, laptop scripts) on PRs and pushes. No
deploy workflow.

## Legacy platform (production today)

Production still runs the legacy platform for most clients
([Legacy bridge](../understand/subsystems/legacy-bridge.md), [Environments](../understand/architecture/environments.md)).
These repositories are **read-only for new-stack work**: report problems, do not change them.

### back4-api

Legacy backend API (Node.js). No README.

| Branch | Deploys | Audience |
|---|---|---|
| `main` (default) | `main.yml`: Elastic Beanstalk app `piot4backend`, env `back4-api-main` (us-east-2), self-hosted runner `packiot-ci` | **customer** (legacy production) |
| `dev` | `dev.yml`: Elastic Beanstalk env `back4-api-dev` (us-east-2) | legacy dev |
| `staging` | nothing (no workflow triggers on it) | — |

No PR CI.

### oeecloud-node-red

Legacy cloud Node-RED: Sparkplug B from GCP Pub/Sub into the legacy TimescaleDB. No README.

| Branch | Does | Audience |
|---|---|---|
| `main` (default) | `ci.yml`: validate, build, and on push publish Docker Hub `packiot/oeecloud-node-red:latest` and `:<sha>` | legacy production |
| `staging` | `ci.yml` copy; triggers on `main`/`develop` only, so nothing runs on `staging` pushes | — |

!!! warning "Unverified"
    How the legacy production oeecloud instance is updated from this image is not in any workflow in this
    repository (it runs on a GCP VM). Check with the team before assuming a push to `main` changes production.

## Other repositories in the organisation

Not deployed by, or part of, the platform described in this wiki. Listed so you know what they are.

| Repository | What it is |
|---|---|
| `stack`, `gitops`, `terraform`, `edge`, `worker`, `integration`, `api` (archived), `rabbitmq`, `poc-rabbitmq` | An earlier Kubernetes / ArgoCD / EKS design, not used by the stack in this wiki. `gitops` and `terraform` have their own validation and deploy workflows for that design |
| `packiot-context` | Shared onboarding context for engineers and AI agents |
| `packiot-product-engineering-ops` | Product & engineering operating standard; weekly `refresh-context.yml` |
| `reports-web` | German production report (Next.js), Amplify app `reports-web` (branch `main`) |
| `client-monitoring` | Amplify app `client-monitoring` |
| `csAdmin4` | Previous CS Admin, Amplify app `csAdmin4` (branch `master`) |
| `highbyte` | HighByte integration configuration (branches `main`, `centralhub`, `vm1`, `vm2`) |
| `operator`, `operator-1`, `frontend-v1`, `packiot1-backend`, `admin-panel-*`, `back-consumer`, `node-red-contrib-*`, `nodeS7`, … | Older generations and libraries; no recent activity |

## Bump bots

`edge-api`, `operator4` and `edge-node-red` share the same workflow, `.github/workflows/bump-stack-submodule.yml`:

1. Triggers on push to the submodule's `staging` or `development` (and manually).
2. Opens a PR in `packiot-stack-alpha` against the **same-named** branch, from
   `bot/bump-<path>-<branch>-<short-sha>`, titled `chore(submodule): bump <path> to <short-sha> (<branch>)`.
3. Enables auto-merge (squash). On `staging` the PR merges when the required checks pass; on the unprotected
   `development` it falls back to a direct merge.
4. Authenticates with the repository secret `PARENT_REPO_TOKEN`. When that token expires, no bump PR appears:
   bump by hand ([how](../build/develop/branches-and-merging.md#6-what-deploys-and-how)) and rotate it
   ([Rotate secrets](../build/operate/secrets-rotation.md)).

## Source map

| Path | What's there |
|---|---|
| `.gitmodules` | the five submodules, all `branch = staging` |
| `.github/workflows/deploy-staging.yml` | which submodules staging fetches; the GHCR barcode pull |
| `.github/workflows/deploy-production.yml` | production deploy on push to `production` |
| `.github/workflows/dev-slices.yml` | the `dev slices gate` check |
| `compose.staging.yml` | build contexts `./edge-api`, `./edge-node-red`, `./operator`, `./csadmin`; `barcode-app` image |
| `dev/services/front4.yml` | dev environment's `FRONT4_DIR` (stale pin default) |
| `<repo>/.github/workflows/` (on GitHub) | each repository's CI, deploys and bump bot |
