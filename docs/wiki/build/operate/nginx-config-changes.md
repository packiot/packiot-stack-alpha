---
title: Change nginx config
layer: 4
owner_area: platform
last_verified: 2026-10-13
---
# Change nginx config

> **Build & operate.** Up: [Build & operate](../index.md)

!!! info "This page is being written"
    Part of the 2026-10 docs redesign. Until it lands, see the related pages linked from
    [Build & operate](../index.md).

<!-- BRIEF for the writer (delete when the page is written):
- nginx_setup.sh is a Terraform templatefile uploaded to S3 and re-run on the host; the deploy does NOT apply it.
- Procedure: snapshot live /etc/nginx (read-only, SSM) → render the template offline → diff functionally → codify good drift → targeted terraform apply → re-run → verify every touched vhost.
- Pitfalls: templatefile ${}/%{} escaping, backups outside conf.d, nested location inheritance of auth_request.
-->
