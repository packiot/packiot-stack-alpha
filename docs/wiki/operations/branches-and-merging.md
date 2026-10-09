---
title: Branches, merging and deploying to staging
layer: 4
owner_area: platform
last_verified: 2026-10-09
---
# Branches, merging and deploying to staging

> **Layer 4 · Operations** — the exact path a change takes from your branch to the running staging stack, in
> every repository: which branch to start from, which branches you must never touch, the checks that run, how to
> merge, what deploys, how to verify it, how to change the database safely and how to roll back. For any engineer
> shipping code. Up: [Environments](../architecture/environments.md) · Workflows in detail: [CI/CD](../components/ci-cd.md)

## The rules in one screen

1. **Every change starts from `staging` and returns to `staging` through a pull request**, in every repository.
   There is no long-lived `development` stage for the new stack ([ADR-0060](../reference/adr-index.md) D8).
2. **Never push to, merge into, rebase or force-push `development`, `master`, `main` or `production`** in any
   repository. Several of them deploy straight to **customers** (table below). In the submodule repositories
   nothing technically stops you — those repositories have no branch protection — so this is a rule you keep.
3. **Merge only when every check on the PR's current head commit has finished green**, not just the one GitHub
   requires. Wait on the head SHA (command below), not on `gh pr checks` output from an earlier push.
4. **A green deploy is not proof.** After the deploy, check the running artifact (container created after your
   merge, your change visible in logs, data or API).
5. **Database changes go through a migration file, applied on staging first** (dry-run → apply → verify), and only
   then merged. Staging's live schema is what production receives in the promotion.
6. **Production is never "the next merge".** It is a planned promotion with its own runbook and an explicit go.

## What each branch deploys

Verified 2026-10-09 from each repository's workflows and the AWS Amplify app settings.

### packiot-stack-alpha (this repository)

| Branch | Deploys | Protection |
|---|---|---|
| `staging` (default) | **Staging stack** — `deploy-staging.yml` on every push | Ruleset "Protect staging": PR required (0 approvals), required check `Validate compose files`, no force-push, no deletion, no bypass |
| `production` | **New-stack production** — `deploy-production.yml` on push. Promotion only. | none — do not touch |
| `development` | nothing. **Retired**: last commit 2026-08-18, 1,449 commits behind `staging` | none |
| `main` | nothing. Frozen legacy anchor | none |

### Submodule and app repositories

| Repository | `staging` | Other branches — **do not push** |
|---|---|---|
| `edge-api` | bump bot → stack `staging` PR | `development` → Elastic Beanstalk `edge-api-dev-docker-env` (`edge-dev.api4.packiot.com`, **used by customers**) **and** a bump into the stack's retired `development`. `master` (default) → Elastic Beanstalk `edge-api-prod-docker-env` (`edge.api4.packiot.com`, **customer production**) |
| `operator4` (stack path `operator/`) | bump bot → stack `staging` PR | `development` → bump into the stack's `development`. `master` → publishes Docker Hub image `devpackiot/operator4` |
| `edge-node-red` | bump bot → stack `staging` PR | `development` → bump into the stack's `development`. `main` → publishes Docker Hub image `devpackiot/edge-node-red` |
| `csadmin` | **no bump bot** — bump the pin by hand (below) | — |
| `front4` | **AWS Amplify** auto-builds → `front.staging.packiot.app` and `staging.packiot.com`. Not tied to the stack's pin. | `production` → Amplify → `front.prod.packiot.app`. `master` (default) → `go.packiot.com` (**customer production**, legacy line). `development` → `dev.packiot.com` |

