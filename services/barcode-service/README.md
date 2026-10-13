# barcode-service

Durable box-scan ingest with a server-authoritative, gapless per-production-order label sequence
(ADR-0040, Phase 0).

## What it does

A scanner client posts one box scan at a time to `POST /v1/scans`. The service derives the tenant
(`id_enterprise`) from the caller's JWT, never from the request, and writes the scan inside one
Postgres transaction under a per-PO advisory lock, so the `production` label sequence is dense
(1, 2, 3, …) even with concurrent scanners and client retries. `scan_uuid` is a client-generated
idempotency key: a replay of an accepted scan returns the original row with `replayed: true` and
writes nothing. Accepted scans are also pushed to live subscribers of `GET /v1/scans/stream` (SSE).
Phase 0 is the durable ingest only: no GS1 parsing, EPCIS, e-signatures or genealogy (the
`// PHASE-2:` markers in the code show where they go).

## Where it fits

```text
 scanner clients
        │ HTTPS  Authorization: Bearer <Cognito ID token>
        ▼
 nginx  scan.staging.packiot.app  (exact paths /v1/scans, /v1/scans/stream, /healthz)
        ▼
 barcode-service :8446 ──▶ pgbouncer ──▶ analytics DB packiot_analytics
        │                                 bronze.box_scans, gold.po_box_counter,
        │                                 serving.v_po_box_totals
        └── SSE fan-out (in-process) ──▶ live subscribers of the same PO and tenant
```

## Status and environments

| Environment | Where (compose file · service · profile) | Image | Ports | Health |
|---|---|---|---|---|
| dev | `dev/services/barcode-service.yml` · `barcode-service` · slice `barcode` | built from `Dockerfile` | `127.0.0.1:8446` | `--healthcheck` → `/healthz` |
| staging | `compose.staging.yml` · `barcode-service` · no profile | built from `Dockerfile` | in-network 8446 (no host publish); public via the `scan.` vhost | `--healthcheck` → `/healthz` (503 when the DB is unreachable) |
| production | not in `compose.production.yml` | — | — | — |

Image: Go 1.25 Alpine builder → `gcr.io/distroless/static-debian12:nonroot`.
The `barcode-app` compose service (`barcode-app:staging`, `127.0.0.1:8092`) is a separate SPA, not this
service.

## Interfaces

### HTTP

