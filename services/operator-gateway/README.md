# operator-gateway

HTTPS bridge that turns a client's own operator-app actions (sent by a Node-RED tee node) into
edge-api calls, so they land in the new stack like actions from our own operator app.

## What it does

Some clients run their own operator UI (Incoplast: Node-RED + Hasura) that writes to their DB and
SparkPlug directly and never calls edge-api. A tee node in that flow POSTs each action here:
downtime justify/edit, PO start/stop/setup/replace/status/time, and event split. For every action the
gateway checks the shared key, checks the tenant scope, resolves the SparkPlug `packml_topic` to the
tenant's equipment (`packml_register` → `equipments` → `areas` → `sites`), maps the body to the edge-api
DTO and calls edge-api with its own per-tenant api key. edge-api then writes the rows and its
`user_logs` audit row. One instance serves one enterprise. It was called `operator-adapter`; the network
alias, cert path, metric names and `cmd/operator-adapter/` still use that name.

## Where it fits

```text
client operator app (Node-RED tee)
   │ HTTPS POST /operator/*   X-Ingest-Key
   ▼
operator-gateway ── SELECT topic_routing ⋈ equipments ⋈ areas ⋈ sites (as operator_gateway) ──▶ analytics DB
   │ POST /api/downtimes/* | /api/production-orders/*   x-api-key (tenant), ?idEnterprise=
   ▼
edge-api ──▶ analytics DB (downtimes, production orders, user_logs)
```

Scrap is not a route: scrap corrections are counter metrics and travel the data path
(tee → ingest-shim / sparkplug-agent → decoder), like PLC counters.

## Status and environments

| Environment | Where | Image | Ports | Health |
|---|---|---|---|---|
| dev (ADR-0060) | `dev/services/operator-gateway.yml` · `operator-gateway`; tenant 3 + the seed's topic prefix; self-signed cert from `dev-tls` | built from `services/operator-gateway/Dockerfile` (Go 1.25 → distroless) | `127.0.0.1:8445` → 8443 (TLS) | `GET /healthz` |
| staging | `compose.staging.yml` · `operator-gateway` (no profile), alias `operator-adapter`, IP 172.18.0.30; enterprise 4 (Incoplast), prefix `INCOPLAST` | same, built on deploy | `127.0.0.1:8445` → 8443 (host loopback only) | `GET /healthz`; healthcheck `operator-gateway --healthcheck` |
| production | defined in `compose.production.yml` · profile `client-ingest` (tenant from `OPERATOR_ADAPTER_*` env); new-stack production is not promoted | same | `8445` → 8443 (the security group does not admit 8445) | same |

No nginx vhost routes to it; the `operator.<domain>` vhosts serve the operator SPA, a different
container.

## Interfaces

### HTTP

