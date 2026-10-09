---
title: barcode-service
layer: 3
owner_area: serving
last_verified: 2026-09-28
---
# barcode-service

> **Layer 3 · Components** — the standalone Go box-scan ingest with a gapless per-PO label
> sequence. Deployed on staging but **superseded** by edge-api's `/api/scanned-boxes`, which
> the barcode app actually uses. Read this before touching scan counting in either place.
> Up: [Serving & APIs](../subsystems/serving-apis.md)

## Responsibility

Record each box scan durably and assign it a **server-authoritative, gapless** label number
per production order (1, 2, 3, … with no gaps or duplicates, even with concurrent scanners
and client retries), and stream accepted scans to listeners. It is "Phase 0" of a planned
serialization feature: GS1 parsing, EPCIS, e-signatures and genealogy are marked
`// PHASE-2:` and not built.

!!! warning "Status: running but orphaned"
    The live barcode app (`barcode.staging.packiot.app`, repo `barcode-scanner-v2`) calls
    **edge-api** `POST /api/scanned-boxes` through its nginx, which injects the sandbox
    (2000003) api-key. edge-api's scanned-boxes DAO is a port of this service's algorithm
    (task #230) and writes the same tables. No first-party client was found calling
    `scan.staging.packiot.app/v1/scans`. The container still starts on every staging deploy;
    it is not in `compose.production.yml`, not scraped by Prometheus and not in the Go CI
    matrix.

## At a glance

| | |
|---|---|
| Language / runtime | Go, single binary (`services/barcode-service/cmd/barcode-service`), distroless |
| Container (staging) | `barcode-service`, IP `172.18.0.36` |
| Port | `8446` (API + `/healthz` + `/metrics` + SSE) |
| Public route (staging) | `https://scan.staging.packiot.app` → nginx `scan.conf` → `172.18.0.36:8446`, exact paths `/v1/scans` and `/v1/scans/stream` only; no SSO gate (the service is its own auth) |
| DB | pgbouncer → `packiot_analytics`, pool of 5, simple protocol |
| Auth | Cognito ID token (tenant from the `custom:id_enterprise` claim); Firebase path disabled (`FIREBASE_PROJECT_ID=""`) |
| Depends on | pgbouncer, Cognito JWKS |
| Depended on by | nothing verified (see status) |

## Inputs & outputs

| Route | Auth | Purpose |
|---|---|---|
| `POST /v1/scans` | Bearer | Assign or validate the next label, write the scan |
| `GET /v1/scans/stream?id_production_order=` | Bearer | Server-sent events of accepted scans for one PO in the caller's tenant |
| `GET /healthz` | none | 503 when the DB is unreachable |
| `GET /metrics` | none | placeholder |

Tables (moved out of the old `barcode` schema by migration `t241-barcode-fold`, resolved by
bare name through the DB `search_path`):

| Table | Role |
|---|---|
| `bronze.box_scans` | Append-only scan ledger; `scan_uuid` UNIQUE; partial unique `(id_production_order, label_seq) WHERE scan_type='production'`; UPDATE/DELETE blocked by trigger |
| `gold.po_box_counter` | Per-PO `last_label_seq`, `total_qty` (the lock anchor) |
| `serving.v_po_box_totals` | Per-PO totals view |

## Internal design

`POST /v1/scans` body: `scan_uuid` (client-generated), `raw_barcode`,
`id_production_order`, `id_equipment`, `qty`, `scan_type`
(`production|sample|void|reprint|rework`), `mode` (`assign|validate`), `label_seq`
(validate only).

```sql
BEGIN;
  SELECT pg_advisory_xact_lock(<id_production_order>);   -- serialise writers for this PO
  -- 1. scan_uuid seen before?  → return the original row (replayed=true, 200), write nothing
  -- 2. PO and equipment belong to the token's enterprise?  else 403 tenant_mismatch
  -- 3. read po_box_counter.last_label_seq
  --    assign   → label_seq = last + 1
  --    validate → label_seq must equal last + 1, else 409 {label_seq_gap, expected, got}
  --    non-production scan types do not consume the sequence
  -- 4. INSERT box_scans; UPSERT po_box_counter (last_label_seq, total_qty)
COMMIT;                                                   -- releases the lock
```

The advisory lock works behind pgbouncer transaction pooling because the whole
BEGIN…COMMIT pins one server connection. The SSE hub (`sse.go`) is in-memory: it fans out
accepted scans per PO and per tenant, and does not survive a restart or span replicas.

## Configuration

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `HTTP_PORT` | `8446` | `8446` | |
| `DB_HOST` / `DB_PORT` | `pgbouncer` / `5432` | same | |
| `DB_USER` / `DB_PASSWORD` | `postgres` / — | `.env` | Missing password → unhealthy, not a crash |
| `DB_NAME` | `packiot_analytics` | same | |
| `FIREBASE_PROJECT_ID` | `fbpackiot` | `""` (disabled) | Firebase path |
| `COGNITO_ISSUER` | — | staging pool issuer | `""` disables Cognito |
| `COGNITO_CLIENT_ID` | — | staging app client | Audience check (`""` skips it) |
| `LOG_LEVEL` | `info` | `info` | |

## Data & invariants

- Gapless, monotonic `production` label sequence per PO; the server decides it.
- Idempotent by `scan_uuid`.
- Tenant is derived from the verified token only; checked inside the transaction.
- `box_scans` is append-only.

These are the same invariants edge-api's `/api/scanned-boxes` implements
(`edge-api/src/data/DAO/scanned-boxes/scanned-boxes-dao.ts`, `applyScan`), against the same
tables. Two writers are safe together because both take the same per-PO advisory lock.

## Observability

Structured JSON logs only; `/metrics` is a placeholder and there is no Prometheus job.
Health via the docker healthcheck (`barcode-service --healthcheck` → `/healthz`).

## Failure modes

| Symptom | Cause |
|---|---|
| 401 | Token missing, expired, wrong issuer/audience, or no `custom:id_enterprise` claim |
| 403 `tenant_mismatch` | PO or equipment belongs to another enterprise |
| 409 `label_seq_gap` | Validate mode with a stale client counter |
| 503 on `/healthz` | DB unreachable |

## Operating it

Nothing depends on it today. Options, for whoever owns scanning: remove it from
`compose.staging.yml` (and the `scan` vhost/DNS), or make it the scan plane again and point
the barcode app at it. Do not change scan-counting logic in one place without the other
while both exist. See [Barcode app](barcode-app.md).

## Tests

`cd services/barcode-service && go test ./...`: gapless assign/validate, idempotent replay,
tenant mismatch (in-memory `scanTx` fake), and the JWT verifier paths.

## Source map

| Path | What's there |
|---|---|
| `services/barcode-service/cmd/barcode-service/main.go` | Config, pool, routes |
| `services/barcode-service/cmd/barcode-service/scans.go` | `applyScan`, the advisory-locked transaction |
| `services/barcode-service/cmd/barcode-service/sse.go` | In-memory SSE hub |
| `services/barcode-service/cmd/barcode-service/auth*.go` | Cognito / Firebase verification |
| `services/barcode-service/README.md` | Contract details |
| `edge-node-red/db/36-box-scans.sql`, `db/migrations/t241-barcode-fold/` | Schema and its move to `bronze`/`gold` |
| `edge-api/src/usecases/scanned-boxes/`, `edge-api/src/data/DAO/scanned-boxes/` | The replacement used by the barcode app |
| `compose.staging.yml` (`barcode-service`), `terraform/staging/user_data/nginx_setup.sh` (`scan.conf`) | Deployment and routing |
