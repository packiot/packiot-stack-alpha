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
"verify every fact in the code", text-only diagrams, no secrets). CI builds the site with
`mkdocs --strict`, so broken links fail the build.

## Other material in `docs/` (not published in the wiki)

| Folder | What |
|---|---|
| [`adr/`](adr/) | Architecture Decision Records (indexed in [wiki/reference/adr-index.md](wiki/reference/adr-index.md)) |
| [`plans/`](plans/) | Design plans and work breakdowns |
| [`runbooks/`](runbooks/), [`ops/`](ops/) | Operational procedures (indexed in [wiki/operations/runbooks.md](wiki/operations/runbooks.md)) |
| [`clients/`](clients/) | Per-client configuration, descriptors and analyses |
| [`audits/`](audits/), reports at the top level | Point-in-time audits and status reports (dated; may be stale) |
| [`archive/wiki-v1/`](archive/wiki-v1/) | The previous Stack Wiki and Guide (superseded 2026-09-28; stale in places) |
