---
title: barcode-service
layer: 3
owner_area: serving
last_verified: 2026-10-13
---
# barcode-service

> **Layer 3 · Components** — the Go box-scan ingest API with a gapless per-PO label
> sequence, live on staging at `scan.<staging domain>`. Read this before touching scan
> counting here or in edge-api's port of the same algorithm.
> Up: [Serving & APIs](../subsystems/serving-apis.md) ·
> [README](https://github.com/packiot/packiot-stack-alpha/blob/staging/services/barcode-service/README.md) ·
> [API reference](../../reference/api/barcode-service.md) ·
> [Service catalog](../../reference/service-catalog.md)

## Responsibility

Record each box scan durably and assign it a **server-authoritative, gapless** label number
per production order (1, 2, 3, … with no gaps or duplicates, even with concurrent scanners
and client retries), and stream accepted scans to live listeners. It is Phase 0 of the
serialization feature (ADR-0040): GS1 parsing, EPCIS, e-signatures and genealogy are marked
`// PHASE-2:` and not built.

!!! note "Two writers of the same tables"
    The service is deployed and publicly reachable on staging (`https://scan.staging.packiot.app`,
    exact paths `/v1/scans`, `/v1/scans/stream`, `/healthz`). The current
    [barcode app](barcode-app.md) build, however, writes scans through **edge-api**
    `POST /api/scanned-boxes` (its nginx injects the sandbox api-key); edge-api's
    scanned-boxes DAO is a port of this service's algorithm against the same tables. Both
    take the same per-PO advisory lock, so they are safe together, but a change to scan
    counting must be made in both places.

## At a glance

| | |
|---|---|
| Language / runtime | Go 1.25, single binary (`services/barcode-service/cmd/barcode-service`), distroless static, nonroot |
| Container (staging) | `barcode-service`, IP `172.18.0.36`, no host publish |
| Port | `8446` (API, SSE, `/healthz`, `/metrics`, `/openapi.json`) |
| Public route (staging) | nginx `scan.conf`: `/v1/scans`, `/v1/scans/stream`, `/healthz` only; no SSO gate (the service is its own auth); CORS for front4, csadmin and the operator hosts; `client_max_body_size 128k` |
| DB | pgbouncer → `packiot_analytics`, pool of 5, simple protocol |
| Auth | Cognito ID token; tenant from the signed `custom:id_enterprise` claim. Firebase verification disabled (`FIREBASE_PROJECT_ID=""`, #159) |
| Depends on | pgbouncer, Cognito JWKS |
| Depended on by | direct API clients of `scan.`; the staging API portal (spec) |
| Production (new stack) | not in `compose.production.yml` |

## Inputs & outputs

| Route | Auth | Purpose |
|---|---|---|
| `POST /v1/scans` | Bearer | Assign or validate the next label, write the scan |
| `GET /v1/scans/stream?id_production_order=` | Bearer | Server-sent events of accepted scans for one PO in the caller's tenant; 25 s heartbeat; slow clients are dropped |
| `GET /healthz` | none | 503 when the DB is unreachable |
| `GET /metrics` | none | Phase-0 placeholder text (`barcode_scans_served_total`, `barcode_scans_failed_total`) |
| `GET /openapi.json` | none | OpenAPI 3.1 document (in-network; nginx does not route it on `scan.`, the API portal proxies it) |

Tables (moved out of the old `barcode` schema by migration `t241-barcode-fold`, resolved by
bare name through the DB `search_path`):

| Table | Role |
|---|---|
| `bronze.box_scans` | Append-only scan ledger; `scan_uuid` UNIQUE; partial unique `(id_production_order, label_seq) WHERE scan_type='production'`; UPDATE/DELETE blocked by trigger |
| `gold.po_box_counter` | Per-PO `last_label_seq`, `total_qty` (the lock anchor) |
| `serving.v_po_box_totals` | Per-PO totals view |

## Internal design

`POST /v1/scans` body (unknown fields rejected, ≤ 64 KiB): `scan_uuid` (client-generated),
`raw_barcode`, `id_production_order`, `id_equipment`, `qty`, `scan_type`
(`production|sample|void|reprint|rework`), `mode` (`assign|validate`), `label_seq`
(validate only).

```sql
BEGIN;
  SELECT pg_advisory_xact_lock(<id_production_order>);   -- serialise writers for this PO
  -- 1. scan_uuid seen before?
  --      owned by the caller's enterprise → return the original row (replayed=true, 200)
  --      owned by another enterprise      → 409 scan_uuid_conflict (#1688), reveals nothing
  -- 2. PO and equipment belong to the token's enterprise?  else 403 tenant_mismatch
  -- 3. read po_box_counter.last_label_seq
  --    assign   → label_seq = last + 1
  --    validate → label_seq must equal last + 1, else 409 {label_seq_gap, expected, got}
  --    non-production scan types do not consume the sequence
  -- 4. INSERT box_scans; UPSERT po_box_counter (last_label_seq, total_qty)
COMMIT;                                                   -- releases the lock
```

The pure algorithm is `applyScan` (`scans.go`) over a `scanTx` interface, so it is unit-tested
without a database. The advisory lock works behind pgbouncer transaction pooling because the
whole BEGIN…COMMIT pins one server connection. The SSE hub (`sse.go`) is in-memory: it fans
out accepted scans per PO and per tenant and does not survive a restart or span replicas.

Before 2026-10-13 (#1688) a `scan_uuid` that belonged to another tenant was "replayed" with a
200, returning that tenant's box id, label number and PO total.

## Configuration

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `HTTP_PORT` | `8446` | `8446` | |
| `DB_HOST` / `DB_PORT` | `pgbouncer` / `5432` | same | |
| `DB_USER` / `DB_PASSWORD` | `postgres` / — | `${POSTGRES_USER}` / `${POSTGRES_PASSWORD}` | Missing password → unhealthy, not a crash |
| `DB_NAME` | `packiot_analytics` | same | |
| `FIREBASE_PROJECT_ID` | `fbpackiot` when unset | `""` (explicitly empty = off) | Firebase path |
| `COGNITO_ISSUER` | — | staging pool issuer | `""` disables Cognito |
| `COGNITO_CLIENT_ID` | — | staging app client | Audience check (`""` skips it) |
| `LOG_LEVEL` | `info` | `info` | |

## Data & invariants

- Gapless, monotonic `production` label sequence per PO; the server decides it.
- Idempotent by `scan_uuid`, **within the caller's tenant** (another tenant's uuid → 409).
- Tenant is derived from the verified token only; checked inside the transaction.
- `box_scans` is append-only.

These are the same invariants edge-api's `/api/scanned-boxes` implements
(`edge-api/src/data/DAO/scanned-boxes/scanned-boxes-dao.ts`) against the same tables.

## Observability

Structured JSON logs (`record scan failed`); `/metrics` is a placeholder and there is no
Prometheus job. Health via the docker healthcheck (`barcode-service --healthcheck` →
`/healthz`), also reachable publicly at `scan.…/healthz`.

## Failure modes

| Symptom | Cause |
|---|---|
| 401 | Token missing, expired, wrong issuer/audience, or no positive `custom:id_enterprise` claim |
| 400 `invalid json body` | Malformed JSON, an unknown field, or a body over 64 KiB (the service answers 400, not 413; nginx answers 413 above 128 KiB) |
| 403 `tenant_mismatch` | PO or equipment belongs to another enterprise |
| 409 `scan_uuid_conflict` | The `scan_uuid` was already used by another tenant; generate a fresh uuid |
| 409 `label_seq_gap` | Validate mode with a stale client counter |
| 503 on `/healthz` | DB unreachable |

## Operating it

Deploys with the stack (`deploy-staging.yml` builds `services/barcode-service`). Restart is
safe at any time (the only in-memory state is SSE subscribers, which reconnect). Do not
change scan-counting logic here without the edge-api port, and vice versa.

## Tests

`cd services/barcode-service && go test ./...` (CI `go-services.yml`): gapless
assign/validate, idempotent replay and the cross-tenant uuid conflict (`scans_test.go`,
in-memory `scanTx` fake), JWT verifier paths (`auth_test.go`), config (`config_test.go`),
spec parity and completeness (`openapi_test.go`, `openapi_completeness_test.go`; export
drift in `openapi-export.yml`).

## Source map

| Path | What's there |
|---|---|
| `services/barcode-service/README.md` | How to run it; error codes |
| `services/barcode-service/cmd/barcode-service/main.go` | Config, pool, routes |
| `services/barcode-service/cmd/barcode-service/scans.go` | `applyScan`, the advisory-locked transaction, body decoding |
| `services/barcode-service/cmd/barcode-service/sse.go` | In-memory SSE hub |
| `services/barcode-service/cmd/barcode-service/auth*.go` | Cognito (and disabled Firebase) verification |
| `services/barcode-service/cmd/barcode-service/openapi.json`, `openapi.go` | Embedded spec, served at `/openapi.json` |
| `db/migrations/t241-barcode-fold/` | Move of the scan tables to `bronze`/`gold` |
| `edge-api/src/usecases/scanned-boxes/`, `edge-api/src/data/DAO/scanned-boxes/` | The edge-api port used by the barcode app |
| `compose.staging.yml` (`barcode-service`), `terraform/staging/user_data/nginx_setup.sh` (`scan.conf`) | Deployment and routing |
