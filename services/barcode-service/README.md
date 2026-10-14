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
 barcode-service :8446 ──▶ pgbouncer ──▶ analytics DB packiot_analytics  (role barcode_service)
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
auth failure is the same 401. Request bodies are capped at 64 KiB; a larger body gets 413
`{"error":"request body too large"}`.

### Messaging

N/A: no broker. The SSE fan-out is an in-memory, single-process broker (`sse.go`).

### Database

Analytics DB `packiot_analytics` through pgbouncer, simple query protocol, max 5 connections, as the
least-privilege login **`barcode_service`** (migration
[`db/migrations/t-barcode-service-role/`](../../db/migrations/t-barcode-service-role/)): NOSUPERUSER,
NOBYPASSRLS, NOINHERIT, column grants only, `statement_timeout=30s`. Table names are schema-qualified in
the code (`db/migrations/t241-barcode-fold/` moved them out of the old `barcode` schema).

| Call path | Statement | Privilege it needs |
|---|---|---|
| boot (`newPool`) and `/healthz` (`Ping`) | connect | `CONNECT` on the database |
| `POST /v1/scans`, one tx per scan (`RecordScan`) | `SELECT pg_advisory_xact_lock(id_po)` | none (`EXECUTE` is granted to `PUBLIC`) |
| | `SELECT set_config('app.tenant_id', <JWT tenant>, true)` | none (built-in) |
| replay check (`existingByUUID`) | `bronze.box_scans ⟕ gold.po_box_counter` by `scan_uuid` | `SELECT` on `box_scans(scan_uuid, id_enterprise, box_scan_id, label_seq, id_production_order)`, `po_box_counter(id_production_order, total_qty)` |
| tenant fence (`tenantOwns`) | `EXISTS` on `core.production_orders`, `core.equipments` with `id_enterprise = $1` | `SELECT` on `production_orders(id_production_order, id_enterprise)`, `equipments(id_equipment, id_enterprise)` |
| gapless counter (`lastLabelSeq`) | `SELECT last_label_seq FROM gold.po_box_counter` | `SELECT` on `po_box_counter(id_production_order, last_label_seq)` |
| write (`insertScan`) | `INSERT INTO bronze.box_scans (13 columns) … RETURNING box_scan_id`, with scalar subqueries for `id_site`, `id_area`, `id_order` | `INSERT` on those 13 columns, `SELECT` on `box_scan_id`; `SELECT` on `equipments(id_site, id_area)`, `production_orders(id_order)` |
| | `INSERT INTO gold.po_box_counter … ON CONFLICT (id_production_order) DO UPDATE … RETURNING total_qty` | `INSERT` on its 5 columns, `UPDATE (last_label_seq, total_qty, updated_at)`, `SELECT` on the ones read |
| the RLS policies on `production_orders` + `equipments` (run as the caller) | `public.current_tenant()`, `public.is_all_tenant()` | `USAGE` on `public`, `EXECUTE` on both |

Schemas: `USAGE` on `bronze`, `gold`, `core`, `public`. Nothing else: no `UPDATE`/`DELETE` on
`box_scans` (append-only; its trigger rejects them anyway), no sequences (`box_scan_id` is an identity
column), no DDL, no `TRUNCATE`. Foreign-key checks run as the table owner, so they need no grant.

- **RLS:** `core.production_orders` and `core.equipments` are `FORCE ROW LEVEL SECURITY` on
  `app.tenant_id`. Right after the advisory lock, the scan transaction stamps the JWT tenant as a
  transaction-local GUC (safe under pgbouncer transaction pooling, as read-api does). Without the stamp
  the fence sees 0 rows and every scan is a 403 (fail closed). The SQL fences (`id_enterprise = $1`)
  stay primary. `box_scans` and `po_box_counter` have no RLS.
