---
title: Write docs
layer: guide
owner_area: platform
last_verified: 2026-10-13
---
# Write docs

> **Build & operate · how-to.** Where documentation goes, how to build this wiki locally,
> and how to keep READMEs, API specs and wiki pages linked. Up: [Build & operate](../index.md)

## Where does it go?

| You are documenting… | Put it in |
|---|---|
| How to run, test or change one service | That repo's / service's **README** |
| An HTTP endpoint | The **OpenAPI spec** in code ([Add an API endpoint](add-an-api-endpoint.md)); the wiki page is generated |
| How something works and why | **Understand**: architecture, subsystem or component page |
| A task an engineer performs | **Build & operate** how-to |
| A task Customer Success or the automation team performs | **Use Packiot**, in plain language |
| A decision and its trade-offs | An **ADR** in `docs/adr/` |
| A fact to look up | **Reference** |

The full rules (page types, front matter, templates, "verify every fact in the source",
no secrets, text-only diagrams) are in `docs/WIKI-STYLE.md` in the stack repo.

## Build the wiki locally

```sh
STRICT=1 scripts/build-wiki.sh    # stages docs/wiki + ADRs, generates API pages, mkdocs --strict
xdg-open dist/wiki/index.html
```

`--strict` turns every broken link or missing anchor into a failure; CI builds the same way.
The script bootstraps a venv from `wiki/requirements.txt` if `mkdocs` isn't installed.

## Keep the docs linked

| When you… | Also update |
|---|---|
| Add a service | A row in the [service catalog](../../reference/service-catalog.md), a component page, the README "Related docs" links |
| Add or change an endpoint | Nothing in the wiki: the API pages regenerate from the spec |
| Move or rename a wiki page | Add the old path to `redirects` in `wiki/mkdocs.yml` so old URLs keep working |
| Add a Grafana dashboard for a service | Its service-catalog row |

## Publishing

Merging to `staging` runs `build-wiki.yml`, which builds the site and syncs it to S3; the
wiki host pulls it every 5 minutes. See [Wiki pipeline](../../understand/components/wiki-pipeline.md).
