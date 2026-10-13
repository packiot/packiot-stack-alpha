---
title: Change nginx config
layer: guide
owner_area: platform
last_verified: 2026-10-13
---
# Change nginx config

> **Build & operate · how-to.** Change a public host on the staging app box (a new route,
> an SSO gate, a CORS origin) without reverting someone else's live fix. Up:
> [Build & operate](../index.md)

**Goal:** a reviewed change to `terraform/staging/user_data/nginx_setup.sh`, live on the
host, with every other vhost exactly as it was.

## How nginx config reaches the host

```text
 nginx_setup.sh (repo) ──terraform apply──► S3 object scripts/nginx_setup.sh
   a Terraform templatefile                  (aws_s3_object.nginx_setup)
                                                      │  re-run by hand on the host
                                                      ▼
                                       /etc/nginx/conf.d/*.conf  → nginx -t → reload
```

The **deploy workflow never touches nginx.** The script is idempotent, but "idempotent"
means a re-run converges on *the script*, not on what is live: a hand-fix on the host
that never made it into the script is silently reverted. That is why step 1 exists.

## Before you start

- AWS access to the staging account, and SSM access to the app host.
- Terraform for `terraform/staging` (init with the Makefile backend config, `make tf-init`).

## Steps

1. **Snapshot the live config (read-only).** Over SSM, archive `/etc/nginx`
   (`conf.d`, `snippets`, `stream.d`, `nginx.conf`) and copy it to your machine. Include
   `stream.d`: missing it once made a file look "missing on live" when it wasn't.
2. **Render the script offline**, exactly as Terraform will: run `templatefile()` on it with
   the staging variables (e.g. in the `hashicorp/terraform` image), then expand each
   `cat > … <<NGINX` heredoc with `bash` and `STAGING_DOMAIN` set.
3. **Diff functionally:** strip comments and whitespace before comparing, and mask
   anything secret-looking before printing. Classify every difference:

    | Kind | Example | Action |
    |---|---|---|
    | Good live hand-fix | refdata's CORS allow-list (2026-10-13) | **Codify it into the script first**, in its own PR |
    | Dead live leftover | cpack-ingest mirror to a retired container | Let the re-run drop it; say so in the PR |
    | Filled at run time | RabbitMQ Basic header from `/opt/packiot/.env` | Not drift |
    | Probe artifact | a dir you didn't snapshot | Fix the probe |

4. **Make your change** in `nginx_setup.sh`. It is a Terraform templatefile: never write
   `${` or `%{` in literal text (escape as `$${`), and escape nginx variables as `\$var`
   inside unquoted heredocs.
5. **Test it locally:** render again, extract the vhosts you touched plus the snippets,
   and run `nginx -t` in an `nginx` container. For gates, run a behaviour test with a stub
   auth server on `:4180` (401 without a cookie, 202 with one) and `curl --resolve`.
   Nested `location` blocks inherit `auth_request`; prove it with the test.
6. **PR → merge**, then a **targeted** apply so nothing else drifts in:
   ```sh
   terraform -chdir=terraform/staging plan -target=aws_s3_object.nginx_setup -out=nginx.tfplan
   terraform -chdir=terraform/staging show nginx.tfplan   # only your lines?
   terraform -chdir=terraform/staging apply nginx.tfplan
   ```
7. **Snapshot again** and confirm nothing changed since step 1, then **re-run on the host**
   (SSM): back up `/etc/nginx` to `/root/nginx-etc-before-rerun-<ts>.tgz` (never inside
   `conf.d`, where `*.conf` would be loaded), download the script from S3, run it, and
   confirm `nginx -t` passes and nginx is active.

## Check it worked

From outside: your new behaviour (status codes, redirects to SSO), **and** every vhost the
script writes still answers as before: api, csadmin, operator, scan, refdata CORS for each
allowed origin, and live ingest traffic in `/var/log/nginx/access.log` (e.g. the CPACK
`/v2/tags` rate) across the reload.

## If it went wrong

The script reloads only after `nginx -t` passes. To roll back, restore the backup tarball
over `/etc/nginx`, `nginx -t`, reload, and revert the PR (then re-apply the S3 object).

## Related

- [Wiki pipeline](../../understand/components/wiki-pipeline.md) and the API docs portal
  are both served by these vhosts.
- [oauth2-proxy & Cognito](../../understand/components/oauth2-proxy-and-cognito.md): the SSO gate.
