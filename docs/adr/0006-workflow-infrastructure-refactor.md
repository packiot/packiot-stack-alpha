# ADR 0006 — Workflow infrastructure refactor for enterprise-grade CI/CD

**Status:** Proposed
**Date:** 2026-06-29
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team

---

## Context

### Where we are today

Across the 4 repos (`packiot-stack-alpha`, `edge-api`, `edge-node-red`, `operator`, plus `oeecloud-node-red` which only has a bump-workflow), **~25 GitHub Actions workflow files** with significant duplication and inconsistency:

| Pattern | Current state |
|---|---|
| `bump-stack-submodule.yml` | Duplicated in **4 repos**. Same logic, 4 maintenance points, drift over time. |
| `deploy-template.yml` | Duplicated in **2 repos** (edge-node-red + operator). Per-repo copies of the same idea. |
| `enterprise-<name>-deploy.yml` | Per-client wrappers in edge-node-red + operator. Copy-paste-and-edit per new client. |
| AWS auth | Long-lived `AWS_ACCESS_KEY_ID` / `SECRET` stored in GitHub Secrets across multiple repos. |
| Action versions | Pinned to mutable tags (`@v4`). Supply-chain risk: a malicious push to the tag = compromised CI. |
| Workflow linting | Not run anywhere. `actionlint` is a 60-second install away. |
| Environment protection | None. Anyone with repo-write can push to the deploy-triggering branches without review. |
| Caching strategy | Inconsistent. Some workflows cache Go modules, some don't; Docker buildx cache not standardized; npm cache absent. |
| Concurrency control | Only `deploy-staging.yml` has it. The rest can race during a busy push. |
| Secret naming | Inconsistent per-repo. No documented schema for new-repo onboarding. |

### Why now

This refactor is **the prerequisite for** ADR-0003 phase 1 (production deployment). Doing prod deployment first and refactoring later means re-doing prod's workflows. Doing them together is cheaper and ships better.

Additionally, ADR-0005 (per-factory deploys) explicitly depends on the reusable-workflow pattern. ADR-0004's per-client config consumption is cleanest when workflows can reference a shared deploy template. Three downstream ADRs all bottleneck on this refactor.

### What this ADR is NOT about

This ADR is about **the workflow files + CI/CD infrastructure** — not about the services they deploy. Application-level caching (in-process Redis-style caches, HTTP cache-headers, etc.) is covered separately in [`docs/caching-review-2026-06-29.md`](../caching-review-2026-06-29.md). The two are complementary but distinct.

This ADR also **explicitly respects** the pinned-production-assets list in [`docs/production-out-of-scope.md`](../production-out-of-scope.md). Several workflow files are off-limits because they deploy to customer-facing production assets; the phasing below honors this constraint.

---

## Decision

Adopt **8 enterprise CI/CD patterns** across the safe-zone workflow files (per the production pinning doc), phased over 4-6 weeks. Each pattern individually delivers value; the combination is the "enterprise-grade" baseline that scales beyond 4 repos.

### Pattern 1 — Reusable workflows + composite actions

Reusable workflows (`workflow_call`) provide a single source of truth callable from any repo. Composite actions (`.github/actions/<name>/action.yml`) share step-level patterns.

```
.github/workflows/
├── reusable-deploy-stack.yml          # workflow_call — staging + production
├── reusable-bump-parent.yml            # workflow_call — all 4 submodules
├── reusable-validate-pr.yml            # workflow_call — compose + Go tests + actionlint
└── reusable-go-services-ci.yml         # workflow_call — vet/test/build matrix

.github/actions/
├── setup-runner-deps/                 # composite: install deps, configure AWS
├── docker-login-and-buildx/           # composite: docker login + buildx with GHA cache
└── git-submodule-fetch/               # composite: persist-credentials dance for private submodules
```

Per-repo `deploy-staging.yml` shrinks to a thin caller (~10 lines).

### Pattern 2 — Centralized via `packiot/.github` repo

GitHub recognizes `<org>/.github` as the canonical location for org-wide workflows + actions. A reusable workflow at `packiot/.github/.github/workflows/reusable-deploy-stack.yml@v1` is callable from any repo in the org.

**Benefits:** one PR updates the workflow for ALL consumers. Consumers pin to versions (`@v1`) and opt into upgrades.

### Pattern 3 — OIDC for AWS — kill long-lived credentials

