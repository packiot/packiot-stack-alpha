# read-api

The new stack's read plane: tenant-scoped HTTP reads over the analytics DB for front4, the operator
app, csadmin and external integrations (the Hasura replacement for reads).

## What it does

read-api (binary and Go package `refdata-api`, its earlier name; network alias `refdata-api`) serves
four kinds of reads from one Go process. Fixed operator routes (`/v1/*`, and `/v2/*` keyed by
`id_equipment` for ADR-0061) return raw JSON arrays. A composable query API (`GET /v1/catalog`,
`POST /v1/query`) compiles allowlisted metrics × dimensions × grain × window, or a named dataset, into
SQL with cost caps (window ≤ 90 days per grain budget, row limit, statement timeout); dataset results are
cached in Redis (cache-aside, fail-open). Anti-corruption shims (`/ext/*`, `/integration/*`) reproduce
the old back4 contracts for external consumers. Every tenant read binds the tenant id as `$1`, derived
server-side from the credential; a client never names a tenant (ADR-0027), with one flag-gated
exception for operator super-admins.

## Where it fits

```text
front4 / operator / csadmin / customize (browser)      external consumers      sparkplug-decoder
   │ https://refdata.staging.packiot.app (nginx, CORS)   │ X-Api-Key            │ X-Internal-Key
   ▼                                                     ▼                      ▼
read-api :9104 ──▶ analytics DB packiot_analytics (pgbouncer, role readapi_ro, RLS)
   ├──▶ app-redis (dataset cache)
   └──▶ historian-gateway (hist-gateway:5432, packiot_historian) for /v1/historian/* (optional)
```

## Status and environments

| Environment | Where | Image | Ports | Health |
|---|---|---|---|---|
| dev (ADR-0060) | `dev/services/read-api.yml` · `read-api` + `read-api-cors` (nginx CORS twin) | built from `services/read-api/Dockerfile` (Go 1.25 → distroless) | `127.0.0.1:9104` via `read-api-cors` | `GET /healthz` |
| staging | `compose.staging.yml` · `read-api` (no profile), IP 172.18.0.26, alias `refdata-api` | same, built on deploy | 9104 in-network; public via nginx vhost `refdata.<staging domain>` (`/metrics` and `/openapi.json` return 404 there) | `GET /healthz` (pings the DB pool); healthcheck `read-api --healthcheck` |
| production | defined in `compose.production.yml` · `read-api` (no profile); new-stack production is not promoted | same | 9104 in-network | same |

## Interfaces

### HTTP

Spec: [`docs/api/openapi/read-api.openapi.json`](../../docs/api/openapi/read-api.openapi.json) (31 paths),
generated from the route tables (`go run ./cmd/refdata-api --dump-openapi`, `make openapi`) and served at
`GET /openapi.json`; portal https://api.staging.packiot.app/docs/ (cs-admin SSO). `openapi_test.go`
fails CI when a mounted route and the spec disagree; `.github/workflows/openapi-export.yml` fails when
the committed file drifts.

| Group | Paths | Auth | What |
|---|---|---|---|
| Operator reads v1 | `/v1/events-timeline`, `/v1/pending-downtime`, `/v1/shift-hours`, `/v1/shift-hours-by-enterprise`, `/v1/day-week-begin`, `/v1/operator-po-list`, `/v1/operator-po-details`, `/v1/operator-entities`, `/v1/entities-per-user-role`, `/v1/downtime-reasons`, `/v1/language-packs` | tenant | fixed reads (some keyed by `topics=`) |
| Operator reads v2 | `/v2/events-timeline`, `/v2/pending-downtime`, `/v2/events-window`, `/v2/operator-po-list`, `/v2/downtime-reasons` | tenant | same reads keyed by `?equipment=<id>,…` (ADR-0061 P3) |
| Query API | `GET /v1/catalog`, `POST /v1/query` | tenant | catalog of metrics/dimensions/grains/datasets; compiled query or named dataset (`datasets.go`) |
| UI state | `GET/PUT /v1/screen-config`, `GET /v1/dashboard-config` | tenant | per-user screen layout (`identity.user_screen_config`, owned by migration `t-readapi-screen-config`; read-api only checks it at boot, no DDL); dashboard config |
| Historian | `POST /v1/historian/production-series`, `/v1/historian/downtime-series` | tenant | daily series past the hot window via the historian gateway; 503 when `HIST_GW_PASSWORD` is unset |
| Internal | `GET /internal/resolve-device` | `X-Internal-Key` | device_key → `id_equipment` for the decoder (ADR-0046); the caller names its enterprise |
| External shims | `/ext/neopac/*`, `/ext/montebello/*`, `/ext/incoplast/*`, `/integration/*/{id_enterprise}` | self-auth via `QUERY_API_KEYS` + per-shim owner binding | back4-compatible contracts (ADR-0031) |
| Ops | `/healthz`, `/metrics`, `/openapi.json` | none | probes and spec |

