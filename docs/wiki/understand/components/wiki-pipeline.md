---
title: Wiki pipeline
layer: 3
owner_area: platform
last_verified: 2026-10-13
---
# Wiki pipeline

> **Layer 3 · Components** — how this wiki goes from Markdown in the repo to pages at
> `wiki.packiot.app`: `scripts/build-wiki.sh`, the generated API pages, the strict mkdocs
> build, the `build-wiki.yml` workflow and the S3 pull model to the serving box. For anyone
> writing or publishing docs.
> Up: [Platform & operations](../subsystems/platform.md) ·
> [How to write docs](../../build/develop/write-docs.md) ·
> [Service catalog](../../reference/service-catalog.md)

## Responsibility

Turn the committed documentation into a static, self-contained, searchable HTML site,
fail the build on any broken link, and deliver the site to the box that serves it without
that box ever being rebuilt. How to *write* pages is a separate contract:
`docs/WIKI-STYLE.md` (sections, layer templates, front matter, text-only diagrams,
relative links, no secrets). The pipeline serves no API.

## At a glance

| Item | Value |
|---|---|
| Generator | mkdocs-material `9.5.44` + `mkdocs-redirects` `1.2.2`, pinned in `wiki/requirements.txt` |
| Config | `wiki/mkdocs.yml` (`docs_dir: build/staging/docs`, `site_dir: ../dist/wiki`, `site_url: https://wiki.packiot.app/`, `theme.font: false`) |
| Source | `docs/wiki/` (one tree), top-level `docs/adr/*.md`, `docs/api/openapi/*.openapi.json` |
| Build script | `scripts/build-wiki.sh` → `dist/wiki/`; `STRICT=1` → `mkdocs build --strict` |
| CI | `.github/workflows/build-wiki.yml`, job **"build merged docs site"** (strict) + S3 deploy job |
| Transport | S3 bucket `packiot-wiki-dist-<account-id>`, prefix `wiki/` |
| Serving box | new-stack production app host (named in `scripts/wiki-box-sync.sh`), nginx vhost `wiki.packiot.app`, root `/var/www/wiki`, behind the production oauth2 gate (`auth.prod.packiot.app`) |
| Puller | `/usr/local/bin/wiki-box-sync.sh` from cron every 5 min, env in `/etc/default/wiki-box-sync` |

## Inputs & outputs

```text
 docs/wiki/**        docs/adr/NNNN-*.md        docs/api/openapi/*.openapi.json
      │ copy               │ copy + rewrite links      │ scripts/wiki-openapi-to-md.py
      ▼                    ▼                           ▼
 wiki/build/staging/docs/ (tree)   /adr/ (not in nav)   reference/api/<api>.md (generated)
      │ mkdocs build --strict (+ redirects plugin)
      ▼
 dist/wiki/  (static HTML + search index + meta-refresh redirect pages)
      │ build-wiki.yml, on push to staging/production
      ▼
 aws s3 sync --delete  ──►  s3://packiot-wiki-dist-<account>/wiki/
      │ box cron every 5 min: wiki-box-sync.sh (aws s3 sync --delete)
      ▼
 /var/www/wiki  ──nginx + oauth2──►  https://wiki.packiot.app
```

## Internal design

### Structure (2026-10-13 restructure)

The tree is organised by reader task (Diátaxis by audience), one folder per nav section:
**Learn** (`learn/`, tutorials), **Use Packiot** (`use/`, plain-language how-tos for CS and
the automation team), **Build & operate** (`build/develop/`, `build/operate/`),
**Understand** (`understand/architecture/` → `subsystems/` → `components/`, layers 1-3) and
**Reference** (`reference/`, plus generated `reference/api/`). Pages moved by the
restructure (`scripts/wiki-restructure.py`, a one-shot that rewrote every relative link)
keep their old URLs through the `redirects` plugin's `redirect_maps` in `wiki/mkdocs.yml`.

### Assembly (`scripts/build-wiki.sh`)

1. Wipe and recreate `wiki/build/staging/docs/` (idempotent).
2. Copy `docs/wiki/.` (fails if `docs/wiki/index.md` is missing).
3. Copy top-level `docs/adr/*.md` into `adr/` and run `scripts/wiki-rewrite-adr-links.py`,
   which points ADR links to non-published repo files at GitHub (`$WIKI_GITHUB_REF`, default
   `staging`) so `--strict` passes. `docs/adr/reference/` is not copied; ADRs are
   `not_in_nav`.
4. Generate one page per API: `scripts/wiki-openapi-to-md.py docs/api/openapi
   <staging>/reference/api` (stdlib only). Each page carries `layer: 4`, `generated: true`
   and a link to the read-only Swagger UI portal at `api.staging.packiot.app/docs/`.
   `reference/api/index.md` is hand-written.
5. Find mkdocs (on PATH, else bootstrap `wiki/.venv-wiki` unless `NO_VENV=1`) and run
   `mkdocs build --config-file wiki/mkdocs.yml --clean ${STRICT:+--strict}`.

### Where the API specs come from

