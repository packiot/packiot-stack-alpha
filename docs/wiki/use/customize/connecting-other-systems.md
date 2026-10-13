---
title: Connecting to an ERP or other systems
layer: guide
owner_area: frontends
last_verified: 2026-09-29
---
# Connecting to an ERP or other systems

> For the **automation team**. Recipes to send a client's production data to another
> system with a [Node-RED flow](node-red-flows.md). Up: [Customizing a client](index.md)

Every recipe starts the same way: **Receive: Normalized tags** gives your flow every batch
of values (`msg.payload.tags` is a list of `{ metric, value, ts }`). Keep only the values you
need with a **function** or **switch** node, then send them.

!!! warning "Before you start"
    - The node you use must be **installed on the factory box**. If it isn't, Preview shows it
      and Apply refuses (a missing node would stop all flows). Ask the platform team to add it.
    - Put **addresses and passwords in the node's settings**, never inside a function.
    - Node-RED flows need a box that reads PLCs with Node-RED (see
      [Node-RED flows](node-red-flows.md)); a helper for Python-reader boxes is **coming soon**.

## Recipes

| Target | Nodes | Tip |
|---|---|---|
| **SQL database / ERP tables** (SQL Server, PostgreSQL, MySQL) | function (build the row) → the database node | Use an "insert … on conflict / merge" so a resend doesn't create duplicates |
| **REST API** (ERP, MES, SAP via its REST gateway) | function (build the JSON) → **http request** | Add a **delay** (rate limit) if the API has limits |
| **CSV file** on the box | function (one line of text) → **file** (append) | One file per day, e.g. `production-2026-09-29.csv` |
| **E-mail / Teams / Slack alert** | switch (only when needed) → **delay** (1 per N minutes) → **http request** to the webhook, or an e-mail node | Always rate-limit alerts |
| **MQTT** (the client's own broker) | function → **mqtt out** | Use one topic per line, e.g. `factory/line01/good-parts` |

## Example: good parts per line into a SQL table, once a minute

1. **Receive: Normalized tags** → **function** "keep good parts" (keeps tags whose metric
   contains `/Admin/ProdProcessedCount/`).
2. → **function** "last value per line" (remembers the newest value per line in node context).
3. → **inject** every 60 s triggers → **function** "build rows" → the **database** node with
   an insert into `production_counts(line, good_parts, ts)`.

## Where this is going

Packiot talks to other systems through a simple contract: it **sends** the tag batch over
HTTP, and **receives** new tags on its normal ingest. Any tool that speaks HTTP can sit on
either side — Node-RED today, possibly a tool like HighByte later — without changing the
factory box or the cloud.
