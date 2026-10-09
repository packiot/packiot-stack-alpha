# packiot_analytics — schema map

The new-stack analytics DB (`packiot_analytics`) is organized by a **medallion +
domain** taxonomy. Every schema carries a `COMMENT ON SCHEMA` (see
`db/migrations/t275-schema-docs-complete`; visible in `\dn+`, pgweb, CloudBeaver).

search_path (silver-first, `public` last as fallback):
`"$user", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public`

| Schema | Role |
|--------|------|
| `bronze` | Immutable append-only raw landing (`*_raw`, `box_scans`). Flag-gated (ADR-0036). Never mutate. |
| `silver` | Merged/deduped facts (latest-wins UPSERT) + minute/hour rollup caggs + live-state grains + `data_quality_event`. |
| `gold` | Computed OEE grains (`equipment_oee_{shift,hourly,daily,weekly,monthly}`, area) + per-PO aggregates. |
| `core` | Conformed dimensions: enterprise→site→area→equipment, production_orders, shifts, topic_routing, products/clients, scrap_targets, client_descriptors. |
| `identity` | AuthZ + profile keyed to Cognito (users, user_roles, user_logs). NOT authN. Renamed from `auth` (t247). |
| `config` | i18n + labels (translations, language_packs, pages, dashboard_config, labels). |
| `ops` | Operational plumbing (idempotency_keys, function_execution_log, capture_observations, mirror dlq). |
| `serving` | `security_invoker` views/fns read by read-api under the caller's RLS. |
| `bi` | `security_definer` + RLS views for Superset (tenant fence via `app.tenant_id`). |
| `customer_reports` | External ERP/report contract surface (see below). |
| `public` | PostgreSQL default schema — not an app domain (see below). |

## Why `public` still exists (it is NOT redesign debt)

`public` cannot be dropped and was never meant to be emptied. It holds only:
1. **Extensions** — timescaledb, dblink, btree_gist, pg_stat_statements (own ~250 fns).
2. **knex migration bookkeeping** (`knex_migrations*`) — the active migration runner defaults here.
3. **A few not-yet-relocated LIVE objects** — `scanned_boxes`/`sample_boxes` (edge-api Samples
   feature), `h_*` `RETURNS SETOF` row-type carriers (dropping one breaks a function signature),
   and `piot_get_*` / `h_piot_get_downtimes_*` fns still called *bare* by read-api.

It is last in search_path, so bare names resolve to the medallion schemas first — only
`public.X`-qualified refs hit it. Dead sediment is trimmed by necessity sweeps
(t235 Hasura fossils; t274 dropped 5 orphan sequences whose backing tables were gone).
A future *optional* tidy could relocate the `piot_get_*` fns + `h_*` carriers to `serving`/`core`
and repoint read-api's bare calls (gated on the read-api contract-golden test) — a cutover, not a delete.

## Why `customer_reports` still exists (external contract, correctly permanent)

Its tables are **write targets for external customer integrations**, not internal reports:
- `sap_data_sync` → **Neopac SAP** (enterprise-13, German field shape)
- `production_data_sync` + `shift` → **Montebello/Incoplast** OEE pull (enterprise-06), via `serving.production_data_sync()`
- `boxes` → source for the SAP transform

Column shapes are dictated by the customers' ERP/SAP systems and cannot be redesigned
unilaterally. #244 replaced the per-tenant *named* legacy objects with these generic
**pooled tables keyed by `customer_id`** + config-driven `serving.*` fns; the pools were kept
on purpose. Remaining work is the **gated prod cutover** to drop the legacy per-tenant *source*
objects (blocked on SETOF drift-gate ordering + external-contract validation + prod row-parity) —
orthogonal to the schema's existence.