`make openapi` in the stack writes `docs/api/openapi/`: the Go services' embedded specs are
copied, read-api's is produced by `refdata-api --dump-openapi`, and edge-api's is read from
the **pinned** `edge-api` submodule commit (`openapi/edge-api.openapi.json`, written there by
edge-api's `npm run openapi:export`). Without the private submodule (CI), the committed copy
is kept. `openapi-export.yml` fails a PR whose committed specs differ from `make openapi`.
See [Add an API endpoint](../../build/develop/add-an-api-endpoint.md).

### Why mkdocs-material and why text diagrams

It produces fully static HTML with a build-time search index and, with `theme.font: false`,
fetches nothing from a CDN at runtime. The site is served behind oauth2 with a strict
origin, so a runtime CDN fetch (Google Fonts, Mermaid) would break. Hence ` ```text `
diagrams. Redirects are meta-refresh HTML pages, no JavaScript.

### Link checking

`mkdocs.yml` sets `validation` (`omitted_files`, `absolute_links`, `unrecognized_links`,
`anchors`, `nav.omitted_files`, `nav.not_found`) to `warn`, and CI builds with `--strict`,
which turns every warning into a failure. Links must be relative from the page's own folder;
links to repo files outside the wiki use full GitHub URLs.

### CI (`build-wiki.yml`)

| Job | When | Does |
|---|---|---|
| `build` ("build merged docs site") | push to `staging`/`production`, PRs, dispatch; only when `docs/wiki/**`, `docs/WIKI-STYLE.md`, `docs/adr/**`, `docs/api/openapi/**`, the two scripts, `wiki/**` or the workflow change | checkout, Python 3.12, `pip install -r wiki/requirements.txt`, `NO_VENV=1 STRICT=1 scripts/build-wiki.sh`, upload artifact `wiki-site` (14 days) |
| `deploy` | push events only | skip unless var `WIKI_S3_BUCKET` and secret `AWS_ROLE_ARN` are set; OIDC assume role; `aws s3 sync dist/wiki/ s3://$WIKI_S3_BUCKET/wiki/ --delete --cache-control "public, max-age=300"` |

On 2026-10-13 the deploy job is configured and syncing.

### Why pull, not push

The serving host has `ignore_changes = [user_data]`, so it never re-runs boot scripts. CI only
needs S3 write on one prefix (no `ssm:SendCommand`, no instance targeting), and the box
catches up within 5 minutes.

## Configuration

| Name | Where | Default | Effect |
|---|---|---|---|
| `STRICT` | build script env | unset | `1` = `mkdocs build --strict` (CI) |
| `NO_VENV` | build script env | `0` | `1` = require mkdocs on PATH (CI) |
| `WIKI_GITHUB_REF` | ADR link rewriter env | `staging` | branch for GitHub links in ADRs |
| `WIKI_S3_BUCKET` | repo Actions variable; `/etc/default/wiki-box-sync` on the box | — | transport bucket |
| `AWS_ROLE_ARN` | repo Actions secret | — | OIDC role for the sync |
| `WIKI_S3_PREFIX` | box env | `wiki` | S3 prefix |
| `WIKI_WWW_ROOT` | box env | `/var/www/wiki` | served directory |

`/etc/default/wiki-box-sync` must use `export VAR=…`: the cron line sources it, and a
non-exported variable is not inherited by the puller.

## Data & invariants

- Both syncs use `--delete`: S3 and `/var/www/wiki` mirror the last build; a page removed
  from the repo disappears (add a redirect when you move one).
- Generated API pages exist only in the build tree, never in the repo.
- The output contains no secrets because the source contains none (style-guide rule 4;
  `gitleaks.yml` scans every PR, so never inline key-like literals, even fake ones).

## Observability

- CI: the `build-wiki` run log (strict warnings appear as the failure reason) and the
  `wiki-site` artifact; the deploy step's `Synced to s3://…` notice.
- Box: `/var/log/wiki-sync.log` (one line per successful sync).

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Build fails in CI, not locally | `Aborted with N warnings in strict mode` | a broken relative link or anchor; local build without `STRICT=1` | build with `STRICT=1 scripts/build-wiki.sh` |
| Old URL 404s | bookmark to a moved page | no `redirect_maps` entry | add the mapping in `wiki/mkdocs.yml` |
| API page stale | wiki shows an old contract | spec not re-exported, or edge-api submodule not bumped | `npm run openapi:export` in edge-api, bump, `make openapi` |
| Deploy job skipped | "WIKI_S3_BUCKET … not set — skipping" notice | var/secret missing | set both |
| Box never updates | stale pages, empty sync log | env not exported in `/etc/default/wiki-box-sync`, or the instance role lacks S3 read | fix export / IAM |
| IaC drift | resources unknown to Terraform | bucket, OIDC role and box policy were CLI-created on 2026-09-02 (record: `docs/archive/wiki-v1/wiki-deploy.md`) | import into Terraform (open follow-up) |

## Operating it

```bash
STRICT=1 scripts/build-wiki.sh             # local strict build, venv bootstrapped if needed
python3 -m http.server -d dist/wiki 8000   # preview at http://localhost:8000
gh workflow run build-wiki.yml --ref staging   # rebuild + publish without a docs change
# on the serving box (via SSM), force a pull now:
sudo sh -c '. /etc/default/wiki-box-sync && /usr/local/bin/wiki-box-sync.sh'
```

## Tests

The strict `build` job on every docs PR is the test: zero warnings or it fails.

## Source map

| Path | What's there |
|---|---|
| `docs/WIKI-STYLE.md` | writing rules and page templates |
| `scripts/build-wiki.sh` | assembly + build |
| `scripts/wiki-openapi-to-md.py` | OpenAPI → API reference pages |
| `scripts/wiki-rewrite-adr-links.py` | ADR link rewriting for `--strict` |
| `scripts/wiki-restructure.py` | the one-shot 2026-10-13 move + link rewrite |
| `wiki/mkdocs.yml`, `wiki/requirements.txt` | generator config, nav, redirects, pinned toolchain |
| `.github/workflows/build-wiki.yml` | CI build + S3 sync |
| `Makefile` (`openapi`), `.github/workflows/openapi-export.yml` | spec vendoring and drift check |
| `scripts/wiki-box-sync.sh` | box-side puller |
| `docs/archive/wiki-v1/wiki-deploy.md` | one-time wiring record (bucket, roles, cron) |
