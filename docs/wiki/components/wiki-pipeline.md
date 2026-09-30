---
title: Wiki pipeline
layer: 3
owner_area: platform
last_verified: 2026-09-28
---
# Wiki pipeline

> **Layer 3 · Components** — how this wiki goes from Markdown in the repo to pages at
> `wiki.packiot.app`: the mkdocs build, `scripts/build-wiki.sh`, the `build-wiki.yml`
> workflow and the S3 pull model to the serving box. For anyone writing or publishing docs.
> Up: [Platform & operations](../subsystems/platform.md)

## Responsibility

Turn the committed documentation into a static, self-contained, searchable HTML site and
deliver it to the box that serves it, without that box ever needing to be rebuilt. How to
*write* pages is a separate contract: `docs/WIKI-STYLE.md` in the repo (layers, templates,
front matter, text-only diagrams, relative links, no secrets).

!!! note "Build script in transition"
    The maintainer is changing `scripts/build-wiki.sh` to copy the new layered `docs/wiki/`
    tree (`architecture/`, `subsystems/`, `components/`, `reference/`, `operations/`). The
    version on 2026-09-28 copies only top-level `docs/wiki/*.md`. This page describes the
    pipeline generically; check the script for the exact copy rules.

## At a glance

| Item | Value |
|---|---|
| Generator | mkdocs-material, pinned in `wiki/requirements.txt` (`mkdocs-material==9.5.44`) |
| Config | `wiki/mkdocs.yml` (`docs_dir: build/staging/docs`, `site_dir: ../dist/wiki`, `site_url: https://wiki.packiot.app/`) |
| Build script | `scripts/build-wiki.sh` → `dist/wiki/` |
| CI | `.github/workflows/build-wiki.yml` (ubuntu-latest) |
| Transport | S3 bucket `packiot-wiki-dist-<account-id>`, prefix `wiki/` |
| Serving box | new-stack production app host (`i-02d255a1c21fb1da3` per `docs/wiki-deploy.md`), nginx vhost `wiki.packiot.app`, root `/var/www/wiki`, behind the oauth2 gate |
| Puller | `/usr/local/bin/wiki-box-sync.sh` from cron `*/5 * * * *`, env in `/etc/default/wiki-box-sync` |

## Inputs & outputs

```text
 docs/wiki/**  docs/guide/*.md  docs/adr/*.md  wiki/pages/*.md
        │ scripts/build-wiki.sh assembles
        ▼
 wiki/build/staging/docs/  ──mkdocs build──►  dist/wiki/  (static HTML + search index)
        │ build-wiki.yml, on push to staging/production only
        ▼
 aws s3 sync --delete  ──►  s3://packiot-wiki-dist-<account>/wiki/
        │ box cron every 5 min: wiki-box-sync.sh (aws s3 sync --delete)
        ▼
 /var/www/wiki  ──nginx──►  https://wiki.packiot.app
```

## Internal design

### Assembly (`scripts/build-wiki.sh`)

1. Wipe and recreate `wiki/build/staging/docs/` (idempotent).
2. Copy the generated Home and Onboarding pages from `wiki/pages/`.
3. Copy the Guide from the working tree `docs/guide/*.md` (required).
4. Copy the wiki from the working tree `docs/wiki/`, or, if absent, extract it from
   `$WIKI_REF` (default `origin/staging`) with `git ls-tree`/`git show`. The build fails if the
   wiki landing page is missing.
5. Copy top-level `docs/adr/*.md` into `adr/` so cross-references resolve. `docs/adr/reference/`
   is **not** copied. ADRs are excluded from the nav (`not_in_nav: /adr/**`).
6. Find mkdocs: on PATH, else (unless `NO_VENV=1`) bootstrap `wiki/.venv-wiki`.
7. `mkdocs build --config-file wiki/mkdocs.yml --clean`.

### Why mkdocs-material and why text diagrams