Spec: [`docs/api/openapi/operator-gateway.openapi.json`](../../docs/api/openapi/operator-gateway.openapi.json)
(served live at `GET /openapi.json`; portal https://api.staging.packiot.app/docs/, cs-admin SSO).
All action routes are POST (405 otherwise) and need `X-Ingest-Key` (constant-time compare, 401).

| Method | Path | edge-api call | `user_logs` eventType |
|---|---|---|---|
| POST | `/operator/downtime` | `id_param` 30810/30811 → `/api/downtimes/create-manual-event`; 30812–30814 → `/api/downtimes/edit-manual-event` | `manual-event-created` / `-edited` |
| POST | `/operator/po` | `/api/production-orders/create-and-start` | `order-created-started` |
| POST | `/operator/po/stop` | `/api/production-orders/stop` | `order-stopped` |
| POST | `/operator/po/setup` | `/api/production-orders/setup` (close current, optionally open next) | `order-changed` |
| POST | `/operator/po/replace` | `/api/production-orders/replace` | `order-replaced` |
| POST | `/operator/po/change-status` | `/api/production-orders/change-status` | `order-status-changed` |
| POST | `/operator/po/change-time` | `/api/production-orders/change-time` | `order-time-changed` |
| POST | `/operator/split` | `/api/downtimes/split` | `event-splitted` |
| GET | `/healthz` | — | `{"healthy":true,"db":true}`; 503 when the resolver pool is down |
| GET | `/metrics` | — | Prometheus (OpenMetrics with trace exemplars) |
| GET | `/openapi.json` | — | the spec |

The PO routes are action-driven (one route = one edge-api endpoint), not a decoder of a client's
SparkPlug `Parameter[30800..]` encoding; each tee does the small translation. The OpenAPI spec lists
every field per route. Key rules:

- **The tee sends `packml_topic` plus the fields it owns.** `id_equipment`, `id_site`, `id_area` and
  `cd_machine` always come from the resolved topic; body values are ignored.
- **Order number (ADR-0062):** `/operator/po` `id_order` may be a JSON string or number and is forwarded
  as a trimmed string to `idOrder` + `orderNumber` (`834.058` → `"834.058"`).
- **`stop_type`** accepts `pause`/`finish` or the numeric `1` (= pause) / `2` (= finish).

**Scope (403):** the body's `enterprise` must equal `INCOPLAST_ENTERPRISE_ID`, or the topic must start
with `INCOPLAST_TOPIC_PREFIX`. The tenant is never chosen by the caller.

**Resolution:** active register rows of the configured enterprise only, exactly one match. Hits are
cached 5 min, misses 30 s (a newly registered topic can 422 for up to 30 s).

| Condition | Response |
|---|---|
| resolved, mapped, edge-api 2xx | 202 `{"status":"accepted"}` |
| edge-api 4xx | same status, edge-api body passed through |
| edge-api 5xx | 502 |
| edge-api unreachable or > 10 s | 503 |
| topic missing / unknown / inactive / cross-tenant / ambiguous | 422 |
| required action field missing | 422 (names the field) |
| resolver DB error | 503 (nothing sent; safe to retry) |
| bad JSON | 400 |

**Idempotency:** a 502, or a 503 caused by the 10 s timeout, can follow a write edge-api already
committed. The gateway sends edge-api an `Idempotency-Key` so the retry is answered from edge-api's
24 h key store instead of written twice: the caller's own `Idempotency-Key` header (any action), or
else a key derived from tenant + endpoint + edge-api body for the time-anchored writes (downtime
justify/manual, PO create-and-start, stop, setup). Edit, replace, change-status, change-time and
split get no derived key (an identical body can be a new action), so callers should send their own.
See `internal/adapter/idempotency.go`.

### Messaging

N/A: HTTP in, HTTP out.

### Database

One read, as the least-privilege login **`operator_gateway`** (migration
[`db/migrations/t-operator-gateway-role/`](../../db/migrations/t-operator-gateway-role/)): NOSUPERUSER,
NOBYPASSRLS, NOINHERIT, read-only sessions (`default_transaction_read_only=on`, `statement_timeout=5s`),
max 3 pool connections to `packiot_analytics`. All writes happen in edge-api.

| Call path | Statement | Privilege it needs |
|---|---|---|
| boot (`db.New`, `MinConns=1`) and `/healthz` (`Ping`) | connect | `CONNECT` on the database |
| resolver (`queryEquipment`), per uncached topic | `BEGIN READ ONLY; SELECT set_config('app.tenant_id', <enterprise>, true)` | none (built-in) |
| | `SELECT … FROM core.topic_routing ⋈ core.equipments ⋈ core.areas ⋈ core.sites` | `USAGE` on `core`; `SELECT` on `topic_routing(packml_topic, id_equipment, active)`, `equipments(id_equipment, cd_equipment, id_area)`, `areas(id_area, id_site)`, `sites(id_site, id_enterprise)` |
| the RLS policies on `topic_routing` + `equipments` (run as the caller) | `public.current_tenant()`, `public.is_all_tenant()` | `USAGE` on `public`, `EXECUTE` on both |

Nothing else: no writes, sequences, `LISTEN` or other functions. **RLS:** `core.topic_routing` and
`core.equipments` are `FORCE ROW LEVEL SECURITY` on `app.tenant_id`, so the resolver stamps the
instance's enterprise as a transaction-local GUC first (safe under pgbouncer transaction pooling, as
read-api does); without it the role sees 0 rows and every topic would 422. The resolver's own
`s.id_enterprise = $2` fence stays primary. It reads `core.topic_routing` rather than the
`security_invoker` compat view, which would need `SELECT` on every column of the table.
`resolver_role_golden_test.go` (`-tags golden`, CI "golden fixtures") applies the real migration and runs
this call path as the role, including the denials.

## Configuration