Replace the long-lived `AWS_ACCESS_KEY_ID` secret with short-lived OIDC tokens.

```yaml
# Old:
- uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}        # long-lived
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

# New:
permissions:
  id-token: write
  contents: read
steps:
- uses: aws-actions/configure-aws-credentials@<SHA>
  with:
    role-to-assume: arn:aws:iam::639178078294:role/github-actions-deployer-staging
    aws-region: us-east-1
```

Setup: one IAM OpenID Connect identity provider + per-environment IAM roles with trust policies scoped to specific repos + branches.

**Industry status:** this is now table-stakes at every AWS-using org. AWS publishes the [OIDC trust policy template](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html); GitHub publishes the [official guide](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services).

### Pattern 4 — SHA-pin all action versions + Dependabot

```yaml
# Old:
- uses: actions/checkout@v4              # mutable tag

# New:
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11   # v4.1.1 — immutable SHA
```

Pair with `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
    open-pull-requests-limit: 10
```

Dependabot opens a PR for each action release; the SHA gets bumped through code review.

### Pattern 5 — `actionlint` as a required CI check

```yaml
# .github/workflows/lint-workflows.yml
on:
  pull_request:
    paths: ['.github/workflows/**', '.github/actions/**']
jobs:
  actionlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<SHA>
      - uses: reviewdog/action-actionlint@<SHA>
```

Catches: typos in event names (`puhs` vs `push`), undefined inputs, shellcheck violations inside `run:` blocks, deprecated syntax, missing required permissions.

### Pattern 6 — GitHub Environments with protection rules

Configure repo Environments:

| Environment | Protection rules |
|---|---|
| `staging` | None (deploy any time) |
| `production-dryrun` | Require 1 reviewer + restrict to `production` branch |
| `production-live` | Require 1 reviewer + 30 min wait timer + restrict to `production` branch (when we cut writes) |

Workflows declare which environment they target:

```yaml
jobs:
  deploy:
    environment: production-dryrun
    runs-on: [self-hosted, production, linux, arm64]
    steps:
      # ...
```

GitHub UI shows an "Approve deployment" gate before the deploy job runs. **Audit-logged, can't be bypassed by branch push alone.**

### Pattern 7 — Standardized secret schema (documented)

```
Repository secrets (org-shared, identical across all repos):
  DOCKER_HUB_USER / DOCKER_HUB_TOKEN
  GH_PARENT_REPO_TOKEN              (PAT for submodule auto-bumps)

Environment secrets (different values per environment):
  AWS_REGION                         (us-east-1)
  HASURA_GRAPHQL_ADMIN_SECRET        (per-env, Terraform-generated)
  EDGE_API_KEY                       (per-env)

Variables (non-secret):
  DEPLOY_INSTANCE_LABEL              (staging | production-dryrun | production-live)
  AWS_SECRET_PREFIX                  (packiot/staging | packiot/production)
```

Documented in `CONTRIBUTING.md`. A new repo or environment can be onboarded by following the schema, not by reverse-engineering existing workflows.

### Pattern 8 — Standardized caching strategy

```yaml
# Go services:
- uses: actions/setup-go@<SHA>
  with:
    go-version: '1.24'
    cache: true                        # built-in module + build cache

# Docker buildx with GHA backend:
- uses: docker/setup-buildx-action@<SHA>
- uses: docker/build-push-action@<SHA>
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max

# Node services (operator, edge-nodered build steps):
- uses: actions/setup-node@<SHA>
  with:
    node-version: '20'
    cache: 'npm'
    cache-dependency-path: 'package-lock.json'
```

**Measured impact in similar setups:** Docker buildx GHA cache reduces rebuild times by ~10× on cache hit. Go module cache eliminates ~30s of dep-fetch per CI run. npm cache eliminates ~45s of `npm ci` per CI run.

---

## Consequences

### Positive
- **Onboarding a new repo or environment** drops from ~4 hours of copy-paste-and-pray to ~30 minutes (clone template, customize inputs, done).
- **Security posture jumps multiple levels** — OIDC removes static AWS creds; SHA pinning closes supply-chain vector; actionlint catches workflow bugs at PR time; environment protection adds deploy gates.
- **CI runtime drops** by 1-3 minutes per workflow once caching lands (Docker layer cache alone is dominant).
- **Workflow drift across repos** stops accumulating — one repo's improvement propagates to all consumers via version bump.
- **Audit trail** for prod deploys becomes legible (GitHub Environments log every approval / reject / who-pushed).

