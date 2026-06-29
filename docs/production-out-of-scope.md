# Production assets — DO NOT TOUCH

**Status:** Authoritative. Reviewed: 2026-06-29.
**Owner:** Platform team.
**Read this before any infrastructure / workflow / deployment change.**

---

This document **pins** the production assets that the new prod-stack deployment effort (ADR-0003) and the workflow refactor (ADR-0006) must NOT modify. It exists because the new prod stack runs **in parallel** with existing prod — not as a replacement — and any accidental change to a pinned asset has direct customer impact.

The rule is simple: **if it's listed here, do not modify it without an explicit ADR + the listed-asset owner's sign-off.** Inventorying it as part of a refactor (PRs that touch the file alongside other changes) is the failure mode this doc prevents.

---

## Pinned: AWS resources

| Asset | Identifier | Why pinned |
|---|---|---|
| EB application | `eba-fkmv8pi5` | The legacy edge-api production deployment lives here |
| EB env (prod) | `edge-api-prod-docker-env` → `edge.api4.packiot.com` | Customer-facing production API |
| EB env (dev) | `edge-api-dev-docker-env` → `edge-dev.api4.packiot.com` | Customer-facing dev API (some customers use it) |
| ACM cert | `04755871-2577-4fb8-ae07-32643ea59ac2` (us-east-1) | TLS for the EB ALBs above |
| EB ALB hosted zone | `Z117KPS5GTRQ2G` (us-east-1) | AWS-managed; do not touch |
| Route53 hosted zone | `api4.packiot.com` (`Z00221828BXMPGOOHGI1`) | Production DNS — modifying records can break customer traffic |
| Route53 hosted zone | `dev.packiot.com` (`Z09213672Z2Z9WBSSD516`) | Production dev DNS |
| Production TimescaleDB | accessed via the `databaseCredentials` Secrets Manager secret | **NO writes, no schema changes, no DDL. SELECT-only via the awslambda role.** Already documented in the memory rule `feedback_prod_db_readonly.md`. |
| New Relic account / app | the entries tied to `edge-api-prod-docker-env` via `new-relic-change-tracking.yml` | Monitoring data for prod |

**Allowed:** read-only inspection (e.g., `aws ssm get-parameter`, EB console reads, Route53 `list-resource-record-sets`).
**Forbidden:** any `aws *-modify-*`, `aws *-delete-*`, `aws *-put-*`, Route53 `change-resource-record-sets`, EB `update-environment`, ACM cert deletion or renewal flip, schema migrations on the prod TimescaleDB.

---

## Pinned: Customer factory deployments

Each entry is a live customer factory running its own self-hosted GitHub Actions runner. **Anything that touches these breaks the customer's operator UI in real time.**

| Customer | Runner label | Deploy workflow(s) | Per-client GitHub Secrets |
|---|---|---|---|
| **Neopac Wil** | `neopac-wil` | `edge-node-red/.github/workflows/enterprise-neopac-wil-deploy.yml` + `operator/.github/workflows/neopac-wil-enterprise-deploy.yml` | `ENTERPRISE_NEOPAC_WIL_ID`, `ENTERPRISE_NEOPAC_WIL_API_KEY`, `ENTERPRISE_NEOPAC_WIL_PUBSUB_TOPIC`, `ENTERPRISE_NEOPAC_WIL_SERVICE_ACCOUNT`, `ENTERPRISE_NEOPAC_WIL_NODE_RED_HTTP` |
| **CPACK** | `cpack` | `operator/.github/workflows/cpack-enterprise-deploy.yml` (operator only — edge-node-red not yet per-client-deployed via runner) | `ENTERPRISE_CPACK_NODE_RED_HTTP` (others TBD) |

**Allowed:** read-only inspection of the workflow files; new workflow files that don't trigger on the same branches or use the same runner labels.
**Forbidden:** editing the above workflow files; renaming or deleting the listed secrets; changing the runner labels these workflows target; changing the per-enterprise deploy mechanism without explicit customer comms.

**Not pinned (safe to touch):** `enterprise-test-deploy.yml` files (test target, internal); the templates `deploy-template.yml` files — these are the LOGIC consumed by the pinned wrappers, so refactoring requires extra care (see "constrained refactor" section below).

---

## Pinned: Branches that auto-deploy to production assets

| Repo | Branch | Triggers |
|---|---|---|
| `packiot/edge-api` | `master` | `deploy-main.yml` → EB prod env `edge-api-prod-docker-env` |
| `packiot/edge-api` | `development` | `deploy-dev.yml` → EB dev env `edge-api-dev-docker-env` |