| Name | Default | Required | Effect |
|---|---|---|---|
| `OPERATOR_API_KEY` | — | yes | shared key the tee sends as `X-Ingest-Key` (staging: `.env`) |
| `EDGE_API_KEY` | — | yes | the tenant's `enterprises.api_key` sent to edge-api (staging: `.env` `OPERATOR_EDGE_API_KEY`); never logged |
| `INCOPLAST_ENTERPRISE_ID` | — | yes (integer) | the one enterprise this instance serves |
| `INCOPLAST_TOPIC_PREFIX` | empty | no | second scope match on the topic |
| `EDGE_API_URL` | `http://edge-api:8080` | no | edge-api base URL |
| `PORT` | `8443` | no | TLS listener |
| `TLS_CERT_FILE`, `TLS_KEY_FILE` | — | yes | the process refuses to serve plaintext |
| `AWS_REGION` | `us-east-1` | no | Secrets Manager region |
| `PG_SECRET_ID` | `packiot/staging/db` (code); compose sets `packiot/<env>/operator-gateway-db-creds` | no | resolver DB credentials secret (`{host,port,user,password,name}`, user `operator_gateway`); compose reads it from `OPERATOR_GATEWAY_PG_SECRET_ID` when set |
| `CREDS_SOURCE` | unset | no | `env` = read `DB_*` from env instead of Secrets Manager |
| `DB_HOST`, `DB_PORT`, `DB_NAME` | `postgres`, `5432`, `packiot` | with `CREDS_SOURCE=env` | resolver DB location |
| `DB_USER`, `DB_PASSWORD` | — | with `CREDS_SOURCE=env` | resolver DB login; empty fails closed |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | no | tracing to Tempo; unset = off |
| `OTEL_TRACES_SAMPLER_ARG` | `1.0` | no | trace sampling ratio |

Staging and production read the `operator_gateway` login from Secrets Manager
(`packiot/staging/operator-gateway-db-creds`, `packiot/production/operator-gateway-db-creds`; staging's
holds host `10.10.10.89`, database `packiot_analytics`, direct, not pgbouncer). `CREDS_SOURCE` is unset
there and the service has no `env_file`, so the admin `POSTGRES_*` from `.env` never enters the container.
Dev (`CREDS_SOURCE=env`) logs in as `operator_gateway` with the seed's password `dev`.
`scripts/ci/check-db-least-priv.py` (PR Validation) fails a compose change that hands this service the
admin login, an admin secret or an `env_file`.

## Run locally

```sh
make dev SVC="operator-gateway"          # + edge-api (submodule) and its migrations, dev-tls
make dev-smoke SVC="operator-gateway"    # a manual downtime written through edge-api
curl -sk https://127.0.0.1:8445/healthz
cd services/operator-gateway && go test -race ./...
```

It runs in the `edge` slice of `.github/workflows/dev-slices.yml` (needs `DEV_SUBMODULES_TOKEN`) and in
the `go-services.yml` matrix. `openapi_completeness_test.go` checks the spec covers every route.

## Provisioning the DB role

Once per environment, **before** the compose change that points the service at the role is deployed (a
deploy without the secret exits at boot: `fetch db secret failed`). Commands are for staging; production
is the same with `packiot/production/*` and its own hosts. No password is ever printed or copied off a host.