**Tenant auth** (`auth.go`, whole-mux middleware): a present `X-Api-Key` wins and maps to a customer id
via `QUERY_API_KEYS` (a bad key 401s, no fallthrough); otherwise `Authorization: Bearer <Cognito ID
token>` is verified against the pool's JWKS and mapped to `id_enterprise` through `identity.users`
(linked by `id_user_cognito`; a first request links by e-mail; 5-min cache). Firebase tokens are no longer
accepted (#159). Fail-closed: no or invalid credential → 401, no DB access.
**Super-admin escalation** (`OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED`): an allowlisted, live super user
carrying `x-operator-superadmin-token` may read another active tenant with `?idEnterprise=`.
**Operator line grants** (`operator_grants.go`, PRODT-172): when the operator nginx sends `X-Operator-Channel`
with its fixed key, the user's token in `X-Operator-Authorization: Bearer …` must verify (else 401) and belong to
the key's tenant (else 403). The operator reads are then limited to the role's `permissions.operator.lines` plus
their descendants (super_user or no such array = every line; no role = nothing): `?equipment=` routes 403
`LINE_NOT_PERMITTED` for a line outside the grant, the topic-keyed `?topic(s)=` routes 403 for any restricted
user (identity is the id — use /v2), both before querying; `/v1/operator-po-list|details` drop other lines' rows.
Without the header nothing changes; a super-admin escalation is unrestricted.

### Messaging

N/A: no AMQP or MQTT.

### Database

| DB | Access | Objects |
|---|---|---|
| analytics DB `packiot_analytics` (`REFDATA_FLOW=f3`; staging role `readapi_ro`, RLS without bypass) | read; writes only `identity.user_screen_config` | operator views/functions, caggs (`agg_equipment_values_*`), gold/silver datasets, `identity.users`, `core.device_bindings`, `ops.retention_policy` (coverage floors) |
| historian `packiot_historian` (user `historian_svc`) | read | `silver.equipment_values`, `silver.equipment_events` unions (hot + S3 parquet) |

With `REFDATA_FLOW` unset or anything but `f3`, it reads the retired `packiot` DB (`DB_NAME`) instead.
`pgxpool` uses the simple protocol (pgbouncer transaction pooling), max 5 connections.

## Configuration

| Name | Default | Required | Effect |
|---|---|---|---|
| `REFDATA_FLOW` | `f1` | set `f3` | `f3` → `DB_NAME_F3`; anything else → `DB_NAME` |
| `DB_HOST`, `DB_PORT` | `pgbouncer`, `5432` | no | DB address |
| `DB_USER` | `postgres` | no | staging: `readapi_ro` |
| `DB_PASSWORD` | empty | yes in practice | staging: `.env` `READAPI_RO_PASSWORD` |
| `DB_NAME` | `packiot` | no | legacy-flow database |
| `DB_NAME_F3` | `packiot_analytics` | no | analytics database |
| `HEALTH_PORT` | `9104` | no | HTTP listener (all routes) |
| `QUERY_API_KEYS` | empty | no | `key:customer_id,…` service/operator keys (secret: staging reads it from Secrets Manager `packiot/staging/app.query_api_keys`, see `docs/runbooks/rotate-readapi-keys.md`) |
| `COGNITO_ISSUER` | staging pool issuer | no | Bearer token issuer |
| `COGNITO_CLIENT_ID` | staging app client | no | expected `aud`/`client_id` |
| `COGNITO_JWKS_URL` | `<issuer>/.well-known/jwks.json` | no | JWKS override |
| `COGNITO_AUTH_ENABLED` | on | no | read by `cognitoAuthEnabled()`, which nothing calls: no effect today |
| `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | `false` | no | super-admin cross-tenant reads (staging: `true`) |
| `OPERATOR_SUPERADMIN_ALLOWLIST` | built-in single address | no | comma-separated e-mails allowed to escalate |
| `INTERNAL_API_KEY` | empty | no | enables `/internal/*` (`X-Internal-Key`); empty = disabled |
| `REDIS_URL` | `redis://app-redis:6379/0` | no | dataset cache |
| `REDIS_CACHE_ENABLED` | `true` | no | cache-aside on/off (fail-open either way) |
| `HIST_GW_HOST`, `HIST_GW_PORT`, `HIST_GW_USER`, `HIST_GW_DB` | `hist-gateway`, `5432`, `historian_svc`, `packiot_historian` | no | historian gateway |
| `HIST_GW_PASSWORD` | empty | no | unset = `/v1/historian/*` answers 503 (staging: `.env` `HIST_GW_SVC_PASSWORD`) |
| `EXTERNAL_NEOPAC_CUSTOMER_ID`, `EXTERNAL_MONTEBELLO_CUSTOMER_ID`, `EXTERNAL_INCOPLAST_CUSTOMER_ID` | `0` (shim unbound) | per shim | owner binding of each external shim |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | no | traces (staging: Alloy) |
| `OTEL_TRACES_SAMPLER_ARG` | `1.0` | no | sampling ratio |
| `UPDATE_GOLDEN` | unset | tests only | `1` rewrites golden files |

`compose.production.yml` also passes `FIREBASE_PROJECT_ID`, `COGNITO_USER_POOL_ID`,
`COGNITO_CS_ADMIN_GROUP`, `EDGE_API_*` and `ONBOARD_*`; read-api does not read them.

## Run locally

```sh
make dev SVC="read-api-cors"             # read-api + CORS proxy on http://127.0.0.1:9104 (dev Cognito pool)
make dev SVC="front4"                    # + front4 on :5173 (needs FRONT4_DIR)
make dev-smoke SVC="read-api"            # /v1/operator-entities with the dev read key
cd services/read-api && go test ./...
go run ./cmd/refdata-api --dump-openapi  # print the spec
go run ./cmd/refdata-api --dump-contract # print the DB contract
```

The dev read key `dev-read-key-3` maps to tenant 3. Tests include the OpenAPI drift test, the contract
golden (`cmd/refdata-api/testdata/contract.golden.json`; refresh with
`UPDATE_GOLDEN=1 go test ./cmd/refdata-api/ -run TestContractGolden`) and external-shim goldens
(`testdata/external/`). CI: `go-services.yml`, `openapi-export.yml`, `refdata-contract-drift.yml`
(structural check per PR; a `workflow_dispatch` job diffs the contract against a live DB through SSM).

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`).
- **Metrics** (job `read-api`): `http_request_duration_seconds` (RED, with trace exemplars),
  `refdata_cache_requests_total`, `refdata_internal_resolve_device_total`, Go runtime. `/healthz` also
  reports `served`/`failed` counts. Dashboard: `grafana/dashboards/audience/02-platform-sre.json`.
- **Failure modes:** every request 401 → wrong Cognito issuer/client for the caller's pool (a dev token is
  useless against staging); browser preflight fails → CORS headers live in nginx, not here; empty results
  for a new user → no `identity.users` row for that Cognito user; `/v1/historian/*` 503 →
  `HIST_GW_PASSWORD` unset or the gateway is down; slow dataset reads → check the cache counter and the
  query window/grain.
- **Contract drift check against a live DB:** `scripts/refdata-contract-drift-check.sh` (read-only).

## Code layout

| Path | What |
|---|---|
| `cmd/refdata-api/main.go` | boot, pool, fixed endpoint table, flags `--healthcheck`, `--dump-openapi`, `--dump-contract` |
| `cmd/refdata-api/routes.go` | the one place routes are mounted |
| `cmd/refdata-api/auth.go`, `auth_cognito.go`, `auth_firebase.go`, `auth_operator_superadmin.go`, `operator_grants.go` | tenant middleware, route classes, Bearer verification, super-admin escalation, operator line grants |
| `cmd/refdata-api/query.go`, `datasets.go`, `coverage.go` | composable query API, named datasets, coverage floors |
| `cmd/refdata-api/historian.go`, `historian_split.go` | historian gateway reads |
| `cmd/refdata-api/internal.go` | `/internal/resolve-device` |
| `cmd/refdata-api/external*.go` | ADR-0031 shims |
| `cmd/refdata-api/openapi.go`, `contract.go`, `flow.go` | spec builder, DB contract, flow selection |
| `internal/cache/`, `internal/httpmetrics/`, `internal/tracing/` | Redis cache, RED metrics, OpenTelemetry |
| `scripts/` | contract drift check, F3 parity check |

## Related docs

- [ADR-0015 customer-facing query API](../../docs/adr/0015-customer-facing-query-api.md)
- [ADR-0027 refdata-api surface 1](../../docs/adr/0027-refdata-api-surface-1-read-contract.md)
- [ADR-0031 back4 retirement shims](../../docs/adr/0031-back4-api-retirement-shims-datasets-and-hasura-sequence.md)
- [ADR-0034 Cognito auth](../../docs/adr/0034-adopt-cognito-amplify-auth.md)
- [ADR-0035 Redis cache layer](../../docs/adr/0035-redis-cache-layer.md)
- [ADR-0046 edge source plugin contract](../../docs/adr/0046-edge-source-plugin-contract.md)
- [ADR-0057 historian storage](../../docs/adr/0057-historian-storage-architecture-and-medallion-naming.md)
- [ADR-0061 remove PackML from the cloud](../../docs/adr/0061-remove-packml-from-the-cloud.md)

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [read-api](https://wiki.packiot.app/understand/components/read-api/) |
| API reference (generated from the spec) | [read-api](https://wiki.packiot.app/reference/api/read-api/) |
| Interactive API docs (staging, SSO) | [API portal](https://api.staging.packiot.app/docs/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