**Allowed:** PRs targeting `staging` branch on edge-api (which doesn't auto-deploy anywhere production).
**Forbidden:** force-push to `master` or `development`; PR-merging to either without the existing review process; modifying `deploy-main.yml` / `deploy-dev.yml` (they already deploy to prod assets).

Note: `master` (not `main`!) is the prod-deploying branch on edge-api. This naming pre-dates the GitHub default rename; do not "fix" it.

---

## Pinned: Workflow files that deploy to production assets

These files are pinned **as-is**. Refactoring them requires a separate change-control flow (see "constrained refactor" below).

| Repo | File | Why pinned |
|---|---|---|
| `edge-api` | `.github/workflows/deploy-main.yml` | Deploys to EB prod |
| `edge-api` | `.github/workflows/deploy-dev.yml` | Deploys to EB dev (customer-facing) |
| `edge-api` | `.github/workflows/new-relic-change-tracking.yml` | Notifies New Relic when deploys land on prod |
| `edge-node-red` | `.github/workflows/enterprise-neopac-wil-deploy.yml` | Deploys to live Neopac Wil factory |
| `edge-node-red` | `.github/workflows/deploy-template.yml` | Consumed by the above; refactoring breaks the call chain |
| `operator` | `.github/workflows/cpack-enterprise-deploy.yml` | Deploys to live CPACK operator UI |
| `operator` | `.github/workflows/neopac-wil-enterprise-deploy.yml` | Deploys to live Neopac Wil operator UI |
| `operator` | `.github/workflows/deploy-template.yml` | Consumed by the above |

---

## Safe to touch (the "sandbox" zone)

These are explicitly OK to modify as part of the prod-deployment effort + workflow refactor. They do not affect any production asset.

**Parent stack (`packiot-stack-alpha`):**
- `.github/workflows/deploy-staging.yml` (only deploys to the new staging env)
- `.github/workflows/pr-validation.yml`
- `.github/workflows/go-services.yml`
- `.github/workflows/build-postgres.yml`
- Anything under `terraform/staging/` — modifies only staging infra
- Anything new under `terraform/production/` — new resources, no overlap

**Submodules (parent-bumping workflows only):**
- `edge-api/.github/workflows/bump-stack-submodule.yml`
- `edge-node-red/.github/workflows/bump-stack-submodule.yml`
- `oeecloud-node-red/.github/workflows/bump-stack-submodule.yml`
- `operator/.github/workflows/bump-stack-submodule.yml`

**Test-target workflows:**
- `edge-node-red/.github/workflows/enterprise-test-deploy.yml`
- `operator/.github/workflows/enterprise-test-deploy.yml`

**Non-deploy workflows:**
- `edge-api/.github/workflows/pullrequests.yml` (PR validation only)
- `edge-node-red/.github/workflows/build.yml`, `ci.yml`
- `operator/.github/workflows/build.yml`, `pr-validation.yml`

**New resources:**
- `terraform/production/*` (new directory, zero overlap with existing infra)
- `compose.production.yml` (new file)
- `.github/workflows/deploy-production.yml` (new file)
- New Secrets Manager paths matching the pattern `packiot/production/*`
- New ACM certs for the new prod-stack domain (TBD)
- New Route53 records under a new hosted zone for the new prod-stack domain (TBD)

---

## Constrained refactor — `deploy-template.yml`

The `deploy-template.yml` files in `edge-node-red` and `operator` are **logically** good candidates for the ADR-0006 enterprise refactor (they're duplicated across repos, have the same shape, both consume the per-enterprise secret schema we want to standardise). BUT they're **called by pinned workflows** (`enterprise-neopac-wil-deploy.yml`, `cpack-enterprise-deploy.yml`).

**Refactor rule:** any change to `deploy-template.yml` must satisfy ALL of the following:

1. The new template MUST be backward-compatible with the pinned callers — no input rename, no input removal, no behavior change for the existing call sites.
2. Change is shipped as a separate PR, tested on `enterprise-test-deploy.yml` (the test target) FIRST.
3. Only after the test target's next deploy succeeds end-to-end (verified by the operator UI loading on `test`), the change can be merged.
4. Rollback plan: revert the PR. The pinned callers continue to work because of (1).

If the refactor requires breaking changes (input rename, behavior change), it must be paired with a coordinated update to ALL pinned callers in the same PR, with the test target rebuilt first and observed for 7 days minimum.

---

## How to use this doc

**Before any platform-engineering change:**

1. Cross-reference the files you're about to touch against the "Pinned" tables above.
2. If anything matches, escalate before continuing — get explicit owner sign-off recorded in the PR.
3. If touching `deploy-template.yml`, follow the "Constrained refactor" rule above.
4. Reference this doc in the PR description for any change that touches the surrounding area, even if the pinned assets themselves aren't modified — gives reviewers explicit context.

**When pinned assets change:**

This doc is the source of truth. Update it whenever a new customer onboards (new factory runner + secrets), a deploy mechanism changes, or an EB env is decommissioned. Stale pinning is worse than no pinning.

---

## Related

- `docs/adr/0003-production-deployment-parent-stack.md` — the new prod-stack effort; explicitly out-of-scopes touching anything pinned here.
- `docs/adr/0006-workflow-infrastructure-refactor.md` — the workflow enterprise refactor; references "Constrained refactor" above for its handling of `deploy-template.yml`.
- `.claude/projects/.../memory/feedback_prod_db_readonly.md` — the SELECT-only prod DB rule; consistent with this doc's prod TimescaleDB entry.
- `CLAUDE.md` (repo root) — the original source for the AWS resource IDs listed above.
