# Wiki static-site: build + delivery

The `wiki.packiot.app` site is the two Packiot doc sets — the commissioned
**Stack Wiki** (`docs/wiki/`) and the polished **Guide** (`docs/guide/`) — merged
into one browsable, searchable static site by **mkdocs-material**.

- Generator config: [`wiki/mkdocs.yml`](../wiki/mkdocs.yml)
- Pinned toolchain: [`wiki/requirements.txt`](../wiki/requirements.txt) (`mkdocs-material==9.5.44`)
- Build script: [`scripts/build-wiki.sh`](../scripts/build-wiki.sh) → emits `dist/wiki/`
- CI: [`.github/workflows/build-wiki.yml`](../.github/workflows/build-wiki.yml)

## Why mkdocs-material

It emits **fully static, self-contained HTML** with a **client-side search index
built at build time** (no server, no runtime backend). With `theme.font: false`
it bundles all CSS/JS/icons locally and fetches **no external CDN assets at serve
time** — required to serve behind the oauth2 gate with a strict origin. One YAML
file drives nav + search + theme, which keeps CI trivial.

## Build locally

```bash
scripts/build-wiki.sh          # bootstraps a venv if mkdocs isn't on PATH
# output: dist/wiki/index.html  (open in a browser, or `python3 -m http.server -d dist/wiki`)
```

The script is idempotent. It assembles a staging tree under `wiki/build/staging/`
from three sources, then runs the generator:

| Source | From | Lands under |
|---|---|---|
| Guide | working tree `docs/guide/` | `guide/` (nav: **Guide**) |
| Stack Wiki | `docs/wiki/` if present, else `origin/staging` (`$WIKI_REF`) | `wiki/` (nav: **Stack Wiki**) |
| Onboarding page | `wiki/pages/first-time-box-setup.md` | `onboarding/` (nav: **Onboarding**) |
| ADRs | top-level `docs/adr/*.md` | `adr/` (not in nav; resolves the Guide's `../adr` cross-refs) |

## Delivery to the box — chosen model: **CI → S3 → box pulls**

`aws_instance.app` has `ignore_changes=[user_data]`, so the box (**`i-02d255a1c21fb1da3`**)
never rebuilds from user_data. We therefore deliver the built site out-of-band:

```
build-wiki.yml (on push to staging/production)
  └─ builds dist/wiki/  ──►  aws s3 sync ──►  s3://<WIKI_S3_BUCKET>/wiki/
                                                   ▲
                                                   │  aws s3 sync --delete (timer, ~5 min)
                          box i-02d255a1c21fb1da3 ──┘  scripts/wiki-box-sync.sh → /var/www/wiki
```

**Why pull, not SSM push:** the box self-heals on a timer, delivery is decoupled
from any per-deploy orchestration, and CI needs only `s3:PutObject` on one prefix
(no `ssm:SendCommand`, no instance targeting). It's the simpler thing to operate.

### One-time operator wiring (NOT done here — no AWS resources were created)

1. **Create the bucket/prefix** (private; the vhost is served from `/var/www/wiki`,
   not S3 — S3 is only the transport):
   ```bash
   aws s3 mb s3://packiot-wiki-dist --region us-east-1   # pick a real name
   ```
2. **CI → S3 (push side):** set an OIDC role CI can assume with `s3:PutObject`,
   `s3:DeleteObject`, `s3:ListBucket` on `arn:aws:s3:::<bucket>/wiki/*`, then set
   in the repo:
   - Actions **variable** `WIKI_S3_BUCKET` = the bucket name
   - Actions **secret** `AWS_ROLE_ARN` = the OIDC role ARN

   Until both are set, the `deploy` job **skips cleanly** (guarded) — build + artifact still run.
3. **Box → S3 (pull side):** grant the box `i-02d255a1c21fb1da3` instance-profile
   read (`s3:ListBucket` + `s3:GetObject` on the same prefix), install the puller,
   and add a timer:
   ```bash
   sudo install -m0755 scripts/wiki-box-sync.sh /usr/local/bin/wiki-box-sync.sh
   sudo tee /etc/default/wiki-box-sync >/dev/null <<'EOF'
   WIKI_S3_BUCKET=packiot-wiki-dist
   WIKI_WWW_ROOT=/var/www/wiki
   EOF
   # cron (every 5 min):
   echo '*/5 * * * * root . /etc/default/wiki-box-sync && /usr/local/bin/wiki-box-sync.sh >>/var/log/wiki-sync.log 2>&1' \
     | sudo tee /etc/cron.d/wiki-box-sync
   ```
   (Or a systemd `wiki-box-sync.timer` — equivalent.)

### The single manual value the operator must choose

**The S3 bucket name.** Set it in all three places above: the `WIKI_S3_BUCKET`
Actions variable, the two IAM policies (CI put / box get), and `/etc/default/wiki-box-sync`
on box `i-02d255a1c21fb1da3`. Everything else is scaffolded.

## Notes

- The build is intentionally **non-strict**. Residual `mkdocs` warnings are (a)
  pre-existing broken/relative links inside the source ADR files (they point at
  terraform / edge-node-red / renamed ADRs), and (b) a few Guide links to files
  outside the two doc sets (`../README.md`, `../BUSINESS-RULES.md`,
  `../clients/_schema.yaml`, `../audits/`, `../adr/reference/`). None break the
  two-set navigation or the build.
- The nginx vhost, DNS, and cert for `wiki.packiot.app` (`root /var/www/wiki`) are
  owned by a separate terraform/nginx change — out of scope for this pipeline.
