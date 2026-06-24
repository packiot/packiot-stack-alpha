# Contributing to packiot-stack-alpha

This repo is the **aggregator** for the Packiot stack. It pins 3 service
repos as submodules and is the only thing deployed to AWS staging EC2. The
service repos do their own testing in isolation; this repo runs the
integration via `docker compose`.

If you're new to the codebase, start with `CLAUDE.md` at the repo root for
the architecture overview. This file is about **workflow** — branches,
PRs, deploys, and how the auto-bump chain wires it all together.

---

## TL;DR

```
┌───────────────────────────────────────────────────────────────┐
│  development  →  scratchpad, devs work here, NOT deployed     │
│  staging      →  alpha-production, deploys to AWS automatically│
│  main         →  reserved for future production tier (not used)│
└───────────────────────────────────────────────────────────────┘
```

- Feature branches off `development`. PR to `development`. PR to `staging`
  to promote. Auto-deploy fires on `staging`.
- Submodules track their own `staging` / `development` branches. The
  parent repo's pointer is updated automatically by a bot workflow on each
  submodule.
- **Parent `staging` is protected**. Direct push is blocked. Every change
  goes through a PR that must pass the **PR Validation** check
  (`docker compose config`).

---

## The two-branch model

| Branch | Purpose | Deploys? | Protected? |
|---|---|---|---|
| `development` | Local scratchpad. Devs run `make` here. Integration of feature branches before promotion. | No | No |
| `staging` | "Alpha production" — deploys to AWS staging EC2 via `deploy-staging.yml`. | Yes (auto on push) | Yes (ruleset "Protect staging") |
| `main` | Reserved for a future real-production tier. Don't push here. | No | (Not currently used) |

### The flow

```
Developer's feature work:
  1. git checkout development
  2. git checkout -b feature/<thing>
  3. ...edit, commit...
  4. PR → development
  5. PR review + merge

Promote to staging:
  6. PR development → staging
  7. PR Validation runs (required)
  8. Squash-merge
  9. deploy-staging.yml fires → AWS staging EC2 redeploys
```

---

## Submodules — the auto-bump chain

The 3 service repos are submodules. The parent's `.gitmodules` tracks each
on `staging` as their default branch:

```
edge-api          → packiot/edge-api
edge-node-red     → packiot/edge-node-red
operator          → packiot/operator4   (note: repo name ≠ path name)
```

> Historically there was a 4th submodule, `oeecloud-node-red`. It was
> decommissioned 2026-06-24 — replaced by `services/oeecloud-worker` (Go),
> which lives in-repo as a regular subdir (not a submodule).

Each submodule has a workflow `bump-stack-submodule.yml` that fires on push
to its own `staging` or `development` branches. The workflow opens a PR on
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
   │  - validates both compose.staging.yml and    │
   │    compose.development.yml                   │
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
targets parent's `development` branch. There's no deploy on `development`.

### Requirements per submodule

- Secret `PARENT_REPO_TOKEN` set with `contents:write` AND
  `pull-requests:write` on `packiot/packiot-stack-alpha`.
- A `development` branch must exist before the workflow can bump there.

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
git checkout development
git submodule update --remote --merge   # pull the freshest staging tip
                                          # of each submodule
```

Then run the full stack locally:

```sh
docker compose -f compose.development.yml up -d --build
```

(Each submodule also has its own `make test` / `npm test` / equivalent for
isolated testing of just that service. Use those for fast inner loops.)

If you only need to validate that the compose files are well-formed
(no actual containers):

```sh
docker compose -f compose.development.yml config --no-interpolate -q
docker compose -f compose.staging.yml config --no-interpolate -q
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

- `development` is the scratchpad — devs want fast iteration. Workflow
  convention is "PR to development", not enforcement.
- `main` is reserved for a future production tier and isn't actively used.

---

## Hotfix protocol

If `staging` is broken and you need to push a fix that doesn't go through
`development` first:

1. `git checkout staging && git pull`
2. `git checkout -b hotfix/<description>`
3. Edit, commit.
4. PR → `staging`. PR Validation runs.
5. Squash-merge once green.
6. **Back-merge to `development`** to prevent regression on the next
   promotion:

   ```sh
   git checkout development
   git pull
   git merge staging
   git push
   ```

Same pattern in a submodule repo (substitute `staging` with the
submodule's `staging`).

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
4. Update `compose.staging.yml` and `compose.development.yml` to reference
   the new service.
5. Open a PR to parent `staging` adding the gitlink + compose changes.

---

## CI checks reference

| Workflow | Trigger | Job name | Required? |
|---|---|---|---|
| `pr-validation.yml` | PR to `staging` or `development` | `Validate compose files` | Yes (on `staging`) |
| `deploy-staging.yml` | push to `staging` | `deploy` | (post-merge, not a check) |
| `build-postgres.yml` | push to `main` (path `db/**`) | `build-and-push` | No |

---

## See also

- `CLAUDE.md` (repo root) — architecture, data flow, service map.
- Each submodule's own `CLAUDE.md` if present — service-specific
  conventions.
