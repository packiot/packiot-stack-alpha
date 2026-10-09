# Contributing to packiot-stack-alpha

This repo is the **aggregator** for the Packiot stack. It holds the in-tree Go
services (`services/`), the analytics DB migrations (`db/migrations/`), the dev
environment (`dev/`), compose + Terraform, and pins 5 repos as submodules
(`edge-api`, `operator` = operator4, `csadmin`, `front4`, `edge-node-red`). It is
the only thing deployed to the AWS staging EC2. The
service repos do their own testing in isolation; this repo runs the
integration via `docker compose`.

If you're new to the codebase, start with the wiki's **For engineers** page (`docs/wiki/for-engineers.md`, served at wiki.packiot.app)
— the end-to-end walk through the stack (architecture, code map,
glossary, doc routing). This file is about **workflow** — branches,
PRs, deploys, and how the auto-bump chain wires it all together.

---

## TL;DR

The full, verified procedure is in the wiki: **Operations → "Branches, merging & deploying"**
(`docs/wiki/operations/branches-and-merging.md`) and **"Local development"**
(`docs/wiki/operations/local-development.md`).

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  staging     →  integration branch; every PR targets it; auto-deploys to AWS staging │
│  production  →  NEW production; promotion only (release branch + runbook + go)       │
│  development →  RETIRED (last commit 2026-08-18; ADR-0060 D8) — do NOT use           │
│  main        →  frozen legacy anchor — do NOT push                                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

- Feature branches off **`staging`**, PR back into **`staging`**, in every repo.
- **Never push/merge/rebase/force-push `development`, `master`, `main` or `production`**
  in any repo: in edge-api and front4 those branches deploy to customers.
- Merge only when **every** check on the PR's head SHA is green (only
  `Validate compose files` is required by the ruleset; the rest is our rule).
- Submodule changes: merge in the submodule's `staging`; edge-api, operator4 and
  edge-node-red bump the pin here automatically; csadmin is bumped by hand.
- `db/migrations/` has no runner: dry-run → apply → verify on staging, then merge.

---

## The branch model

| Branch | Purpose | Deploys? | Protected? |
|---|---|---|---|
| `staging` (default) | Integration branch for all work. | Yes — `deploy-staging.yml` on push | Yes (ruleset "Protect staging") |
| `production` | **New production.** Changed only by a planned promotion (release branch → draft PR → runbook → explicit go). | Yes (on push) | No ruleset — never push |
| `development` | **Retired.** It was the pre-staging scratchpad; ADR-0060 D8 rejected a long-lived dev branch and it has not moved since 2026-08-18. Submodule bump bots still target it when someone pushes a submodule's `development` — another reason not to. | No | No |
| `main` | **Frozen legacy anchor.** Do NOT push. | No | No |

### The flow

```
  1. git fetch origin && git switch -c <type>/<thing> origin/staging
  2. ...edit, commit; run the service's tests + `make dev SVC=… && make dev-smoke SVC=…`
  3. git push -u origin HEAD && gh pr create --base staging
  4. wait until EVERY check on the head SHA is completed/success
  5. gh pr merge <n> --squash --delete-branch --match-head-commit <sha>
  6. deploy-staging.yml deploys; verify the running artifact, not just the green run
```

---

## Submodules — the auto-bump chain

Five repos are submodules. The parent's `.gitmodules` tracks each on
`staging`:

```
edge-api          → packiot/edge-api        (bump bot)
edge-node-red     → packiot/edge-node-red   (bump bot)
operator          → packiot/operator4       (bump bot; repo name ≠ path name)
csadmin           → packiot/csadmin         (NO bump bot — bump the pin by hand in a PR)
front4            → packiot/front4          (deploys itself via AWS Amplify; the pin is not deployed)
```

> Historically there was a 4th submodule, `oeecloud-node-red`. It was
> decommissioned 2026-06-24 — replaced by `services/oeecloud-worker` (Go),
> which lives in-repo as a regular subdir (not a submodule).

edge-api, operator4 and edge-node-red have a workflow `bump-stack-submodule.yml` that fires on push
to their own `staging` or `development` branches. The workflow opens a PR on
**this** parent repo bumping the submodule pointer to the new SHA. The
flow is automatic end-to-end:

