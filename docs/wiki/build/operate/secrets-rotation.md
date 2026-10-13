---
title: Rotate secrets
layer: guide
owner_area: identity
last_verified: 2026-10-13
---
# Rotate secrets

> **Build & operate · how-to.** Which secrets the platform uses, how each one reaches the
> process that reads it, and the safe order to rotate it. Names only. This page never
> contains a value, and neither should your terminal history. Up: [Build & operate](../index.md)

## The rule that matters

**Updating a secret is not the same as the process using it.** Most staging secrets are
copied once into a file on the host (`/opt/packiot/.env`, `/root/.gitconfig`) by
`terraform/staging/user_data/app_init.sh` or by a deploy step. Rotation always ends with
"get the new value to where it is read, then prove it works".

## Inventory (staging)

| Secret (AWS Secrets Manager) | Read by | Reaches the process via |
|---|---|---|
| `packiot/staging/app` | Most services (many keys: origin-verify header, Slack webhook, …) | `/opt/packiot/.env`, written by `app_init.sh` and deploy steps |
| `packiot/staging/db` | Database logins | `.env` |
| `packiot/staging/rabbitmq-*-creds` | Decoder, stream-engine, clients | Generated RabbitMQ definitions at deploy |
| `packiot/staging/historian-svc`, `historian-gateway-s3` | historian-gateway | `.env` / deploy step |
| `packiot/staging/agent-ingest` | sparkplug-agent ingest key | `.env` |
| `packiot/staging/github-pat` | The deploy runner's git (submodule fetch) | `/root/.gitconfig` `insteadOf` rule, written once by `app_init.sh` |
| `packiot/staging/github-runner` | Self-hosted runner registration | Runner setup |
| `packiot/staging/ghcr-read` | Pulling private images from GHCR | Deploy step (optional) |
| `packiot/dev/cognito` | Dev-environment users | Read by developers on demand |

Production has the same shape under `packiot/production/*`.

## GitHub tokens

| Where | Used for | If it expires |
|---|---|---|
| Secrets Manager `packiot/staging/github-pat` (key `token`) | The staging deploy runner fetching private submodules | **Every staging deploy fails** at *Fetch submodules* with `Authentication failed` |
| Repo secret `PARENT_REPO_TOKEN` in edge-api, operator4, edge-node-red | Each repo's bump bot opening the stack's submodule-bump PR | Merges in that repo never reach staging; the bot's run fails with `could not read Username` |
| Repo secret `DEV_SUBMODULES_TOKEN` in the stack repo (optional) | The `edge` dev slice in CI | The edge slice is skipped (CI stays green, but edge-api and the SPAs aren't smoke-tested) |

!!! warning "What happened on 2026-10-13"
    A personal access token set on 2026-09-15 expired. Staging deploys and the edge-api
    bump bot both started failing the same day, silently, and merged fixes stopped reaching
    staging. Prefer a **GitHub App** (installation tokens are short-lived and rotate
    themselves). If you must use a personal token, record its expiry date and the places it
    is used, and alert before it lapses.

### Rotate the GitHub token

1. Create the new credential with the least access needed. Read access to repository
   contents for `packiot-stack-alpha`, `edge-api`, `csadmin`, `operator4`, `front4` and
   `edge-node-red`; contents + pull-request write on `packiot-stack-alpha` for the bots.
2. Put it in Secrets Manager `packiot/staging/github-pat` (key `token`) and in each
   `PARENT_REPO_TOKEN` that uses it.
3. **Refresh the runner's git config.** `app_init.sh` only writes `/root/.gitconfig` at
   first boot. On the host, re-create the `url."https://x-access-token:<token>@github.com/packiot/".insteadOf`
   rule from the new secret value (read it into a variable; never echo it).
4. **Prove it:** re-run *Deploy to Staging* and check that *Fetch submodules* passes; merge
   a trivial change in a submodule repo, or re-run its bump workflow, and check that the bump PR appears.

## Rotate a value in `packiot/staging/app` or another `.env`-fed secret

1. Update the key in Secrets Manager.
2. Re-materialize it on the host. Re-running the relevant part of `app_init.sh`, or
   the deploy step that writes it, updates `/opt/packiot/.env`. Never `source` that file in a
   script: some values contain shell metacharacters. Extract single keys with `grep | cut`.
3. Recreate only the containers that read it (`docker compose … up -d <service>`), then
   check their health and one real request.

## Verify without printing secrets

```sh
aws secretsmanager describe-secret --secret-id <name> \
  --query '{changed:LastChangedDate,accessed:LastAccessedDate}'     # metadata only
docker compose -p stack exec <svc> sh -c 'test -n "$VAR" && echo set'  # presence, not value
```

## Related

- [Deploy](deploy.md): where a broken token shows up first.
- [Tenancy & security](../../understand/architecture/tenancy-and-security.md).