- **Firebase path:** the `identity.users` lookup gets no grant. Firebase is off on staging and dev
  (#159), and the query cannot run on `packiot_analytics` anyway: `identity.users` has no
  `id_user_firebase` column.
- **Proof:** `cmd/barcode-service/scans_role_golden_test.go` (`-tags golden`, CI "golden fixtures")
  applies the real migration and runs `RecordScan` as the role, including replay, 403, 409 and the
  denials. It is red-checked: removing the stamp or any single grant fails it.

`serving.v_po_box_totals` is the per-PO totals view over these tables (read by other services).

## Configuration

| Name | Default | Required | Effect |
|---|---|---|---|
| `HTTP_PORT` | `8446` | no | Listener for the API, `/healthz`, `/metrics`, SSE; also used by `--healthcheck` |
| `PG_SECRET_ID` | — | yes, unless `CREDS_SOURCE=env` | Secrets Manager id of the DB login `{host, port, user, password, name}`. Staging: `${BARCODE_SERVICE_PG_SECRET_ID:-packiot/staging/barcode-service-db-creds}` (host `pgbouncer`, user `barcode_service`). Empty → boot error, never a fallback |
| `AWS_REGION` | `us-east-1` | no | Region of the secret |
| `CREDS_SOURCE` | — | no | `env` (dev only) reads the login from `DB_HOST` (`postgres`), `DB_PORT` (`5432`), `DB_USER` (`barcode_service`), `DB_PASSWORD` (required), `DB_NAME` (`packiot_analytics`) |
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

## Provisioning the DB role

Once per environment, **before** the compose change that points the service at the role is deployed (a
deploy without the secret exits at boot: `db creds … get secret`). Commands are for staging. No password
is ever printed or copied off a host.

1. **Apply the migration** on the DB host (instance tag `packiot-staging-db`), as in
   [Add a migration, steps 8–9](../../docs/wiki/build/develop/add-a-migration.md#8-dry-run-on-staging):
   dry-run `01-up.sql` with `COMMIT` → `ROLLBACK`, then apply it and run `verify.sql`. Every `V` line
   must match its label; `I1` is `f` (no password yet). V9 runs a real scan insert as the role inside
   `BEGIN … ROLLBACK` (it only advances the `box_scan_id` identity).
2. **Copy the provisioning script to the app host** (instance tag `packiot-staging-app`): on your laptop
   `base64 -w0 scripts/ops/provision-db-role.py`, then on the host (`sudo -i`)
   `echo '<paste>' | base64 -d > /root/provision-db-role.py`.
3. **Create the secret and set the role password** on the app host:
   `python3 /root/provision-db-role.py --service barcode-service`. It checks the role, generates a
   256-bit password, creates `packiot/staging/barcode-service-db-creds` =
   `{host: pgbouncer, port: 5432, user: barcode_service, password, name: packiot_analytics}`, sets the role
   password as a SCRAM verifier on the DB host directly (the plaintext never reaches Postgres or its
   logs), then logs in as `barcode_service` **through pgbouncer**, the service's own path (pgbouncer
   authenticates the role with `auth_query` + SCRAM pass-through, as for `readapi_ro`). Expect four
   numbered lines ending `4. login OK as barcode_service via pgbouncer/packiot_analytics (statement_timeout=30s; …)`.
4. **Re-run `verify.sql`** on the DB host: `I1` is now `t`.
5. **Merge the PR and deploy** ("Deploy to Staging"). The container is recreated with
   `PG_SECRET_ID=packiot/staging/barcode-service-db-creds` and no `.env`.
6. **Verify it connects as `barcode_service`:**
   - `docker logs barcode-service 2>&1 | grep 'db creds loaded'` shows
     `postgres://barcode_service:***@pgbouncer:5432/packiot_analytics…`, and there is no
     `not logged in as the least-privilege role` warning;
   - `docker exec barcode-service /usr/local/bin/barcode-service --healthcheck; echo $?` → `0`;
   - on the DB host: `SELECT usename, count(*) FROM pg_stat_activity WHERE application_name = 'barcode-service' GROUP BY 1;`
     → only `barcode_service`;
   - a real scan (or the `scan.` API with a staging Cognito token) returns 201.
7. **Confirm the admin path is unused:**
   `docker inspect barcode-service --format '{{json .Config.Env}}' | grep -c POSTGRES_` → `0`.

**Rotate:** `python3 provision-db-role.py --service barcode-service --rotate`, then
`docker compose -f compose.staging.yml -p stack up -d --force-recreate barcode-service` and step 6.
pgbouncer re-reads the verifier on the next login. `--check` verifies without changing anything.
**Roll back:** revert the compose change and redeploy (back to the admin login), then, if the role
should go, `rollback.sql` on the DB host. Production: the service is not in `compose.production.yml`;
when it is, apply the migration there and run the script with
`--env production --db-host <its pgbouncer> --admin-host <DB host>`.

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
| `cmd/barcode-service/main.go` | config, routes, `/healthz`, `/metrics`, `--healthcheck` |
| `cmd/barcode-service/dbcreds.go` | DB login (Secrets Manager or dev env) and the pgx pool |
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