!!! danger "`development` and `master` in the app repositories are customer-facing"
    `edge-api/development` and `edge-api/master` deploy Elastic Beanstalk environments that factories use;
    `front4/master` is `go.packiot.com`. These are the legacy line, owned and released separately. New-stack work
    never targets them. If something from those branches must reach the new stack, port it in a new PR into
    `staging` (that is how `edge-api` #294 and the barcode features in #295 were carried over).

## The path of a change

```text
 your branch (from staging)
      │  make dev SVC=… && make dev-smoke SVC=…            ← local, against the dev seed
      ▼
 PR into staging ──► checks run (table below) ──► wait for ALL green on the head SHA
      │
      ▼  squash-merge (stack, front4, csadmin, operator4, edge-node-red) · merge commit (edge-api)
 staging branch ──► deploy-staging.yml (stack) · bump bot PR (submodules) · Amplify (front4)
      │
      ▼
 staging stack running ──► verify the artifact, not the run
```

### 1. Start the branch

```bash
git fetch origin
git switch -c <type>/<short-name> origin/staging       # e.g. fix/l6-line-scrap, feat/sap-report-page
```

Use one branch per concern. Keep unrelated changes (for example a code fix and its data repair script) in separate
PRs so neither waits for the other.

### 2. Build and test locally

Run the tests of what you changed (`go test ./...` in the service, `yarn test`/`npm test` in a frontend, the
repository's lint) **and** the dev slice that exercises it:

```bash
make dev SVC="<service>" && make dev-smoke SVC="<service>"
```

See [Local development environment](local-development.md). For a bug fix, prove the test you add **fails on the
old code** first: a test that also passes without your fix proves nothing.

### 3. Open the pull request

```bash
git push -u origin HEAD
gh pr create --base staging --title "<type>(<area>): <what>" --body "<why, how verified, what to watch>"
```

A good body says what was wrong (root cause), what changed, how you verified it (commands and numbers), and any
manual step (migration to apply, flag to set).

### 4. The checks

**Stack repository** — what runs on a PR into `staging`:

| Check | Workflow | Runs when | Blocks merge? |
|---|---|---|---|
| `Validate compose files` | `pr-validation.yml` | every PR | **yes — the only required check** |
| `packml ratchet (ADR-0061)` | `pr-validation.yml` | every PR | no (but never merge red: a new PackML reference is a design violation) |
| `gitleaks detect (full history)` | `gitleaks.yml` | every PR | no |
| `<service> — vet/test/build`, `stream-engine — golden fixtures` | `go-services.yml` | PR touches a Go service | no |
| `slice tier0-grafana / pipeline / barcode / edge` | `dev-slices.yml` | PR touches `dev/`, `db/migrations/`, `services/`, `customize/`, `grafana/`, broker configs, a submodule pin or `Makefile` | no |
| `2-tenant RLS isolation…`, `compose.superset.yml merges…` | `superset-rls-isolation.yml` | every PR | no |
| `contract self-check (no prod access)` | `refdata-contract-drift.yml` | PR touches read-api's dataset registry or its golden | no |
| `build merged docs site` | `build-wiki.yml` | PR touches `docs/wiki/`, `docs/adr/`, `wiki/` | no |
| `structure …` / `hardproof …` | `dashboard-lint.yml` | PR touches `grafana/dashboards/` | no |

**Submodule repositories** — their own CI is the real gate for their code:

| Repository | Checks on a PR into `staging` |
|---|---|
| `edge-api` | `ciCoverage` (`pullrequests.yml`, self-hosted runner `packiot-ci`): commit lint, unit tests with coverage, e2e tests, **ESLint/Prettier** (formatting errors fail it); `packml ratchet` |
| `front4` | `Typecheck, build & tests` (`ci.yml`); `Lint (ESLint + react-hooks) — non-blocking` is `continue-on-error` and **already red on `staging`** (pre-existing errors) |
| `operator4` | `pr-validation.yml`; `packml ratchet` |
| `csadmin` | **only** `packml ratchet` — there is no test CI. Run `npx vitest run` and `npx tsc -b` yourself and say so in the PR |
| `edge-node-red` | `ci.yml`, `lint-flows.yml` |

!!! warning "Wait for every check on the head commit"
    GitHub only *requires* `Validate compose files`. Merging while other checks still run has bitten us
    (edge-api #292 merged mid-run, 2026-10-08). Wait on the current head SHA:
    ```bash
    PR=1234 REPO=packiot/packiot-stack-alpha
    SHA=$(gh pr view $PR -R $REPO --json headRefOid -q .headRefOid)
    gh api "repos/$REPO/commits/$SHA/check-runs?per_page=100" \
      -q '.check_runs[] | "\(.status) \(.conclusion) \(.name)"'
    ```
    Merge when every line reads `completed success` (or `completed skipped` for jobs that skip by design). For
    front4's non-blocking lint, confirm with `npx eslint <changed files>` that **your** files add no error.

### 5. Merge

| Repository | Method | Command |
|---|---|---|
| stack, front4, csadmin, operator4, edge-node-red | squash | `gh pr merge $PR -R $REPO --squash --delete-branch --match-head-commit $SHA` |
| `edge-api` | **merge commit** (squash is disabled in that repository) | `gh pr merge $PR -R packiot/edge-api --merge --match-head-commit $SHA` |

`--match-head-commit` refuses the merge if someone pushed after you checked.

### 6. What deploys, and how

**Stack repository.** The push to `staging` starts `deploy-staging.yml` on the self-hosted runner, which is the
staging app host itself:

1. `gate` job: if `staging` already moved past this commit, the run **skips itself**. A newer run deploys the newer
   code. Without this, an older run finishing last re-deployed old code (2026-10-08, fixed in #1642).
2. `deploy` job: fetch submodules at their pins, build all images, `docker compose up -d --remove-orphans`, reload
   Prometheus/Alloy/Alertmanager, then the **service-state gate** (every service running/healthy, one-shots exited 0,
   300 s deadline). The run also stops and restarts RabbitMQ (durability test): expect a short ingest gap.
3. edge-api's knex migrations run automatically at deploy (`db-migrate`). **`db/migrations/` SQL does not run at
   deploy** — see [Database changes](#database-changes).

Deploys queue, never cancel each other.

**Submodules with a bump bot** (edge-api, operator4, edge-node-red). Merging into the submodule's `staging` makes the
bot open a PR in the stack, `chore(submodule): bump <name> to <sha> (staging) (auto)`, and enable auto-merge. It
merges as soon as the required check passes, and the stack deploy follows.

!!! warning "A bump PR does not wait for the other checks"
    Auto-merge waits only for `Validate compose files`. The `dev-slices` run on a pin bump does not block it. Treat
    the submodule's own CI as the gate, and run the dev slice before you merge in the submodule.

If no bump PR appears within a few minutes, the bot's `PARENT_REPO_TOKEN` secret in that repository has probably
expired (it has happened twice). Bump by hand (next block) and report the token.

**csadmin, or any manual bump:**

```bash
git switch -c chore/bump-csadmin origin/staging
git -C csadmin fetch origin staging && git -C csadmin checkout <merged-sha>
git add csadmin
git commit -m "chore(submodule): bump csadmin to <short-sha> (staging) — <what it brings>"
git push -u origin HEAD && gh pr create --base staging --fill
```

**front4** deploys itself: Amplify builds `front4/staging` on every push. The stack's `front4` pin is not used by
any deploy.

### 7. Verify the deploy

```bash
gh run list -R packiot/packiot-stack-alpha -w deploy-staging.yml --limit 3
gh run watch <run-id> -R packiot/packiot-stack-alpha
```

A green run proves the run, not the result. Then check the artifact: the service's container was **created after
your merge**, its log shows your change working, or the API or data shows the new behaviour. Use the read-only
procedures in [Runbooks](runbooks.md) to look inside the staging host. A queued-run race or a phantom merge (a PR
that carried docs but not code) both looked green.

## Database changes

### edge-api migrations (knex)

Files in `edge-api/migrations/`. They run automatically at every staging deploy (`db-migrate`, knex
`migrate:latest`). Write them reversible, and test them in dev: `make dev SVC="edge-api"` runs them against the
seed in its `edge-api-migrate` step.

### Analytics DB migrations (`db/migrations/`)

There is **no migration runner** for `db/migrations/`. Each change is a folder applied by hand on staging, and the
PR is merged only after it has been applied and verified, so `staging` in git matches the live schema.

```text
db/migrations/t-<topic>/
  01-up.sql      the change: \set ON_ERROR_STOP 1, BEGIN … COMMIT, SET LOCAL lock_timeout, idempotent
  verify.sql     read-only checks that RAISE on failure (BEGIN READ ONLY … ROLLBACK)
  rollback.sql   restores the previous state
```

The procedure:

1. Write the three files; run them against the dev seed (`make dev`, then `psql` into `packiot-dev-postgres-1`).
2. Open the PR.
3. **Dry-run on staging**: run `01-up.sql` plus the verify body inside one transaction that ends in `ROLLBACK`.
4. **Apply** `01-up.sql` on staging, then run `verify.sql`.
5. Write the dry-run and verify output in the PR, then merge.

Rules that come from real incidents:

| Rule | Why |
|---|---|
| Never call `decompress_chunk` on the shared database | It took the CPACK operator API down (2026-09-30) |
| In UPDATE/DELETE on hypertables, use **literal** timestamp bounds, never `date 'X' + 1` or `now() - …` | On compressed chunks a stable bound silently matches 0 rows (TimescaleDB 2.27, found 2026-10-09). SELECTs are unaffected, so only a read-back exposes it |
| Re-flag gold (`recalc_needed`) only for the last 7 days | Re-flagging 30-day-old shifts stalled the shift rollup for every tenant for 22 minutes (2026-10-01) |
| Key data fixes by business attributes, not surrogate ids | Ids differ between staging and production |
| Do not hand-edit the staging schema outside a migration | The production promotion copies staging's live catalog: an unrecorded hand edit is shipped to production unreviewed |
| No new PackML / `packml_topic` references | The packml ratchet fails ([ADR-0061](../reference/adr-index.md)) |

### Data repairs

Repairs of existing data are scripts in `scripts/ops/` (for example `repair-line-scrap-and-unbacked.sh`), never
ad-hoc UPDATEs. They:

- snapshot every row they change into an `ops._fix_*` table (old and new values) **before** changing it;
- update with guards and literal bounds, one equipment-day at a time;
- mark a row applied only from a **read-back**;
- refresh the continuous aggregates for the touched days, and flag gold only within 7 days;
- never treat a value as junk by size alone: check the row's own totalizer first.

Run the script against the dev seed first, then on staging under `nohup` (sessions are killed after an hour), and
verify with a read-only query before reporting done.

## Rolling back

| What | How |
|---|---|
| Stack code | Revert the merge commit in a PR into `staging` (`gh pr create` from `git revert <sha>`). It deploys like any change. |
| Submodule code | Revert in the submodule's `staging` (the bot bumps the pin back), or revert the stack's bump PR to return the pin to the previous SHA. |
| front4 | Revert in `front4/staging`; Amplify rebuilds. |
| A `db/migrations/` change | Run the folder's `rollback.sql`, verify, then revert the PR. |
| A data repair | Restore from its `ops._fix_*` snapshot (the undo statement is in the script header). |

Do not "fix" the staging host by hand and leave it: the next deploy overwrites manual changes. Land the fix or the
revert through a PR.

## Hotfix on staging

Same path, smaller: branch from `staging`, the minimal fix, a PR, all checks green, merge, verify. There is no
bypass: the ruleset has no bypass actors.

## Production

Production is promoted, not merged into. The promotion is prepared on a release branch
(`release/prod-promotion-<date>` = `staging` plus a merge of `production`), reviewed as a draft PR, and applied in a
planned window with the database transplant runbook and an explicit go. See
`docs/adr/reference/production-promotion-transplant-runbook.md` and
`docs/adr/reference/production-promotion-branch-reconciliation.md` in the repository.

## Checklist

```text
[ ] branch from origin/staging, in every repo involved
[ ] tests pass locally; a new test fails on the old code
[ ] make dev SVC=… && make dev-smoke SVC=… for what you changed
[ ] PR into staging with root cause, change, verification, manual steps
[ ] every check on the head SHA completed success (csadmin: tests + tsc run by hand)
[ ] DB: migration dry-run + applied + verified on staging BEFORE merge
[ ] merged with --match-head-commit (edge-api: merge commit)
[ ] submodule: bump PR appeared and merged (csadmin: manual bump PR)
[ ] deploy run green AND artifact verified on staging
[ ] never touched development / master / main / production
```

## Source map

| Path | What's there |
|---|---|
| `.github/workflows/deploy-staging.yml` | `gate` (skip superseded) + `deploy` (build, up, service-state gate) |
| `.github/workflows/pr-validation.yml` | required `Validate compose files`; `packml ratchet` |
| `.github/workflows/go-services.yml`, `dev-slices.yml`, `gitleaks.yml`, `superset-rls-isolation.yml`, `refdata-contract-drift.yml`, `build-wiki.yml`, `dashboard-lint.yml` | PR checks |
| `.github/workflows/deploy-production.yml` | production deploy (push to `production`) |
| `.gitmodules` | every submodule tracks `staging` |
| `edge-api/.github/workflows/{bump-stack-submodule,pullrequests,deploy-dev,deploy-main}.yml` | edge-api bump bot, CI, the two Elastic Beanstalk deploys |
| `operator/.github/workflows/`, `edge-node-red/.github/workflows/`, `front4/.github/workflows/` | their bump bots, CI and deploys |
| `db/migrations/` | analytics DB migrations (no runner) |
| `scripts/ops/repair-line-scrap-and-unbacked.sh` | reference implementation of a safe data repair |
| `scripts/ci/packml-ratchet.sh` | the PackML ratchet |
| `CONTRIBUTING.md` | the short version of this page |