It produces fully static HTML with a search index built at build time and, with
`theme.font: false`, fetches nothing from a CDN at runtime. The site is served behind oauth2
with a strict origin, so any runtime CDN fetch (Google Fonts, Mermaid) would break. That is why
the style guide requires ` ```text ` diagrams instead of Mermaid.

### Link checking

`mkdocs.yml` sets `validation` for `omitted_files`, `absolute_links` and `unrecognized_links`
to `warn` (non-strict build). The style guide states the build is link-checked, so treat any
new warning from your page as an error. Links must be relative from the page's folder.

### CI (`build-wiki.yml`)

| Job | When | Does |
|---|---|---|
| `build` | push to `staging`/`production`, PRs, dispatch — only when `docs/wiki/**`, `docs/guide/**`, `docs/adr/**`, `wiki/**`, the script or the workflow change | checkout with full history, Python 3.12, `pip install -r wiki/requirements.txt`, `NO_VENV=1 WIKI_REF=origin/staging scripts/build-wiki.sh`, upload artifact `wiki-site` (14 days) |
| `deploy` | push events only | guard: skip unless var `WIKI_S3_BUCKET` and secret `AWS_ROLE_ARN` are set; OIDC assume role (`packiot-wiki-ci-deploy`); `aws s3 sync dist/wiki/ s3://$WIKI_S3_BUCKET/wiki/ --delete --cache-control "public, max-age=300"` |

### Why pull, not push

The serving host has `ignore_changes = [user_data]`, so it never re-runs boot scripts. CI only
needs `s3:PutObject/DeleteObject/ListBucket` on one prefix (no `ssm:SendCommand`, no instance
targeting), and the box self-heals within 5 minutes.

## Configuration

| Name | Where | Default | Effect |
|---|---|---|---|
| `WIKI_REF` | build script env | `origin/staging` | where to read `docs/wiki` if not in the working tree |
| `NO_VENV` | build script env | `0` | `1` = require mkdocs on PATH (CI) |
| `WIKI_S3_BUCKET` | repo Actions variable; `/etc/default/wiki-box-sync` on the box | — | transport bucket |
| `AWS_ROLE_ARN` | repo Actions secret | — | OIDC role for the sync |
| `WIKI_S3_PREFIX` | box env | `wiki` | S3 prefix |
| `WIKI_WWW_ROOT` | box env | `/var/www/wiki` | served directory |

`/etc/default/wiki-box-sync` must use `export VAR=…`: the cron line sources it and a
non-exported variable is not inherited by the puller.

## Data & invariants

- Both syncs use `--delete`: S3 and `/var/www/wiki` are exact mirrors of the last build; a page
  removed from the repo disappears from the site.
- The build output contains no secrets because the source contains none (style-guide rule 4;
  `gitleaks.yml` scans every PR).

## Observability

- CI: the `build-wiki` run log and the uploaded `wiki-site` artifact.
- Box: `/var/log/wiki-sync.log` (one line per successful sync).

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Deploy job skipped | "WIKI_S3_BUCKET … not set — skipping" notice | var/secret missing | set both (see `docs/wiki-deploy.md`) |
| Box never updates | stale pages, empty sync log | env not exported in `/etc/default/wiki-box-sync`, or instance role lacks `wiki-s3-read` | fix export / IAM |
| Page missing from site | 404 | script did not copy that folder, or page not in nav | check the copy rules in `build-wiki.sh` and `nav` in `mkdocs.yml` |
| Broken ADR link | warning | `docs/adr/reference/` is not vendored | link top-level ADRs only, or name the path as text |
| IaC drift | resources unknown to Terraform | bucket, OIDC role and box policy were CLI-created on 2026-09-02 | import into Terraform (open follow-up) |

## Operating it

```bash
scripts/build-wiki.sh                       # local build, venv bootstrapped if needed
python3 -m http.server -d dist/wiki 8000    # preview at http://localhost:8000
gh workflow run build-wiki.yml --ref staging   # rebuild + publish without a docs change
# on the serving box (via SSM), force a pull now:
sudo sh -c '. /etc/default/wiki-box-sync && /usr/local/bin/wiki-box-sync.sh'
```

## Tests

The `build` job on every docs PR is the test: the build must succeed and should add no new
link warnings.

## Source map

| Path | What's there |
|---|---|
| `docs/WIKI-STYLE.md` | writing rules and page templates |
| `scripts/build-wiki.sh` | assembly + build |
| `wiki/mkdocs.yml`, `wiki/requirements.txt`, `wiki/pages/` | generator config, pinned toolchain, generated pages |
| `.github/workflows/build-wiki.yml` | CI build + S3 sync |
| `scripts/wiki-box-sync.sh` | box-side puller |
| `docs/wiki-deploy.md` | one-time wiring record (bucket, roles, cron) |