### Negative
- **Net new repo** (`packiot/.github`) introduces a new place to maintain CI/CD logic. The benefit is the shrinking of per-repo workflow files; the cost is one more place to know about.
- **Migration is multi-week.** Each pattern is shippable individually but the full set is ~4-6 weeks of focused work.
- **OIDC role setup** requires AWS IAM administrative access — non-trivial first-time setup (identity provider, trust policy, role permissions). Worth it but front-loaded effort.
- **Pinned SHAs break Dependabot's idempotent autopin** — a workflow consuming `@v4` always picks up `v4.x.y` updates silently; a SHA-pinned workflow requires explicit PR-merge. More controlled, but also more deliberate work per upgrade.
- **Environment protection adds friction to legitimate emergency hotfixes.** Mitigation: the reviewer can be a small list including the deployer themselves for staging (effectively self-approval), retains audit trail.

### Mitigations
- **`packiot/.github` is incrementally adopted.** Start with one reusable workflow (`reusable-deploy-stack.yml`) consumed by parent's `deploy-staging.yml` + `deploy-production.yml`. Expand to other workflows as their refactor lands.
- **Phasing respects production pinning.** Phase 1 touches only the safe-zone workflows; production-asset workflows (in `production-out-of-scope.md`) are explicitly deferred until coordinated refactor (separate ADR).
- **OIDC migration is per-environment.** Roll out OIDC for `staging` first, observe for 2 weeks, then `production-dryrun`, then any future env. Long-lived secrets stay until each migration is proven.
- **SHA pinning + Dependabot together** prevents the "we forgot to upgrade" tax — Dependabot opens the PRs on schedule.

---

## Alternatives considered

### A. Per-repo `deploy-template.yml` (status quo)
- ✅ Zero change
- ❌ All the duplication / drift problems persist
- ❌ Per-client deploy onboarding scales linearly in workflow files

### B. Make + shell scripts as the CI logic, GitHub Actions as a thin runner
- ✅ Logic is portable to GitLab CI / Jenkins / local development
- ❌ Doesn't address auth, environment protection, secret schema — those are GitHub-native concerns
- ❌ Loses the reusable-workflows benefit (workflow inputs as typed contracts)

### C. Adopt a third-party CI/CD platform (CircleCI, GitLab CI, Buildkite)
- ✅ Some platforms have richer reusability primitives (CircleCI orbs)
- ❌ Migration cost from GitHub Actions is enormous
- ❌ GitHub Actions is already deeply integrated (status checks, PR comments, OIDC); leaving cuts a lot of integration value

### D. Full org migration to Argo Workflows / Tekton / Flux (Kubernetes-native CI/CD)
- ✅ Powerful primitives for complex pipelines
- ❌ Requires running the orchestrator infrastructure
- ❌ Massive learning curve; abandons GitHub Actions ecosystem
- **Why not chosen:** wrong scale for Packiot. Worth revisiting at 100+ repos / 10+ teams.

---

## Implementation phases

Phases respect [`docs/production-out-of-scope.md`](../production-out-of-scope.md) — Phase 1-3 touch only the safe-zone workflows. Production-asset workflows refactor in Phase 5 under coordinated change-control.

