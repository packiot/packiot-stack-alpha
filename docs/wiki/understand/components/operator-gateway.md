---
title: operator-gateway (operator-adapter)
layer: 3
owner_area: serving
last_verified: 2026-10-13
---
# operator-gateway (operator-adapter)

> **Layer 3 · Components** — a small TLS bridge that turns a client's bespoke operator
> actions (posted by a Node-RED tee) into edge-api calls. Built for Incoplast (enterprise
> 4). For whoever onboards a client whose operators do not use our operator app.
> Up: [Serving & APIs](../subsystems/serving-apis.md) ·
> [README](https://github.com/packiot/packiot-stack-alpha/blob/staging/services/operator-gateway/README.md) ·
> [API reference](../../reference/api/operator-gateway.md) ·
> [Service catalog](../../reference/service-catalog.md)

## Responsibility

Accept operator actions (justify a downtime, start/stop/setup a PO, split an event) from a
client's own operator system, authenticate and tenant-scope them, resolve the client's
`packml_topic` to our equipment ids, and forward each one as exactly one edge-api call with
the tenant's api-key. The effect is that such a client's operator actions land in the
analytics DB and in `user_logs` exactly as if they had used our operator app. It is the
operator-action twin of [ingest-shim](ingest-shim-and-fanout.md) (which does the same for
telemetry). It is an anti-corruption layer: its stable contract is edge-api's semantics, not
the client's parameter encoding.

## At a glance

| | |
|---|---|
| Language / runtime | Go, binary `operator-gateway` built from `services/operator-gateway/cmd/operator-adapter` |
| Container (staging) | `operator-gateway`, alias `operator-adapter`, IP `172.18.0.30` |
| Port | `8443` TLS only (refuses plaintext); host publish `127.0.0.1:8445` (loopback only, no security-group ingress) |
| TLS | cert and key mounted from `/opt/packiot/operator-adapter/certs` on the host |
| DB | small pool (max 3 conns) to `packiot_analytics`, direct to the DB host on staging, used only for topic resolution (SELECT) |
| Downstream | `http://edge-api:8080`, 10 s client timeout |
| Tenant | one enterprise per instance: `INCOPLAST_ENTERPRISE_ID=4`, `INCOPLAST_TOPIC_PREFIX=INCOPLAST` |
| Depends on | edge-api, pgbouncer/DB, Secrets Manager (unless `CREDS_SOURCE=env`) |
| Depended on by | the client's Node-RED tee node |
| Production (new stack) | defined in `compose.production.yml` behind profile `client-ingest` (starts only when a bespoke-operator client is onboarded); there it publishes `8445` on all interfaces and takes tenant/prefix from `OPERATOR_ADAPTER_ENTERPRISE_ID` / `_TOPIC_PREFIX` |

!!! warning "Unverified: live traffic"
    On staging the gateway runs; Incoplast (enterprise 4) telemetry arrives through
    ingest-shim (see [Environments](../architecture/environments.md)). Whether its Node-RED
    tee still posts operator actions here was not verified (read-only check of
    `operator_adapter_requests_total` on Grafana would answer it).

## Inputs & outputs

| Route | edge-api call | Resulting `user_logs.category` |
|---|---|---|
| `POST /operator/downtime` | `/api/downtimes/create-manual-event` (param 30810/30811) or `/api/downtimes/edit-manual-event` (30812-30814) | `manual-event-created` / `manual-event-edited` |
| `POST /operator/po` | `/api/production-orders/create-and-start` | `order-created-started` |
| `POST /operator/po/stop` | `/api/production-orders/stop` | `order-stopped` |
| `POST /operator/po/setup` | `/api/production-orders/setup` | `order-changed` |
| `POST /operator/po/replace` | `/api/production-orders/replace` | `order-replaced` |
| `POST /operator/po/change-status` | `/api/production-orders/change-status` | `order-status-changed` |
| `POST /operator/po/change-time` | `/api/production-orders/change-time` | `order-time-changed` |
| `POST /operator/split` | `/api/downtimes/split` | `event-splitted` |
| `GET /healthz` | — | `{"healthy":true,"db":true}`; 503 if the DB pool is down |
| `GET /metrics` | — | Prometheus |
| `GET /openapi.json` | — | OpenAPI 3.1 document (embedded `internal/adapter/openapi.json`; also served by the staging API portal) |

Scrap is **not** an operator route: scrap corrections are counter metrics and travel the
telemetry path.

## Internal design

```text
 client Node-RED tee ──HTTPS, X-Ingest-Key──▶ operator-gateway
     1. auth: constant-time compare X-Ingest-Key with OPERATOR_API_KEY        → 401
     2. scope: body.enterprise == INCOPLAST_ENTERPRISE_ID
               OR topic starts with INCOPLAST_TOPIC_PREFIX                     → 403
     3. resolve packml_topic → (id_equipment, cd_equipment, id_area, id_site)
        SELECT … FROM packml_register p JOIN equipments JOIN areas JOIN sites
         WHERE p.packml_topic = $1 AND p.active AND s.id_enterprise = $ent LIMIT 2
        unknown / inactive / cross-tenant / ambiguous (2 rows)                → 422
        DB error                                                              → 503
     4. map fields to the edge-api DTO; missing required field                → 422
     5. POST edge-api with x-api-key = EDGE_API_KEY, ?idEnterprise=<ent>, traceparent
        (no Idempotency-Key), 10 s timeout
 edge-api 2xx → 202 · 4xx → passthrough · 5xx → 502 · unreachable or timeout → 503
```

Resolver cache (`internal/adapter/resolver.go`): hits cached 5 min, misses 30 s, bounded
map. A DB error is never cached as a miss.

| File (`internal/adapter/`) | Role |
|---|---|
| `server.go` | Routes, auth, scope, status translation |
| `mapping.go` | Downtime mapping (create vs edit by `id_param`) |
| `po_lifecycle.go` | The five PO routes |
| `split.go` | Split mapping |
| `resolver.go` | Topic → ids with tenant gate and cache |
| `edgeclient.go` | edge-api HTTP client (api-key, enterprise, trace propagation) |
| `ordernumber.go` | Client PO number kept as text (ADR-0062), forwarded as `idOrder` + `orderNumber` |
| `openapi.go`, `openapi.json` | Embedded spec served at `/openapi.json` |
| `types.go`, `metrics.go` | Payload types, `operator_adapter_requests_total{action,outcome}` |

Request bodies are capped at 1 MiB; unknown JSON fields are allowed on purpose (Node-RED
adds metadata). edge-api writes the analytics DB directly; the gateway never touches it.

## Configuration

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `OPERATOR_API_KEY` | — (required) | `.env` | Inbound `X-Ingest-Key` secret |
| `EDGE_API_KEY` | — (required) | `.env` `OPERATOR_EDGE_API_KEY` | The tenant's `enterprises.api_key` for edge-api |
| `INCOPLAST_ENTERPRISE_ID` | — (required) | `4` | Tenant scope |
| `INCOPLAST_TOPIC_PREFIX` | empty | `INCOPLAST` | Second scope gate |
| `EDGE_API_URL` | `http://edge-api:8080` | same | Downstream |
| `PG_SECRET_ID`, `AWS_REGION` | `packiot/staging/db`, `us-east-1` | same | Resolver creds from Secrets Manager |
| `CREDS_SOURCE` | Secrets Manager | `env` | `env` → `DB_HOST`/`DB_PORT`/`DB_USER`/`DB_PASSWORD`/`DB_NAME` |
| `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` | from secret | DB host direct, 5432, `${POSTGRES_USER}` / `${POSTGRES_PASSWORD}` | Resolver connection |
| `DB_NAME` | from secret | `packiot_analytics` | Resolver DB |
| `PORT` | `8443` | `8443` | TLS port |
| `TLS_CERT_FILE`, `TLS_KEY_FILE` | — (required) | mounted certs | Refuses to start without them |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | `http://tempo:4317` | Tracing (exemplar service for the rollout) |

The env names still say "Incoplast": the code has no hardcoded tenant, so another client
means another instance with different values.

## Data & invariants

- Never writes the DB itself; every effect goes through edge-api, so edge-api's tenant
  fence, validation and audit log apply.
- Rejects rather than guesses: a wrong downtime or PO write is worse than a 422.
- A resolved id always belongs to the configured enterprise (join gated on
  `sites.id_enterprise`).

## Observability

- `operator_adapter_requests_total{action,outcome}` plus Go runtime; Prometheus job
  `operator-gateway` scrapes `https://operator-gateway:8443/metrics` with verification off
  (self-signed internal cert).
- Traces span receive → resolve (DB) → edge-api and continue into edge-api.
- `/healthz` includes the DB pool check.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| 401 | Tee sends wrong/missing `X-Ingest-Key` | Rotate/sync `OPERATOR_API_KEY` |
| 403 | Body enterprise or topic prefix not the configured tenant | Fix the tee node payload |
| 422 "topic … did not resolve" | Topic missing/inactive in `packml_register`, or duplicated | Fix registration in csadmin; wait up to 30 s for the negative cache |
| 502 | edge-api 5xx | edge-api logs |
| 503 `edge-api unreachable` | edge-api down, or slower than the 10 s client timeout | edge-api health; see the duplicate-write risk below |
| 4xx passthrough (e.g. 404) | edge-api TenantFence or validation | The edge-api key does not own the target, or DTO mismatch |
| Container exits at boot | Missing TLS files or required env | Place certs, fill `.env` |

!!! warning "Known failure mode: a retry after a timeout can duplicate a write"
    The gateway answers 503 when the edge-api call errors, **including a client timeout**
    (10 s). If edge-api had already committed the action (slow response, not a failure),
    a tee that retries on 503 sends it again, and the gateway forwards it without an
    `Idempotency-Key`, so edge-api cannot recognise the replay. Manual events, PO
    create-and-start and splits are not naturally idempotent; a duplicate needs manual
    cleanup. Mitigation today: tell the client to retry 503s only after checking the
    effect (for example the PO list), or not at all for creates. A fix would forward a
    deterministic `Idempotency-Key` (edge-api already honours it for 24 h).

## Operating it

Deploys with the stack. To onboard another bespoke-operator client: add a second service
instance with its own enterprise id, topic prefix, inbound key and edge-api key; in
production enable the `client-ingest` profile. The gateway is internal-only on staging; a
client reaches it through whatever TLS front door is provisioned for that client.

## Tests

`cd services/operator-gateway && go test ./...` (`server_test.go`, `po_lifecycle_test.go`,
`split_test.go`, `resolver_test.go`, `ordernumber_test.go`, `openapi_test.go` +
`openapi_completeness_test.go`); CI `go-services.yml`, spec drift `openapi-export.yml`.

## Source map

| Path | What's there |
|---|---|
| `services/operator-gateway/cmd/operator-adapter/main.go` | Config, pool, resolver TTLs, TLS server, healthcheck |
| `services/operator-gateway/internal/adapter/` | Routes, mapping, resolver, edge-api client, metrics |
| `services/operator-gateway/internal/secrets/secrets.go` | Secrets Manager creds |
| `services/operator-gateway/README.md` | How to run it; full field-mapping tables |
| `services/operator-gateway/internal/adapter/openapi.json` | Embedded spec (vendored by `make openapi`) |
| `compose.staging.yml`, `compose.production.yml` (`operator-gateway`) | Deployment |
| `monitoring/prometheus/prometheus.yml` (`operator-gateway`) | Scrape job |