| Method | Path | Auth | What |
|---|---|---|---|
| POST | `/v1/scans` | Bearer JWT (Cognito, or Firebase when enabled) | Durable scan write, `mode` = `assign` (server allocates `last + 1`) or `validate` (asserts the client's `label_seq == last + 1`) |
| GET | `/v1/scans/stream?id_production_order=` | Bearer JWT | SSE feed of accepted scans for one PO, tenant-scoped; 25 s heartbeat; best-effort (slow clients drop) |
| GET | `/healthz` | none | 200, or 503 when the DB is unreachable (ADR-0011 rule 4) |
| GET | `/metrics` | none | Phase-0 placeholder text: `barcode_scans_served_total`, `barcode_scans_failed_total` |
| GET | `/openapi.json` | none | The OpenAPI document (in-network only; not proxied by the vhost) |

Spec: [`docs/api/openapi/barcode-service.openapi.json`](../../docs/api/openapi/barcode-service.openapi.json)
(source `cmd/barcode-service/openapi.json`); browse it in the API portal at
https://api.staging.packiot.app/docs/ (SSO).

Error codes (JSON `{"error": "<code>"}`): `scan_uuid_required`, `id_production_order_required`,
`id_equipment_required`, `qty_invalid`, `scan_type_invalid`, `mode_invalid`, `label_seq_required`
(400); `tenant_mismatch` (403: PO or equipment not owned by the token's tenant); `label_seq_gap` (409,
with `expected`/`got`); `scan_uuid_conflict` (409: the `scan_uuid` belongs to another tenant). Every
auth failure is the same 401. Request bodies are capped at 64 KiB.

### Messaging

N/A: no broker. The SSE fan-out is an in-memory, single-process broker (`sse.go`).

### Database

Analytics DB `packiot_analytics` through pgbouncer, simple query protocol, max 5 connections.
Table names are unqualified and resolve through the DB `search_path`
(`db/migrations/t241-barcode-fold/` moved them out of the old `barcode` schema).

| Object | Access |
|---|---|
| `bronze.box_scans` | INSERT (append-only; a no-mutate trigger rejects UPDATE/DELETE); SELECT for replays |
| `gold.po_box_counter` | SELECT + UPSERT `last_label_seq`, `total_qty` |
| `production_orders`, `equipments` | SELECT: tenant fence; `id_site`, `id_area`, `id_order` filled server-side |
| `users` | SELECT `id_enterprise` for a Firebase uid (Firebase path only) |

`serving.v_po_box_totals` is the per-PO totals view over these tables.

## Configuration

| Name | Default | Required | Effect |
|---|---|---|---|
| `HTTP_PORT` | `8446` | no | Listener for the API, `/healthz`, `/metrics`, SSE; also used by `--healthcheck` |
| `DB_HOST` / `DB_PORT` | `pgbouncer` / `5432` | no | Database endpoint (dev: `postgres`) |
| `DB_USER` | `postgres` | no | Staging: `POSTGRES_USER` from `.env` |
| `DB_PASSWORD` | — | yes | Staging: `POSTGRES_PASSWORD` from `.env` |
| `DB_NAME` | `packiot_analytics` | no | Target DB |
| `FIREBASE_PROJECT_ID` | `fbpackiot` when **unset** | no | Set to `""` to turn the Firebase path off (staging and dev do). Read with `LookupEnv`, so an explicit empty value is honoured (#159) |
| `COGNITO_ISSUER` | — | no | `https://cognito-idp.<region>.amazonaws.com/<poolId>`; empty turns the Cognito path off. Staging: the staging pool; dev: the dev pool |
| `COGNITO_CLIENT_ID` | — | no | Expected `aud`; empty skips the audience check (Phase-0 lenient) |
| `LOG_LEVEL` | `info` | no | Read into config but **not applied**: the logger is fixed at info |

With both auth paths off every request is 401 (fail closed).

## Run locally

```sh
make dev SVC="barcode-service"        # Tier 0 + barcode-service on 127.0.0.1:8446 (dev Cognito pool, Firebase off)
make dev-smoke SVC="barcode-service"  # fail-closed 401 + the write-path tables exist
cd services/barcode-service && go test ./...   # CI: .github/workflows/go-services.yml
```

Unit tests use an in-memory transaction fake (`scans_test.go`) and offline JWT verification
(`auth_test.go`); `openapi_*_test.go` keep the embedded spec in step with the routes.
After changing `openapi.json`, run `make openapi` and commit the exported copy
(`.github/workflows/openapi-export.yml` fails on drift).

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`)
  rebuilds the image from source.
- **Public entry:** the `scan.` vhost in `terraform/staging/user_data/nginx_setup.sh` (DNS in
  `terraform/staging/dns.tf`) proxies only the exact API paths; barcode-service is the only auth
  layer. The docs portal fetches `/openapi.json` in-network.
- **Metrics:** only the placeholder counters above; there is no Prometheus scrape job, alert rule or
  Grafana dashboard for this service.
- **Failure modes:**
  - DB unreachable → `/healthz` 503, container unhealthy, writes rejected (by design).
  - `409 label_seq_gap` in `validate` mode → the client's counter is out of step; it should re-read
    `expected` instead of retrying the same number.
  - SSE clients miss scans under load or after a restart: the feed is advisory; `bronze.box_scans`
    is the record.
  - Every request 401 → check `COGNITO_ISSUER`/`COGNITO_CLIENT_ID` match the token's pool and app client.

## Code layout

| Path | What |
|---|---|
| `cmd/barcode-service/main.go` | config, pgx pool, routes, `/healthz`, `/metrics`, `--healthcheck` |
| `cmd/barcode-service/scans.go` | `POST /v1/scans`: validation, advisory lock, tenant fence, gapless assign/validate |
| `cmd/barcode-service/sse.go` | per-PO, per-tenant in-memory SSE broker |
| `cmd/barcode-service/auth.go`, `auth_cognito.go`, `auth_firebase.go` | issuer-routed JWT verification; tenant from `custom:id_enterprise` or the users table |
| `cmd/barcode-service/openapi.json`, `openapi.go` | embedded OpenAPI document and handler |

## Related docs

- [ADR-0040 — barcode traceability service](../../docs/adr/0040-barcode-traceability-service.md)
- [ADR-0011 — durability boundary and store-and-forward](../../docs/adr/0011-durability-boundary-and-store-and-forward.md)
- [ADR-0034 — adopt Cognito/Amplify auth](../../docs/adr/0034-adopt-cognito-amplify-auth.md)
- [ADR-0060 — local development environment](../../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md)

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [barcode-service](https://wiki.packiot.app/understand/components/barcode-service/) |
| API reference (generated from the spec) | [barcode-service](https://wiki.packiot.app/reference/api/barcode-service/) |
| Interactive API docs (staging, SSO) | [API portal](https://api.staging.packiot.app/docs/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
