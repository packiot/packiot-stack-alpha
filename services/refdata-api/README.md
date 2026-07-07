# refdata-api

**The Hasura replacement for reads** (ADR-0015; task #86 Option C).
A single small Go binary serving two surfaces:

1. **The legacy contract** — the 12 reference-read routes enumerated
   from Hasura's own query log (`docs/audits/hasura-review-2026.md`
   found only ~4% of Hasura was actually used; these routes are that
   4%). Flow 1 keeps minimal Hasura; the refactored flows consume this
   instead. Raw JSON arrays, no GraphQL engine.
2. **The composable query API** — `GET /v1/catalog` + `POST /v1/query`:
   metrics × dimensions × grain × window compiled to CAgg SQL.
   Safe-by-construction: only allowlisted metrics/dimensions/grains
   compile; grains map to `agg_equipment_values_{1min,10min,1hour}`
   with hard window caps (7d/30d/90d). Plus `GET/PUT /v1/screen-config`
   for operator layout persistence.

## Routes

`/v1/events-timeline` · `/v1/pending-downtime?topics=` ·
`/v1/shift-hours?topic=` · `/v1/day-week-begin?topic=` ·
`/v1/shift-hours-by-enterprise?topic=&enterprise=` ·
`/v1/operator-po-list` · `/v1/operator-po-details` ·
`/v1/operator-entities` · `/v1/entities-per-user-role` ·
`/v1/language-packs` · `/v1/downtime-reasons?topics=` ·
`/v1/catalog` · `/v1/query` · `/v1/screen-config` · `/healthz`

## Tenancy invariant

`X-Api-Key` → `customer_id` server-side (`QUERY_API_KEYS="key:cid,…"`).
**customer_id is never client-supplied** — the query compiler injects
`id_enterprise = $1` itself. Keep it that way.

## Config

`DB_HOST` (default `pgbouncer`) · `DB_PORT` · `DB_USER` ·
`DB_PASSWORD` · `DB_NAME` (`packiot`) · `HEALTH_PORT` (9104) ·
`QUERY_API_KEYS`. pgxpool with `QueryExecModeSimpleProtocol`
(pgbouncer transaction pooling — do not remove). Deployed in
`compose.staging.yml` only. Code: `cmd/refdata-api/{main.go,query.go}`
— deliberately no `internal/`; it's ~400 lines and should stay small.