| Phase | Scope | Effort | Risk |
|---|---|---|---|
| **0 — Design + ADR** | This document | done | N/A |
| **1 — Foundation for production deployment** | (a) Set up OIDC IAM provider + 2 roles (`github-actions-deployer-staging`, `github-actions-deployer-production`). (b) Extract `reusable-deploy-stack.yml` covering both staging + production. (c) Add actionlint + dependabot. (d) Pin all action SHAs in **parent stack only**. **This is the bare minimum for ADR-0003 phase 1.** | ~1 week | Low (parent staging only; rollback = revert PR) |
| **2 — Production deployment (ADR-0003 phase 1)** | Uses the patterns from Phase 1. `deploy-production.yml` is a 10-line caller of `reusable-deploy-stack.yml`. New IAM role, new env, new Secrets Manager namespace. | ~1 week | Low (greenfield prod-dryrun env, no production-asset overlap) |
| **3 — Org-level `packiot/.github` repo + submodule bump consolidation** | Create `packiot/.github`. Move `reusable-bump-parent.yml` there. Each submodule's `bump-stack-submodule.yml` becomes a 5-line caller. | ~1 week | Low (bump workflows are isolated, fail-soft, easy to revert) |
| **4 — Environment protection + secret schema migration** | Configure GitHub Environments for `staging`, `production-dryrun`. Audit + rename secrets to standardized schema (one rename PR per repo). Update CONTRIBUTING.md. | ~3-4 days | Low (additive — old secret names stay until consumers migrate) |
| **5 — Production-asset workflow refactor (CONSTRAINED — separate ADR)** | The pinned workflows (`enterprise-neopac-wil-deploy.yml`, `cpack-enterprise-deploy.yml`, `deploy-template.yml` in edge-nodered + operator, `deploy-main.yml` + `deploy-dev.yml` in edge-api) require their own ADR + coordinated change-control. Out of scope here; flagged for future work. | TBD | High (touches customer-facing deploys; coordinated with customer comms) |
| **6 — Cleanup + ongoing hygiene** | Caching audit per workflow, retention policies, workflow observability, anything turned up by actionlint, periodic SHA pin updates | ongoing | Low |

**Total focused effort for phases 1-4: ~3-4 weeks**, after which the new prod stack is live (dry-run mode) AND the safe-zone workflows are enterprise-grade. Phase 5 (production-asset refactor) is a deliberate future engagement requiring its own design + customer coordination.

---

## Open questions

These need answers before Phase 1 implementation begins:

1. **Org-level repo name.** `packiot/.github` (GitHub's special name) vs `packiot/workflows` (explicit) vs `packiot/actions` (action-style)?
2. **OIDC role naming.** `github-actions-deployer-staging` / `github-actions-deployer-production` (verb-noun) vs `gha-deploy-staging` (acronym) vs `packiot-cicd-staging` (org-prefixed)?
3. **SHA pinning cutover.** Parent only first (phase 1) → submodules later, or all-at-once?
4. **GitHub Environment `production-dryrun` reviewer.** Self-approval is allowed (deployer can approve own deploy)? Or require a second human?
5. **Bump-workflow consolidation timing.** Phase 3 (after prod live), or earlier (eats into ADR-0003 timeline but de-risks bump drift)?
6. **Dependabot autopin frequency.** Weekly (default) vs daily vs monthly? Affects PR volume on Mondays.
7. **What lives in `.github/actions/` (composite actions) vs `.github/workflows/` (reusable workflows)?** Composite actions are more granular (single steps) but harder to test in isolation. Reusable workflows are coarser (whole jobs) but easier to compose.
8. **Caching backend.** GitHub Actions cache (default, 10 GB per repo limit) vs S3 backend (unlimited, slower) vs Buildkite-style local runner cache?
9. **Should `actionlint` be a required check or advisory?** Required = can't merge if lint fails. Advisory = lint failures visible but don't block. Recommend required after a 2-week grace.
10. **How to handle secret rename migration safely?** New secret with new name, both consumed for 1 week, then old removed? Or atomic rename?

---

## References

External:
- [GitHub: Reusable workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows) — official docs for the `workflow_call` pattern
- [GitHub: OIDC for AWS](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services) — the OIDC migration guide
- [`actionlint`](https://github.com/rhysd/actionlint) — the workflow linter
- [`step-security/harden-runner`](https://github.com/step-security/harden-runner) — supply-chain hardening for self-hosted runners (defense in depth)
- [Google: SRE Workbook on canary releases](https://sre.google/workbook/canarying-releases/) — informs the Environment protection design
- [Dependabot for GitHub Actions](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/keeping-your-actions-up-to-date-with-dependabot) — auto-update mechanism

Internal:
- [`docs/production-out-of-scope.md`](../production-out-of-scope.md) — the pinning doc this ADR's phasing respects
- [`docs/caching-review-2026-06-29.md`](../caching-review-2026-06-29.md) — application caching (different from CI build caching covered here)
- [[ADR 0003]] — production deployment of parent stack; depends on phase 1 of this ADR
- [[ADR 0004]] — config centralization; the per-client config flow uses the reusable patterns proposed here
- [[ADR 0005]] — per-factory deploys; depends on phase 1 + phase 3 of this ADR (org-level reusable workflows + standardized secret schema)
