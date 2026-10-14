---
title: Deploy
layer: guide
owner_area: platform
last_verified: 2026-10-13
---
# Deploy

> **Build & operate · how-to.** How a change reaches staging, how to re-run or roll back a
> deploy, and what the deploy does *not* do. Up: [Build & operate](../index.md)

**Goal:** get a merged change running on staging, and know it is really running.

## How a change reaches staging

```text
 PR to staging ──► required checks ──► merge ──► "Deploy to Staging" workflow
 (stack repo)      Validate compose files        (.github/workflows/deploy-staging.yml)
                   dev slices gate                    │
                                                      ├─ gate job (GitHub-hosted)
 submodule repo ──► merge to its staging ──► bump bot  │   skips a run whose commit is
 (edge-api, …)                               opens a   │   already superseded by a newer one
                                             bump PR ──┘
                                                      └─ deploy job (self-hosted runner
                                                         on the staging app host)
```

Changes in a **submodule repo** (edge-api, operator4, csadmin, edge-node-red) reach
staging only when the stack repo's submodule pointer moves. edge-api, operator4 and
edge-node-red have a bump bot that opens and auto-merges that PR; csadmin is bumped by
hand. See [Repositories](../../reference/repositories.md) for which branch of each repo deploys where.

## What the deploy job does, in order

1. Checks out the stack repo and fetches the submodules it builds (`edge-api`,
   `edge-node-red`, `operator`, `csadmin`) with the GitHub token configured on the runner.
2. Links `/opt/packiot/.env`, and materializes values the stack needs (RabbitMQ
   definitions, the optional Alertmanager Slack webhook, historian service password).
3. Resolves compose profiles from `.env` `COMPOSE_PROFILES` plus `shared-tee`.
4. `docker compose -f compose.staging.yml -f compose.superset.yml -p stack build`, then
   `up -d --remove-orphans`.
5. Reloads or restarts what `up -d` does not pick up on its own: Prometheus, Alloy,
   Alertmanager config reloads; Loki and postgres-exporter restarts when their config changed.
6. **Post-deploy gate:** every expected service must be running/healthy (one-shot init jobs
   must have exited 0) within 6 minutes, or the run fails.
7. End-to-end checks: a synthetic Sparkplug counter is injected and followed through the
   decoder; a RabbitMQ chaos test proves outbox durability; schema and int-overflow sentinels.

## Check it worked

```sh
gh run list --branch staging --workflow "Deploy to Staging" --limit 3
gh run view <run-id> --json jobs --jq '.jobs[]|"\(.name) \(.conclusion)"'
```

A run that says **"Superseded by <sha> … skipping"** deployed nothing on purpose: a newer
commit's run owns staging. The run list order is not the order things were deployed.

## Re-run or roll back

| You want to… | Do |
|---|---|
| Re-run a failed deploy of the current tip | Actions → Deploy to Staging → *Run workflow* on `staging` (or `gh workflow run deploy-staging.yml --ref staging`) |
| Roll back a bad change | Revert the PR on `staging`; the revert's deploy rolls it out. Don't hand-edit the host |
| Roll back a submodule change | Revert in the submodule repo's `staging`, then bump (or revert the bump PR in the stack) |

## What the deploy does NOT do

| Not done by the deploy | How it happens instead |
|---|---|
| nginx config (`terraform/staging/user_data/nginx_setup.sh`) | [Change nginx config](nginx-config-changes.md) |
| Database migrations (`db/migrations/`) | Applied deliberately; see [Add a migration](../develop/add-a-migration.md) |
| Secrets and tokens | [Rotate secrets](secrets-rotation.md) |
| Production | The release/promotion runbook; production is not deployed from `staging` |

## If it went wrong

| Symptom in the run log | Cause | Fix |
|---|---|---|
| `Authentication failed for 'https://github.com/packiot/<repo>.git/'` at *Fetch submodules* | The runner's GitHub token (Secrets Manager `packiot/staging/github-pat`) expired or was revoked | [Rotate secrets → GitHub tokens](secrets-rotation.md#github-tokens) |
| Post-deploy gate lists a service as `created`/`exited` | The container failed to start or a dependency never became healthy | `docker logs` for that service on the host; the gate prints the state of every service |
| Bump PR never appears after a submodule merge | The submodule repo's bump bot failed (often the same expired token) | Check the bot's workflow run in that repo; bump by hand meanwhile |
