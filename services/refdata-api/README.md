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

## Named datasets (`POST /v1/query {"dataset": …}`)

The composable API also serves an allowlisted **named-dataset registry**
(`datasets.go`) that replaces front4's direct Hasura reads — each dataset is a
`$1`-first, tenant-scoped, projection-shaped read (see `GET /v1/catalog`). The
front4→refdata migration (#58 Phases 2-3) adds these: `home-uns`,
`events-timeline-from-po`, `events-timeline-full`, `production-orders-runtimes`,
`production-orders-with-runtimes`, `entities-per-user-role`, `menu-per-user-role`,
`equipment-downtime-reasons`, `site-by-equipment`, `custom-target-{month,week,day}`.
Several front4 reads fold into existing datasets rather than adding new ones:
GET_TARGET → `production-targets`/`scrap-targets`; ScrapPeriod → `single-period`;
OEE_OBJ_MONTH → `live-equipment-month` + `oee-targets`; GET_SHIFT_PROD →
`live-equipment-shift`; LIST_USERS → `users`; USER_LANGUAGE → `/v1/language-packs`.

**VariablesContext (`GET_VARIABLES_CONTEXT`) caveat.** The `enterprise-config`
dataset already returns `enterprises` **minus `api_key`** — migrating front4's
bootstrap to it is what removes the secret from browser localStorage. The
per-role bootstrap views (`entities-per-user-role`, `menu-per-user-role`) are
scoped by `id_enterprise = $1` only and return **all** of the tenant's role rows;
the correct per-USER narrowing needs `(id_enterprise, id_user_role)` where
`id_user_role` is resolved from the caller's Firebase uid. The #68 Bearer path
resolves `uid → customer_id` and **discards the uid**, so no handler can yet scope
by user identity — the server-side per-user tightening is a flagged follow-up
(plumb the verified uid into request context). Until then front4 selects its own
role client-side from the uid it already holds. `v_entities_per_user_role`'s
`enterprise` jsonb column (which embeds `api_key`) is deliberately projected out.

## Tenancy invariant

**customer_id is never client-supplied** — it is derived server-side from
the credential and injected as `id_enterprise = $1`. Two credential types
resolve to the SAME tenant (`auth.go` whole-mux middleware, ADR-0027
Surface-1). Precedence: **a present `X-Api-Key` wins** (a bad one 401s, no
fallthrough); otherwise the Bearer token is tried.

- `X-Api-Key` → `customer_id` via `QUERY_API_KEYS="key:cid,…"` (operator /
  service credential).
- `Authorization: Bearer <firebase-jwt>` → `uid` → `id_enterprise` via
  `users` (task #68, the static front4 SPA path — it holds no key and never
  names a tenant). The ID token is verified with public keys only (no
  secret): RS256 signature against Google's rotating x509 certs, plus
  `iss=securetoken.google.com/<project>`, `aud=<project>`, `exp`/`iat`. The
  uid→enterprise lookup is hardened (`active = true AND id_enterprise IS NOT
  NULL`) and cached (5-min TTL). Fail-closed: bad/expired/wrong-project
  token, or a uid with no active enterprise → 401, never a default tenant.

`/healthz` + `/metrics` are the only auth-exempt routes.

## Config

`DB_HOST` (default `pgbouncer`) · `DB_PORT` · `DB_USER` ·
`DB_PASSWORD` · `DB_NAME` (`packiot`) · `HEALTH_PORT` (9104) ·
`QUERY_API_KEYS` · `FIREBASE_PROJECT_ID` (default `fbpackiot`; the
JWKS/x509 URL is a public constant, not config). pgxpool with
`QueryExecModeSimpleProtocol` (pgbouncer transaction pooling — do not
remove). Deployed in `compose.staging.yml` only. Code:
`cmd/refdata-api/{main.go,query.go,auth.go,auth_firebase.go}` —
deliberately no `internal/`; keep it small.
