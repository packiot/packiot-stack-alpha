---
title: Build & operate
layer: 0
owner_area: platform
last_verified: 2026-10-13
---
# Build & operate

> **Engineering how-tos.** Each page is one task, with the exact commands, how to verify it
> worked, and what to do if it didn't. For *why* things work the way they do, see
> [Understand](../understand/index.md). Up: [Packiot docs](../index.md)

## Develop

| Task | Page |
|---|---|
| Run the stack on your laptop | [Local development](develop/local-development.md) |
| Branch, open a PR, pass the checks, deploy to staging | [Branches, merging & deploying](develop/branches-and-merging.md) |
| Add a new service | [Add a service](develop/add-a-service.md) |
| Change the database schema | [Add a migration](develop/add-a-migration.md) |
| Add or change an HTTP endpoint (with its OpenAPI spec) | [Add an API endpoint](develop/add-an-api-endpoint.md) |
| Write or change these docs | [Write docs](develop/write-docs.md) |

## Operate

| Task | Page |
|---|---|
| Something is broken: find the symptom | [Runbooks](operate/runbooks.md) |
| Deploy, roll back, re-run a deploy | [Deploy](operate/deploy.md) |
| Rotate a secret or token | [Rotate secrets](operate/secrets-rotation.md) |
| Change nginx / a public host safely | [Change nginx config](operate/nginx-config-changes.md) |
| Back up and restore a database | [Backups & restore](operate/backups-and-restore.md) |
| Onboard a client (technical side) | [Onboarding a client](operate/onboarding-a-client.md) |
| Install a factory box for the first time | [First-time box setup](operate/first-time-box-setup.md) |
| Work on the database safely | [DBA guide](operate/dba-guide.md) |