```
   ┌──────────────────────────┐
   │ push to <submodule>:STG  │
   └──────────┬───────────────┘
              │
              ▼
   ┌──────────────────────────────────────────────┐
   │ bump-stack-submodule.yml (on submodule)      │
   │  - creates bot/bump-<sub>-staging-<sha>      │
   │  - opens PR on parent (base: staging)        │
   │  - gh pr merge --auto --squash               │
   └──────────┬───────────────────────────────────┘
              │
              ▼
   ┌──────────────────────────────────────────────┐
   │ PR Validation (on parent, required)          │
   │  - docker compose config --no-interpolate    │
   │  - validates compose.staging.yml and the     │
   │    dev/ environment (dev/compose.yml)        │
   └──────────┬───────────────────────────────────┘
              │ (green)
              ▼
   ┌──────────────────────────────────────────────┐
   │ Auto-merge fires → parent staging advances   │
   └──────────┬───────────────────────────────────┘
              │
              ▼
   ┌──────────────────────────────────────────────┐
   │ Deploy to Staging (on parent)                │
   │  runs-on: self-hosted staging EC2            │
   │  → docker compose -f compose.staging.yml \   │
   │     up -d --build                            │
   └──────────────────────────────────────────────┘
```

A push to a submodule's `development` branch follows the same chain but
targets the parent's **retired** `development` branch (direct merge, it is unprotected).
Do not push submodule `development` branches: in edge-api it also deploys the
customer-facing Elastic Beanstalk `edge-api-dev-docker-env`.

Auto-merge waits only for the one required check (`Validate compose files`), not
for `dev-slices` or `go-services`: the submodule's own CI is the real gate.

### Requirements per submodule

- Secret `PARENT_REPO_TOKEN` set with `contents:write` AND
  `pull-requests:write` on `packiot/packiot-stack-alpha`.
- (Legacy) the workflow can also bump the retired `development` branch; do not rely on it.

### Submodule path mismatch (operator/operator4)

The frontend repo on GitHub is `operator4` but the submodule path inside
this parent repo is `operator`. The bump workflow on `operator4` hardcodes
`SUBMODULE_PATH=operator`. If you ever fork/rename, update there.

---

## Local development

Clone with submodules:

```sh
git clone --recurse-submodules https://github.com/packiot/packiot-stack-alpha.git
cd packiot-stack-alpha
git checkout staging
git submodule update --init --recursive   # submodules at the pinned SHAs
docker login ghcr.io                      # token with read:packages (the dev seed is private)
```

Then run what you need locally with the dev environment (ADR-0060, see `dev/README.md`):

```sh
make dev SVC=<service>   # the service + its depends_on closure, on the anonymized dev seed
```

(Each submodule also has its own `make test` / `npm test` / equivalent for
isolated testing of just that service. Use those for fast inner loops.)

If you only need to validate that the compose files are well-formed
(no actual containers):

```sh
docker compose -f compose.staging.yml config --no-interpolate -q
docker compose -f dev/compose.yml --env-file dev/.env.dev config -q
```

This is the same check that PR Validation runs in CI.

---

## Branch protection on `staging`

Ruleset name: **Protect staging** (id `18079945`).

Rules active on `refs/heads/staging`:

| Rule | Effect |
|---|---|
| `pull_request` | All changes must go through a PR. Direct `git push origin staging` is rejected. Required approvals: 0 (so bot bump PRs auto-merge). |
| `required_status_checks` | `Validate compose files` must pass before merge. |
| `non_fast_forward` | Force-push to `staging` is rejected. |
| `deletion` | `staging` cannot be deleted. |

**No bypass actors.** Even repo admins use PRs. For emergencies, use a PR
with the admin "merge regardless of failing checks" UI rather than
weakening the ruleset.

### Why no protection on `development` or `main`?

- `development` is retired (ADR-0060 D8); nothing should target it.
- `main` is reserved for a future production tier and isn't actively used.

---

## Hotfix protocol

If `staging` is broken, the fix takes the normal path, just smaller:

1. `git checkout staging && git pull`
2. `git checkout -b hotfix/<description>`
3. Edit, commit.
4. PR → `staging`. PR Validation runs.
5. Squash-merge once every check is green (edge-api: merge commit).
6. Verify the deployed artifact.

Same pattern in a submodule repo (its `staging`). There is no back-merge to
`development`: it is retired, and in edge-api/front4 it is customer-facing.

---

## Common operations

### Manually re-trigger a bump

