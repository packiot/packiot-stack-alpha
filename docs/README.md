# Packiot Stack — Documentation

The engineering documentation for the Packiot platform lives in **[`wiki/`](wiki/index.md)**
and is published at **wiki.packiot.app**. It is written in layers; start at the top and go
down only as far as you need:

| Layer | Start here | Answers |
|---|---|---|
| 0 · Start here | [wiki/index.md](wiki/index.md), [glossary](wiki/glossary.md) | What is Packiot? What should I read for my role? |
| 1 · Architecture | [wiki/architecture/overview.md](wiki/architecture/overview.md) | How does the whole system fit together? |
| 2 · Subsystems | [wiki/subsystems/](wiki/subsystems/) | What does each part own, and how do parts talk? |
| 3 · Components | [wiki/components/](wiki/components/) | How does one service work, down to config, SQL and failure modes? |
| 4 · Reference & ops | [wiki/reference/](wiki/reference/), [wiki/operations/](wiki/operations/) | Look it up; do the task |

Writing or changing a page: follow **[WIKI-STYLE.md](WIKI-STYLE.md)** (layers, templates,
"verify every fact in the code", text-only diagrams, no secrets). The site is assembled by
`scripts/build-wiki.sh` (the layered `docs/wiki/` tree plus `docs/adr/*.md`) and built by
`.github/workflows/build-wiki.yml` with `mkdocs --strict` on PRs and pushes that touch those paths, so
broken links fail the build. Pushes to `staging`/`production` also sync the built site to S3, from where
the wiki host pulls it.

## Other material in `docs/` (not published in the wiki, except the top-level ADRs)

| Folder | What |
|---|---|
| [`adr/`](adr/) | Architecture Decision Records; the top-level `NNNN-*.md` files are also published in the wiki under `/adr` (indexed in [wiki/reference/adr-index.md](wiki/reference/adr-index.md)) |
| [`api/openapi/`](api/openapi/) | OpenAPI specs of the Go services' HTTP APIs, exported by `make openapi` (the "OpenAPI export is current" workflow fails a PR on drift); browsable in the API portal at https://api.staging.packiot.app/docs/ (SSO). edge-api's spec lives in the edge-api repo |
| [`dev/`](dev/) | Local dev environment contracts ([dev/contracts.md](dev/contracts.md)); the how-to is [`../dev/README.md`](../dev/README.md) |
| [`plans/`](plans/) | Design plans and work breakdowns |
| [`specs/`](specs/) | Functional specifications owned by product (business rules `RN-`, acceptance criteria `AC-`) that Jira cards cite by ID, e.g. [specs/PRODT-157-operator-app.md](specs/PRODT-157-operator-app.md) and its [backlog](specs/PRODT-157-operator-backlog.md) |
| [`runbooks/`](runbooks/), [`ops/`](ops/) | Operational procedures (indexed in [wiki/operations/runbooks.md](wiki/operations/runbooks.md)) |
| [`clients/`](clients/) | Per-client configuration, descriptors and analyses |
| [`ingestion/`](ingestion/), [`reference/`](reference/) | Ingestion designs and client tee functions; schema maps, topic contracts and fixtures |
| [`audits/`](audits/), reports at the top level | Point-in-time audits and status reports (dated; may be stale) |
| [`archive/wiki-v1/`](archive/wiki-v1/) | The previous Stack Wiki and Guide (superseded 2026-09-28; stale in places) |

Service-level READMEs (one per deployable under `services/`) are indexed in
[`../services/README.md`](../services/README.md).
