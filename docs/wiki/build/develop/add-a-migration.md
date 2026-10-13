---
title: Add a migration
layer: 4
owner_area: analytics-db
last_verified: 2026-10-13
---
# Add a migration

> **Build & operate.** Up: [Build & operate](../index.md)

!!! info "This page is being written"
    Part of the 2026-10 docs redesign. Until it lands, see the related pages linked from
    [Build & operate](../index.md).

<!-- BRIEF for the writer (delete when the page is written):
- db/migrations layout and naming; there is NO automatic migration runner on staging — how migrations are applied and verified.
- TimescaleDB rules: compressed chunks (literal bounds, read-back), never decompress_chunk on the shared DB, caggs refresh order.
- Dev seed manifest: new ops.* tables must be classified (dev/seed manifest + tsv) or the seed build fails.
-->
