# barcode-service (Phase 0)

Durable box-scan ingest with a **server-authoritative, gapless per-production-order
label sequence**. The Bronze-tier foundation of the North-star pharma/serialization
pillar — Phase 0 ships the durable gapless-ingest skeleton only. No EPCIS, no GS1
serialization, no Part-11 e-sig, no genealogy. Those slot in at the `// PHASE-2:`
markers.

Modelled on `services/refdata-api`: one lean Go binary, config from env, `pgx`
over pgbouncer (simple protocol for transaction pooling), structured `slog`,
and an **issuer-agnostic dual Firebase/Cognito JWT verifier** that derives the
tenant (`id_enterprise`) server-side and fails closed. The client never names a
tenant.

## Endpoints

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `POST` | `/v1/scans` | Bearer JWT | Durable gapless scan write (assign/validate) |
| `GET`  | `/v1/scans/stream?id_production_order=` | Bearer JWT | SSE feed of accepted scans for a PO (tenant-scoped) |
| `GET`  | `/healthz` | none | 503 when the DB is unreachable (ADR-0011 rule 4) |
| `GET`  | `/metrics` | none | Phase-0 placeholder (PHASE-2: Prometheus RED) |

### `POST /v1/scans`

```json
{
  "scan_uuid": "b1f2…",          // client-generated, UNIQUE → idempotency key
  "raw_barcode": "(01)0761…",    // PHASE-2: parsed into GS1 element strings
  "id_production_order": 4242,
  "id_equipment": 55,
  "qty": 1,
  "scan_type": "production",      // production|sample|void|reprint|rework
  "mode": "assign",               // assign | validate
  "label_seq": 7                  // required only in validate mode
}
```

- **assign** → server allocates `label_seq = last + 1`, writes the row, bumps the
  counter. Returns `{ box_scan_id, label_seq, total, scan_uuid, replayed:false }`.
- **validate** → server asserts `label_seq == last + 1`, else returns
  `409 { "error":"label_seq_gap", "expected":N, "got":M }`.
- **idempotent replay** → a repeat `scan_uuid` returns the original row
  (`replayed:true`, HTTP 200) and writes nothing.
- **tenant fence** → the PO and equipment must belong to the JWT's
  `id_enterprise`, checked inside the tx, else `403 tenant_mismatch`.

The gapless authority is one Postgres transaction:

```
BEGIN;
  SELECT pg_advisory_xact_lock(id_production_order);   -- serialize writers for this PO
  -- idempotent-replay check by scan_uuid
  -- tenant fence (PO + equipment belong to id_enterprise)
  -- read po_box_counter.last_label_seq → decide next / validate
  -- INSERT box_scans (label_seq = next)
  -- UPSERT po_box_counter (last_label_seq, total_qty)
COMMIT;                                                 -- releases the advisory lock
```

## Config (env)

| Var | Default | Notes |
|-----|---------|-------|
| `HTTP_PORT` | `8446` | serves API + `/healthz` + `/metrics` + SSE |
| `DB_HOST` / `DB_PORT` | `pgbouncer` / `5432` | |
| `DB_USER` / `DB_PASSWORD` | `postgres` / — | password from env/secret |
| `DB_NAME` | `packiot_analytics` | writes to the analytics plane (go-forward) |
| `FIREBASE_PROJECT_ID` | `fbpackiot` | `""` disables the Firebase path |
| `COGNITO_ISSUER` | — | `https://cognito-idp.<region>.amazonaws.com/<poolId>`; `""` disables Cognito |
| `COGNITO_CLIENT_ID` | — | Cognito app-client id (aud); `""` skips the audience check (Phase-0 lenient). Same var refdata-api uses. |
| `LOG_LEVEL` | `info` | |

## Data model

Migration `edge-node-red/db/36-box-scans.sql` creates:
- `box_scans` — the append-only Bronze table (identity PK, `scan_uuid` UNIQUE,
  partial-unique `(id_production_order, label_seq) WHERE scan_type='production'`,
  `BEFORE UPDATE OR DELETE` trigger that RAISEs + `REVOKE UPDATE,DELETE`).
- `po_box_counter` — per-PO `last_label_seq` + `total_qty` (the advisory-lock anchor).
- `v_po_box_totals` — the authoritative per-PO totals view.

FK note: the hierarchy PKs (`enterprises/sites/areas/equipments.id_*`,
`production_orders.id_order`) are `INTEGER` in `packiot_analytics`; only
`production_orders.id_production_order` is `BIGINT`. The FK columns are
type-matched accordingly; `id_site/id_area/id_order` are nullable and populated
server-side from the tenant's own rows.

## Tests

`go test ./...` — unit-tests the gapless assign/validate logic against an
in-memory `scanTx` fake (assign returns last+1; validate rejects a gap with 409;
idempotent replay returns the original row with no second insert; tenant mismatch
rejected) plus the dual-verifier auth path (issuer routing, fail-closed tenant,
full offline Firebase RS256 verify, Cognito claim-tenant).