1. **Apply the migration** on the DB host (instance tag `packiot-staging-db`), as in
   [Add a migration, steps 8–9](../../docs/wiki/build/develop/add-a-migration.md#8-dry-run-on-staging):
   dry-run `01-up.sql` with `COMMIT` → `ROLLBACK`, then apply it and run `verify.sql`. Every `V` line
   must match its label; `I1` is `f` (no password yet).
2. **Copy the provisioning script to the app host** (instance tag `packiot-staging-app`; the host has
   no checkout of an unmerged branch): on your laptop
   `base64 -w0 scripts/ops/provision-operator-gateway-db-role.py`, then on the host
   (`aws ssm start-session --target <app instance>`, `sudo -i`)
   `echo '<paste>' | base64 -d > /root/provision-operator-gateway-db-role.py`.
3. **Create the secret and set the role password** on the app host:
   `python3 /root/provision-operator-gateway-db-role.py`. It checks the role (step 1 done), generates a
   256-bit password and creates `packiot/staging/operator-gateway-db-creds` =
   `{host: 10.10.10.89, port: 5432, user: operator_gateway, password, name: packiot_analytics}` (the app
   instance role may create `packiot/staging/*`), sets the role password as a SCRAM verifier (the plaintext
   never reaches Postgres or its logs), then logs in as `operator_gateway`. Expect four numbered lines
   ending `4. login OK as operator_gateway …`. Re-running is safe (it reuses the secret).
4. **Re-run `verify.sql`** on the DB host: `I1` is now `t`.
5. **Merge the PR and deploy** ("Deploy to Staging"). The container is recreated with
   `PG_SECRET_ID=packiot/staging/operator-gateway-db-creds` and no `.env`.
6. **Verify it connects as `operator_gateway`:**
   - `docker logs operator-gateway 2>&1 | grep 'db secret fetched'` shows
     `postgres://operator_gateway:***@10.10.10.89:5432/packiot_analytics…`;
   - `curl -sk https://127.0.0.1:8445/healthz` → `{"db":true,"healthy":true}`;
   - on the DB host: `SELECT usename, count(*) FROM pg_stat_activity WHERE application_name = 'operator-gateway' GROUP BY 1;`
     → only `operator_gateway`;
   - the next real Incoplast action is `accepted` (dashboard `07-operator.json`, or
     `operator_adapter_requests_total` has no new `unresolved`/`resolver_error`).
7. **Confirm the admin path is unused:**
   `docker inspect operator-gateway --format '{{json .Config.Env}}' | grep -c POSTGRES_` → `0`, and the
   `pg_stat_activity` query above returns no `postgres` row for `operator-gateway`.

**Rotate:** `python3 provision-operator-gateway-db-role.py --rotate`, then
`docker compose -f compose.staging.yml -p stack up -d --force-recreate operator-gateway` and step 6
(open connections keep the old password until the recreate). `--check` verifies without changing
anything. **Roll back:** revert the compose change and redeploy (the service goes back to the admin
login), then, if the role should go, `rollback.sql` on the DB host. Production: the role is a cluster
object, so apply the migration and run the script there too (`--env production --db-host <host>`).

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`). The TLS
  pair lives at `/opt/packiot/operator-adapter/certs/` on the host (mounted read-only). The container
  exits at boot if the keys, enterprise id, TLS files or the DB pool are missing.
- **Metrics:** `operator_adapter_requests_total{action,outcome}` and the RED histogram
  `http_request_duration_seconds`; scraped by job `operator-gateway` (`monitoring/prometheus/prometheus.yml`).
  Dashboards: `grafana/dashboards/library/07-operator.json` ("Operator — actions & adapter") and
  `library/12-api.json`. Traces go to Tempo when `OTEL_EXPORTER_OTLP_ENDPOINT` is set (staging: yes).
- **Reading a 422:** a topic that does not resolve is a registration problem (not in `packml_register`,
  inactive, or another tenant's) — fix it in CS-Admin, not here. A named missing field is a tee bug.
- **ADR-0061** removes `packml_topic` from the cloud; this service's topic resolution is one of the
  remaining consumers.

## Code layout

| Path | What |
|---|---|
| `cmd/operator-adapter/main.go` | boot, config, pool, TLS server, `--healthcheck` (binary `operator-gateway`) |
| `internal/adapter/server.go` | routes, auth, scope, status translation |
| `internal/adapter/mapping.go` | downtime and PO-start body → edge-api DTO |
| `internal/adapter/po_lifecycle.go` | stop / setup / replace / change-status / change-time |
| `internal/adapter/split.go` | event split |
| `internal/adapter/ordernumber.go` | ADR-0062 order-number normalisation |
| `internal/adapter/resolver.go` | topic → equipment resolver with TTL cache |
| `internal/adapter/edgeclient.go` | edge-api client (10 s timeout) |
| `internal/adapter/openapi.go`, `openapi.json` | embedded spec |
| `internal/adapter/metrics.go`, `internal/httpmetrics/` | Prometheus collectors |
| `internal/db/`, `internal/secrets/`, `internal/tracing/` | pool, credentials, OpenTelemetry |

## Related docs

- [ADR-0020 Incoplast staging test tenant](../../docs/adr/0020-incoplast-staging-test-tenant.md)
- [ADR-0061 remove PackML from the cloud](../../docs/adr/0061-remove-packml-from-the-cloud.md)
- [ADR-0062 production-order identity](../../docs/adr/0062-production-order-identity-and-alphanumeric-numbers.md)
- [ADR-0060 dev environment](../../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md)

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [operator-gateway](https://wiki.packiot.app/understand/components/operator-gateway/) |
| API reference (generated from the spec) | [operator-gateway](https://wiki.packiot.app/reference/api/operator-gateway/) |
| Interactive API docs (staging, SSO) | [API portal](https://api.staging.packiot.app/docs/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