Each submodule's bump workflow has a `workflow_dispatch` trigger.
Run it from the submodule's Actions page → "Bump packiot-stack-alpha
submodule pointer" → "Run workflow" on the branch you want to re-bump.

Useful if `PARENT_REPO_TOKEN` was rotated mid-flight and a previous
bump failed silently.

### Add a new submodule

1. Add to `.gitmodules` with `branch = staging`.
2. Copy `.github/workflows/bump-stack-submodule.yml` from one of the
   existing submodules into the new repo. Change `SUBMODULE_PATH`.
3. Set `PARENT_REPO_TOKEN` secret on the new submodule.
4. Update `compose.staging.yml` to reference the new service, and add a dev fragment
   `dev/services/<svc>.yml` (contract header first — see `dev/README.md`).
5. Open a PR to parent `staging` adding the gitlink + compose changes.

---

## CI checks reference

### Parent (this repo)

| Workflow | Trigger | Job name | Required? |
|---|---|---|---|
| `pr-validation.yml` | PR to `staging` or `development` | `Validate compose files` | **Yes** (on `staging`) |
| `gitleaks.yml` | PR + push to `staging` | `gitleaks detect (full history)` | **Yes** — fails on any secret |
| `go-services.yml` | PR to `staging`/`development` touching `services/**` | `<service> — vet/test/build` (matrix) | No (convention) |
| `deploy-staging.yml` | push to `staging` | `deploy` (includes smoke check on container health) | (post-merge) |
| `build-postgres.yml` | push to `main` (path `db/**`) | `build-and-push` | No |

### Submodules

| Submodule | Workflow | Job name | Required? |
|---|---|---|---|
| `edge-api` | `pullrequests.yml` | `ciCoverage` (Jest + lint + coverage) | **No — convention only** |
| `operator` | `pr-validation.yml` | `Lint, test, build` (vitest + eslint + vite build) | **No — convention only** |
| `edge-node-red` | `ci.yml` | `Validate Node-RED flows` (JSON + creds scan) | **No — convention only** |

### Why "convention only" on submodules?

The submodule repos are private and the org is on GitHub Free, which does
not allow branch protection (neither rulesets nor classic) on private
repos. The parent stack has the only enforced check because it's public.

**The convention**: don't merge a submodule PR to `staging` if its CI is
red. The auto-bump fires immediately on push; a red commit deployed to
staging will trip the smoke check in `deploy-staging.yml`, but you've
already shipped the broken submodule pointer.

If discipline isn't enough, three escapes (in order of cost):

1. **Defer** — the current state. Cheapest, surfaces issues at the cost
   of relying on human judgment.
2. **Make the submodule public** — unlocks branch protection on the Free
   plan. Audit git history for accidental secrets first (`gitleaks` is
   the standard tool).
3. **Upgrade org to Team** — ~$4/user/mo unlocks branch protection on
   private repos. Also gets you required reviewers, code-owner
   enforcement, etc.

A fourth option exists but is custom code: a parent-side workflow that
polls each submodule's CI status at the pinned SHA and rejects the bot
bump PR if red. Approximates the gate without native protection;
worth ~2-4h of work if discipline keeps slipping.

---

## Secret scanning (gitleaks)

Two layers keep credentials out of git:

1. **CI (`gitleaks.yml`)** — a **required** check that scans the full history
   on every PR and every push to `staging`. Any finding fails the job and
   blocks the merge. Runs the pinned gitleaks binary with the shared
   `.gitleaks.toml` allowlist (tuned to suppress documented dev-default /
   public-key false positives with near-zero noise).

2. **Local pre-commit hook** — catches leaks *before* they reach a remote.
   Install once per clone:

   ```bash
   pip install pre-commit      # or pipx / brew
   pre-commit install          # wires the git commit hook
   ```

   Thereafter each `git commit` runs `gitleaks protect --staged` on the staged
   diff and blocks the commit on a finding. Emergency bypass (discouraged):
   `git commit --no-verify`.

If the scanner flags a genuine false positive, add it to the allowlist in
`.gitleaks.toml` (keep it tight — allowlist the *extracted secret value* or an
exact path, never a broad secret shape), and explain why in the PR. Never
commit a real secret and "allowlist" it — rotate it instead.

---

## See also

- `docs/GUIDE.md` — architecture, data flow, code map, glossary.
- `docs/INDEX.md` — the full documentation inventory.
- Each submodule's own `CLAUDE.md` if present — service-specific
  conventions.
