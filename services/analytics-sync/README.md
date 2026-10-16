# analytics-sync

Replays operator actions (`user_logs`) into the analytics DB: one Go module, three binaries —
`analytics-sync` (idle on staging), `legacy-replicator` (the CPACK twin feed, live on staging) and
`prod-reflector` (ADR-0064: a staging tenant as a read-only mirror of production; idle until switched on).

## What it does

Operator actions (start/stop a production order, justify or split a downtime, add a manual event)
are written by edge-api and logged in `user_logs`. Telemetry alone does not carry them, so this
module polls `user_logs` on a cursor, dispatches each row by `category` to a handler, and re-applies
the effect idempotently by natural key (`(id_enterprise, id_order)` for POs,
`(id_equipment, ts_event)` for events). The cursor advances on every row, so the loop never wedges.

- **`analytics-sync`** (`cmd/shadow-mirror`, formerly shadow-mirror, ADR-0013) replayed actions
  *within* one instance, from the F1 `packiot` DB into `packiot_analytics`. Its source DB is retired;
  it runs **idle** on staging (`SHADOW_MIRROR_ENABLED=false`) and only serves `/healthz` + `/metrics`.
- **`legacy-replicator`** (`cmd/legacy-replicator`) replays *across* instances: CPACK actions from the
  **legacy DB** (`packiot40`, enterprise 1, SELECT-only) into the **analytics DB** (enterprise 3, and
  the sandbox twin 2000003 via `legacy-replicator-sbx`). It maps ids at the boundary
  (`internal/replicate/resolver.go`: enterprise by config, equipment by PackML base topic, PO by
  `id_order`) and runs reconcilers that copy what never passes through `user_logs` (POs, product/client
  ids, manual events, PLC base events).

## Where it fits

```text
 legacy DB packiot40 (ent 1)                         analytics DB packiot_analytics
 ┌───────────────────────────┐   SELECT only        ┌──────────────────────────────────────┐
 │ user_logs                 │ ───────────────────▶ │ legacy-replicator      → ent 3       │
 │ production_orders         │                      │ legacy-replicator-sbx  → ent 2000003 │
 │ equipment_events(_man)    │                      │   writes core.production_orders,     │
 │ packml_register           │                      │   gold.production_orders_runtime,    │
 └───────────────────────────┘                      │   silver.equipment_events(_man),     │
                                                    │   ops.mirror_replay_cursor/_dlq      │
 F1 packiot DB (retired) ─ ─ ─ ▶ analytics-sync     └──────────────────┬───────────────────┘
                                 (idle)                                 ▼
                                                    stream-engine rollups, read-api, front4
```

## Status and environments

| Environment | Where (compose file · service · profile) | Image | Ports | Health |
|---|---|---|---|---|
| dev | `dev/services/analytics-sync.yml` · `analytics-sync` · slice `ingest` | built from `Dockerfile` | in-network 9103 | `--healthcheck` → `/healthz` |
| staging | `compose.staging.yml` · `analytics-sync` · no profile, **idle** | built from `Dockerfile` | in-network 9103 | `--healthcheck` |
| staging | `compose.staging.yml` · `legacy-replicator` (ent 1 → 3) · no profile | built from `Dockerfile.replicator` | in-network 9104 | `--healthcheck`; `/healthz` 503 after 600 s without a successful poll |
| staging | `compose.staging.yml` · `legacy-replicator-sbx` (ent 1 → 2000003) · no profile | built from `Dockerfile.replicator` | in-network 9114 | same; enabled only when `.env` sets `REPLICATE_SBX_ENABLED=true` |
| production | not in `compose.production.yml` (no legacy source in a greenfield prod) | — | — | — |

Both images: Go 1.25 Alpine builder → `gcr.io/distroless/static-debian12:nonroot`. Neither binary
publishes a host port.

## Interfaces

### HTTP

| Method | Path | Auth | What |
|---|---|---|---|
| GET | `/healthz` | none (in-network) | 200 while up; the replicator returns 503 when `HEALTHCHECK_MAX_AGE_SEC` > 0 and the loop is stale |
| GET | `/metrics` | none (in-network) | Prometheus metrics |

No OpenAPI spec: there is no business API.

### Messaging

N/A: neither binary uses RabbitMQ or MQTT; both poll Postgres.

### Database

| Binary | Reads | Writes |
|---|---|---|
| analytics-sync (when enabled; **idle on staging and dev: no connection, no DB credentials**) | `packiot.public.user_logs` | `shadow_go_port.*` (main pool) and `packiot_analytics.public.*`; cursor `mirror_replay_cursor` source `shadow-mirror` |
| legacy-replicator | legacy `user_logs`, `production_orders`, `equipment_events`, `equipment_events_man`, `packml_register`, products/clients | analytics `core.production_orders`, `core.products`/`clients`/`product_families`, `gold.production_orders_runtime`, `silver.equipment_events`, `silver.equipment_events_man`, `ops.mirror_replay_cursor` (source = `CURSOR_SOURCE`), `ops.mirror_replay_dlq`, `ops.legacy_manual_event_link`, `serving.downtime_events_resolved` (through `serving.refresh_downtime_events_resolved`); reads `ops.sandbox_hold_mode()` |


**Least privilege (analytics-sync).** The idle binary returns before it reads any DB setting, so
staging and dev give it **no DB login at all**: no `DB_*`, no `PG_SECRET_ID`, no `env_file` (it used to
receive the Postgres admin `POSTGRES_*` and the whole `.env` for a path that never runs).
`scripts/ci/check-db-least-priv.py` (`NO_DB`) fails if any of that comes back or if
`SHADOW_MIRROR_ENABLED` is flipped. No DB role is created for it: its replay source, the F1 `packiot`
DB, is retired, so a role would only grant a dead path. If it is ever re-enabled, give it a
`t-analytics-sync-role` migration first (as operator-gateway and barcode-service have: `SELECT` on
`user_logs` and the cursor, writes on its sink tables, NOBYPASSRLS) and move it to `SERVICES` in the
check.

#### legacy-replicator database role

The DEST (analytics) side logs in as the least-privilege **`legacy_replicator`** role
([`db/migrations/t-legacy-replicator-role/`](../../db/migrations/t-legacy-replicator-role/)), never the
Postgres admin. One role serves both instances (`legacy-replicator`, ent 3, and `legacy-replicator-sbx`,
ent 2000003). NOSUPERUSER, NOBYPASSRLS, NOINHERIT, owns nothing. **The LEGACY source side is unchanged**:
`LEGACY_DB_*`, the SELECT-only `awslambda` login on `packiot40`, read exactly as before.

| What the replicator does (DEST statements, incl. triggers its writes fire) | Privilege |
|---|---|
| resolver: `core.packml_register` (security_invoker view → `core.topic_routing`), `core.equipments` | SELECT |
| PO-number trigger `production_orders_po_number` on every PO INSERT/UPDATE: `core.po_number_corrections` | SELECT |
| serving refresh joins: `core.sites`, `core.shifts`, `gold.equipment_oee_shift`; sandbox gate: `ops.sandbox_hold_status` | SELECT |
| PO lifecycle replay, PO reconciler (insert, finish, fill start, retime, revert), enrich: `core.production_orders` | SELECT, INSERT, UPDATE |
| enrich find-or-create dimensions: `core.products`, `core.product_families`, `core.clients` | SELECT, INSERT |
| runtime windows open/close/reassign; converge deletes + re-inserts a PO's windows: `gold.production_orders_runtime` | SELECT, INSERT, UPDATE, DELETE |
| base events (replay + base reconciler insert; classify/split update): `silver.equipment_events` | SELECT, INSERT, UPDATE |
| manual-event reconciler (deletes only rows it owns): `silver.equipment_events_man` | SELECT, INSERT, UPDATE, DELETE |
| `serving.refresh_downtime_events_resolved` (INVOKER: delete range + re-insert): `serving.downtime_events_resolved` | SELECT, INSERT, UPDATE, DELETE |
| cursor `ops.mirror_replay_cursor` | SELECT, INSERT, UPDATE |
| DLQ `ops.mirror_replay_dlq`, provenance `ops.legacy_manual_event_link` | SELECT, INSERT, UPDATE, DELETE |
| sequences: `core.production_orders_internal_id_order_seq` (trigger), `core.product_families_id_product_family_seq`, `silver.equipment_events_source_seq_seq`, `ops.mirror_replay_dlq_id_seq` | USAGE |
| enrich `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS`: `core.products_id_product_seq`, `core.clients_id_client_seq` (`last_value` + `setval`) | SELECT, UPDATE, USAGE |
| INVOKER functions: `public.current_tenant()`, `public.is_all_tenant()` (RLS), `core.uuidv7(timestamptz)` (`po_uuid` default), `ops.sandbox_hold_mode(int)`, `serving.refresh_downtime_events_resolved(tstz, tstz)` | EXECUTE |
| the database | CONNECT |

Not granted: DDL (the binary used to `CREATE SCHEMA ops` / `CREATE TABLE IF NOT EXISTS` its cursor, DLQ and
provenance tables at boot; that DDL is now section 1 of the migration and the code only checks the tables),
TRUNCATE, REFERENCES, TRIGGER, TEMPORARY, DELETE on `core.*` and `silver.equipment_events`, any UPDATE on
`core.equipments` / `core.topic_routing`, `identity.*`. `verify.sql` V4 pins exactly these 25
table/sequence grants (missing|extra|wrong = 0|0|0), V9 the 5 functions.

**RLS: tenant-scoped, not cross-tenant.** Each instance mirrors exactly one tenant, and every statement is
keyed on it or on its equipment. So the role has **no `app.tenant_id` default**; each DEST connection stamps
`app.tenant_id = DST_ENTERPRISE` in its startup packet (`db.DBCreds.Params`). On the FORCE-RLS tables
(`core.equipments`, `core.topic_routing`, `core.production_orders`, `gold.production_orders_runtime`,
`gold.equipment_oee_shift`, `serving.downtime_events_resolved`) a bug that addresses another tenant's row
matches nothing; a connection without the stamp sees no tenant rows (the resolver maps nothing, so nothing is
written). The refresh function is cross-tenant in shape (it deletes a whole time range), but both its DELETE
and its re-INSERT go through `serving.downtime_events_resolved`'s FORCE RLS, so a stamped caller
re-resolves only its own tenant (the golden test proves other tenants' rows survive). Not `-1` (the
all-tenant sentinel `stream_engine` uses): nothing here needs a second tenant, and `-1` would let the CPACK
instance write the sandbox tenant. Like every RLS GUC in the stack, `app.tenant_id` is user-settable: a fence
against bugs, not against a compromised process.

**Proof.**
- `verify.sql` on the dev seed: V0–V10 match; V10 shows 0 rows without the stamp, exactly tenant 3's with
  it, and TRUNCATE / DDL / DELETE on core / `identity.users` / UPDATE `core.equipments` denied.
- Golden test `TestGoldenLegacyReplicatorRoleCoversDestPath` (`-tags golden`, CI "golden fixtures"): applies
  the real migration and drives the resolver, cursor, DLQ, 13 replay categories, the PO reconciler
  (insert, converge, enrich with kept ids → `setval`), the base and manual reconcilers, the serving refresh
  and the sandbox gate as the role, plus the RLS cases and the denials.
- The real binary ran as the role on the dev seed against a throwaway Postgres carrying a synthetic legacy
  schema (only the columns the replicator selects): every replay category, DLQ capture → retry →
  success/backoff/retire, PO reconciler insert/finish/fill-start/retime/revert/converge, enrich (kept legacy
  ids + `setval`, family by sequence), base reconciler + refresh, manual reconciler insert/move/update/
  delete/adopt-link/prune + refresh. Postgres logged **0 `permission denied`**. The only DEST error, a
  `production_orders_ts_start_ts_end` CHECK on re-replaying history through a second cursor, is identical
  as the admin login.
## Configuration

### analytics-sync (`internal/config/config.go`, `cmd/shadow-mirror/main.go`)

| Name | Default | Required | Effect |
|---|---|---|---|
| `SHADOW_MIRROR_ENABLED` | `false` | no | `true` runs the replay loop; otherwise idle (health + metrics only). Staging and dev: `false` |
| `DB_HOST` / `DB_PORT` | `postgres` / `5432` | when enabled | DB server |
| `DB_USER` / `DB_PASSWORD` | — / — | when enabled | Refuses to boot if either is empty (no default user, so never the admin by accident). **Not set on staging or dev**: idle needs no DB login |
| `PG_DB_NAME` | `packiot` | no | Source DB (`user_logs`, `shadow_go_port`) |
| `PG_ANALYTICS_DB_NAME` | `packiot_analytics` | no | Second sink; empty = write `shadow_go_port` only |
| `POLL_INTERVAL_MS` / `BATCH_SIZE` | `2000` / `100` | no | Loop pacing |
| `HEALTH_PORT` | `9103` | no | HTTP listener; also read by `--healthcheck` |
| `LOG_LEVEL` | `info` | no | slog level |
| `MAX_RETRIES` | `5` | no | Loaded but **unused** |

### legacy-replicator (`internal/replicate/config.go`)

| Name | Default | Required | Effect |
|---|---|---|---|
| `REPLICATE_ENABLED` | `false` | no | Master toggle; off = idle. Staging: `true` (sbx: `REPLICATE_SBX_ENABLED`, default `false`) |
| `LEGACY_DB_HOST` / `_PORT` / `_USER` / `_NAME` | legacy prod host / `5432` / `awslambda` / `packiot40` | no | Source (SELECT-only user) |
| `LEGACY_DB_PASSWORD` | — | yes when enabled | `.env` `LEGACY_DB_PASSWORD` |
| `PG_SECRET_ID` | — | yes when enabled (unless `CREDS_SOURCE=env`) | Destination login from Secrets Manager `{host, port, user, password, name}`; empty = boot error (no admin fallback). Staging: `${LEGACY_REPLICATOR_PG_SECRET_ID:-packiot/staging/legacy-replicator-db-creds}` on both instances |
| `AWS_REGION` | `us-east-1` | no | Secrets Manager region |
| `CREDS_SOURCE` | — | no | `env` = destination login from `DEST_DB_*` instead (dev / tests only; never set on staging) |
| `DEST_DB_HOST` / `_PORT` / `_USER` / `_NAME` / `_PASSWORD` | staging DB EC2 / `5432` / `legacy_replicator` / `packiot_analytics` / — | with `CREDS_SOURCE=env` | Destination (all writes + cursor) |
| `SRC_ENTERPRISE` / `DST_ENTERPRISE` | `1` / `3` | no | Enterprise map (sbx: `DST_ENTERPRISE=2000003`) |
| `BACKFILL_SINCE_DAYS` / `BACKFILL_SINCE` | `60` / — | no | Cold-start history depth; `BACKFILL_SINCE` (RFC 3339 or `YYYY-MM-DD`) wins. An existing cursor is always kept |
| `CURSOR_SOURCE` | `legacy-cpack` | no | `ops.mirror_replay_cursor.source` key (sbx: `legacy-sbxcpack`) |
| `REPLICATE_BASE_EVENTS` | `true` | no | Replay `downtime-event-created` into `silver.equipment_events` |
| `POLL_INTERVAL_MS` / `BATCH_SIZE` | `3000` / `200` | no | Loop pacing |
| `HEALTH_PORT` | `9104` | no | HTTP listener (sbx: `9114`) |
| `HEALTHCHECK_MAX_AGE_SEC` | `0` (off) | no | `/healthz` 503 when no successful poll within N s. Staging: `600` |
| `LOG_LEVEL` | `info` | no | slog level |
| `SANDBOX_HOLD_ENABLED` | `false` | no | Every writer stands down while `ops.sandbox_held(DST_ENTERPRISE)` (sbx: `true`) |
| `RECONCILE_PO_ENABLED` / `_INTERVAL_SEC` / `_WINDOW_DAYS` | `false` / `300` / `14` | no | PO reconciler (`reconcile.go`, `reconcile_converge.go`). Staging: on |
| `RECONCILE_PO_ENRICH_ENABLED` / `_WINDOW_DAYS` | `false` / `14` | no | Copy `id_product`/`id_client` into twin POs (`enrich.go`). Staging: on, 120 days |
| `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS` | `true` | no | Create missing dimensions with legacy ids; must be `false` for the +2M sandbox |
| `RECONCILE_MANUAL_EVENTS_ENABLED` | `false` | no | Manual-event reconciler (`manual_reconcile.go`); when on, the manual-event replay handlers are not registered. Staging: on |
| `RECONCILE_MANUAL_EVENTS_INTERVAL_SEC` / `_LOOKBACK_DAYS` / `_MAX_DELETES` / `_REFRESH_SERVING` | `300` / `35` / `50` / `true` | no | Its pacing, window, delete guard and serving refresh |
| `RECONCILE_BASE_EVENTS_ENABLED` | `false` | no | Base (PLC) event reconciler (`base_reconcile.go`); also needs `REPLICATE_BASE_EVENTS`. Staging: on |
| `RECONCILE_BASE_EVENTS_INTERVAL_SEC` / `_LOOKBACK_HOURS` / `_REFRESH_SERVING` | `120` / `72` / `true` | no | Its pacing and window (staging: 96 h) |
| `EVENT_MIN_OVERLAP_SEC` / `EVENT_MAX_START_DRIFT_SEC` | `30` / `600` | no | Interval-overlap fallback matcher for justify/edit/split |
| `DLQ_CAPTURE_ENABLED` / `DLQ_RETRY_ENABLED` | `true` / `true` | no | Capture failed dispatches into `ops.mirror_replay_dlq`; retry them |
| `DLQ_RETRY_INTERVAL_SEC` / `_MAX_ATTEMPTS` / `_BATCH_SIZE` | `120` / `5` / `100` | no | DLQ retrier pacing |

Golden tests also read `DATABASE_URL` (test-only).

## Run locally

```sh
make dev SVC="analytics-sync"        # boots idle, like staging (SHADOW_MIRROR_ENABLED=false)
make dev-smoke SVC="analytics-sync"
```

`legacy-replicator` has no dev slice: it reads the legacy production DB, which has no stand-in
(`dev/README.md`, "Not in dev").

```sh
cd services/analytics-sync
go test ./...                                                     # unit tests (CI: go-services.yml)
DATABASE_URL=postgres://... go test -tags golden ./internal/replicate/   # DB-backed golden tests
```

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`)
  rebuilds both images from source.
- **Metrics** (`internal/metrics/metrics.go`; scraped as jobs `analytics-sync` :9103 and
  `legacy-replicator` :9104 in `monitoring/prometheus/prometheus.yml`):
  `shadow_mirror_dispatched_total`, `shadow_mirror_skipped_total`, `shadow_mirror_failed_total`,
  `shadow_mirror_update_noop_total` (a zero-row UPDATE = a replay gap), `shadow_mirror_cursor`,
  `legacy_replicator_reconcile_{inserted,finished,unresolved,enriched}_total`,
  `legacy_replicator_reconcile_enrich_skipped_total`, `legacy_replicator_manual_events_total{action}`,
  `legacy_replicator_base_events_total`, `legacy_replicator_dlq_retried_total`,
  `legacy_replicator_dlq_depth`. The `shadow_mirror_` prefix is kept for both binaries.
- **Alerts** (`monitoring/prometheus/rules.yml`): `ShadowMirrorFailures`
  (`increase(shadow_mirror_failed_total[15m]) > 0`) and `ReplicatorReplayGaps`
  (update no-ops on job `legacy-replicator` for 30 min).
- **Dashboards:** none of the JSON dashboards under `grafana/dashboards/` queries these metrics.
- **Failure modes:**
  - *Wedged loop* — `/healthz` 503 after `HEALTHCHECK_MAX_AGE_SEC`, Docker marks the container unhealthy.
  - *Silent no-op* — a legacy row resolves to no twin row (`shadow_mirror_update_noop_total`); usually
    an equipment without a matching PackML base topic in the twin.
  - *Missing table* (42P01) is fail-open in the replay handlers of both binaries: a dropped table
    loses writes silently. This is how manual events after 2026-09-12 were lost (the `public.`
    shim was dropped) until the manual reconciler took over.
  - *`permission denied` in the log* — a statement outside the role's grants (see § legacy-replicator database
    role). Emergency lever, no redeploy: `LEGACY_REPLICATOR_PG_SECRET_ID=packiot/staging/db` in
    `/opt/packiot/.env`, recreate both replicators; then add the grant and remove the override.
  - *Missing ops table* — the replicator no longer creates its tables: a missing `ops.mirror_replay_cursor`
    is a boot error (`read cursor … 42P01`), a missing DLQ or provenance table is logged at boot
    (DLQ capture degrades to log-only; the manual-event pass is disabled). Apply
    `t-legacy-replicator-role/01-up.sql`.
  - *Sandbox held* — `legacy-replicator-sbx` writes nothing while `ops.sandbox_held(2000003)`
    ([`docs/runbooks/sandbox-twin.md`](../../docs/runbooks/sandbox-twin.md)).
- **One-off repair:** `scripts/backfill-event-fcs-from-legacy.sh` (applied 2026-09-25; `MODE=dry` default).

## Provisioning the legacy-replicator DB role

Once per environment, **before** the compose change that points the replicators at the role is deployed (a
deploy without the secret exits at boot: `dest DB credentials: get secret …`). Staging commands; no password
leaves a host. The legacy side needs nothing.

1. **Apply the migration** on the DB host (`packiot-staging-db`), as in
   [Add a migration, steps 8–9](../../docs/wiki/build/develop/add-a-migration.md#8-dry-run-on-staging):
   - Dry-run `01-up.sql` with `COMMIT` changed to `ROLLBACK`, then apply it. Section 1 (the ops tables) is a
     no-op on staging: they exist.
   - Run `verify.sql`. Every `V` line matches its label, and `I1` is `f`.
2. **Copy `scripts/ops/provision-db-role.py`** to the app host if it is not already there.
3. **Create the secret and set the password:** `python3 /root/provision-db-role.py --service legacy-replicator`.
   - It creates `packiot/staging/legacy-replicator-db-creds` =
     `{host: 10.10.10.89, port: 5432, user: legacy_replicator, password, name: packiot_analytics}`.
   - Expect `4. login OK as legacy_replicator via 10.10.10.89/packiot_analytics (; …)` (no session default).
4. **Re-run `verify.sql`**: `I1` is now `t`.
5. **Merge and deploy.** "Deploy to Staging" recreates both replicators with no `.env`; their tuning keys still
   arrive through the explicit pass-through block, and `LEGACY_DB_PASSWORD` is still interpolated by compose.
6. **Verify, in the first 15 minutes** (both containers):
   - `docker logs legacy-replicator 2>&1 | grep 'pool ready'` shows `"user":"legacy_replicator"` for
     `legacy-replicator-dst` and `"user":"awslambda"` for `legacy-replicator-src` (unchanged).
   - `docker logs --since 15m legacy-replicator 2>&1 | grep -c 'permission denied'` returns `0` (same for `-sbx`).
   - The pass logs keep appearing (`PO reconcile pass done`, `base-event reconcile pass done`,
     `manual-event reconcile pass done`) and `shadow_mirror_cursor` keeps moving.
   - On the DB host,
     `SELECT usename, count(*) FROM pg_stat_activity WHERE application_name = 'legacy-replicator-dst' GROUP BY 1;`
     lists only `legacy_replicator`.
   - `docker inspect legacy-replicator --format '{{json .Config.Env}}' | grep -c -E 'POSTGRES_(USER|PASSWORD)|RABBITMQ_(USER|PASSWORD)'`
     returns `0`.

**Emergency rollback (no redeploy):** `LEGACY_REPLICATOR_PG_SECRET_ID=packiot/staging/db` in
`/opt/packiot/.env`, then `docker compose -f compose.staging.yml -p stack up -d --force-recreate legacy-replicator legacy-replicator-sbx`
(the admin login ignores the tenant stamp: superuser bypasses RLS). **Full rollback:** revert the compose change
and redeploy, then run `rollback.sql`. **Rotate:** `provision-db-role.py --service legacy-replicator --rotate`,
then recreate both containers. **Production** has no legacy-replicator.

## prod-reflector (ADR-0064)

After a tenant's production go-live, staging keeps it as a **read-only mirror of production**. `cmd/prod-reflector`
(`internal/mirror`) is a **state reflector**, not an action replayer: both databases share the schema and the ids, so
every minute it converges staging's rows of the tenant to production's, table by table, production always wins.

- **What:** `internal/mirror/spec.go` — `Reflected` (production owns: hierarchy, topics, device keys, descriptors,
  reasons, shifts, products, targets, users/roles, POs + runtime, events + justifications, box scans, samples, gold,
  live views; FK order) and `Local` (staging keeps: its own reader's raw series, its audit log, invariants, customer
  exports). A tenant-keyed table in neither list is reported (MR5), never touched.
- **How:** per table and UTC-day bucket, `count + md5` of the tenant's rows on both sides (production in one REPEATABLE
  READ READ ONLY snapshot); only differing buckets are fetched; upsert by primary key (self-references set after the
  rows exist), delete what production no longer has (children first, literal keys), replace whole buckets for tables
  without a key; then read back in the same transaction. Hot passes look 35 days back, a full pass every 6 h.
  Only columns present on both sides are mirrored. `core.enterprises.api_key` is never copied; the name becomes
  production's + `" (mirror)"`. `bronze.box_scans` is append-only.
- **Guards:** a production without the enterprise aborts the pass; `empty_source` (production returns no rows for a
  table staging has) and `max_deletes` refuse deletes; each table converges in its own savepoint.
- **Detector:** a row the reflector wrote that changed again on staging while production did not →
  `prod_reflector_staging_writes_total` (a write surface the block missed).
- **Invariants** every 15 min into `ops.data_invariant_result` (source `prod-reflector`): MR1 config equal, MR2 POs equal,
  MR3 lag, MR4 id blocks (production ≥ `PROD_ID_BLOCK`, staging below), MR5 unclassified tables.

| Name | Default | Effect |
|---|---|---|
| `PROD_MIRROR_ENTERPRISES` | — | the switch (shared with edge-api, barcode-service, stream-engine); empty = idle, no DB connection |
| `PROD_REFLECT_DRY_RUN` | `false` | full passes, then ROLLBACK; invariants logged, not recorded |
| `SRC_SECRET_ID` / `PG_SECRET_ID` | — | production login (`prod_reflector_ro`) / staging login (`prod_reflector`), Secrets Manager; `CREDS_SOURCE=env` reads `SRC_DB_*` / `DEST_DB_*` (dev/tests) |
| `PROD_REFLECT_INTERVAL_SEC` / `_FULL_EVERY_HOURS` / `_LOOKBACK_DAYS` | `60` / `6` / `35` | pacing |
| `PROD_REFLECT_MAX_DELETES` | `2000` | per table per pass |
| `PROD_REFLECT_NAME_SUFFIX` | `" (mirror)"` | staging enterprise name suffix |
| `PROD_ID_BLOCK` | `1000000000` | MR4 threshold |
| `PROD_REFLECT_INVARIANT_EVERY_MIN` / `_MAX_LAG_SEC` | `15` / `600` | MR cadence / MR3 bound |
| `HEALTH_PORT` / `HEALTHCHECK_MAX_AGE_SEC` | `9124` / `0` | `/healthz` (503 when no pass completed in N s), `/metrics` |

Roles: `db/migrations/t-prod-reflector-roles` (both sides). Runbook: `docs/runbooks/staging-mirror-of-production.md`.
Tests: `go test ./internal/mirror/` (unit; includes the spec ↔ migration grant list check) and
`-tags golden` (two real databases, the real migration's roles: convergence, api key kept, name suffix, self-FK order,
other tenant untouched, serving refresh, staging-write detector, append-only, dry run, empty-source guard, MR4).

## Code layout

| Path | What |
|---|---|
| `cmd/shadow-mirror/` | `analytics-sync` entrypoint (idle mode, handler registration, HTTP) |
| `cmd/legacy-replicator/` | `legacy-replicator` entrypoint (pools, handlers, reconcilers, DLQ retrier) |
| `cmd/prod-reflector/`, `internal/mirror/` | `prod-reflector` (ADR-0064): config, spec (reflected/local tables), catalog, plan (SQL), diff, pass, invariants |
| `internal/config/` | analytics-sync env config |
| `internal/replay/` | cursor, dispatcher, loop; `handlers/` per `user_logs` category |
| `internal/replicate/` | legacy-replicator: config, resolver (id map), handlers, loop, cursor, `dlq.go`, `reconcile*.go` (POs), `enrich.go`, `manual_reconcile.go`, `base_reconcile.go`, `hold.go`, `flexnum.go` |
| `internal/db/`, `internal/health/`, `internal/log/`, `internal/metrics/` | pgx pools, liveness, slog, Prometheus registry |
| `Dockerfile`, `Dockerfile.replicator`, `Dockerfile.reflector` | one image per binary |
| `scripts/` | one-off legacy backfill |

## Related docs

- [ADR-0013 — shadow-mirror service](../../docs/adr/0013-shadow-mirror-service.md)
- [ADR-0012 — schema refactor and multi-tenancy pool](../../docs/adr/0012-schema-refactor-and-multitenancy-pool.md)
- [ADR-0060 — local development environment](../../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md)
- [ADR-0062 — production-order identity](../../docs/adr/0062-production-order-identity-and-alphanumeric-numbers.md)
- [Runbook: sandbox twin](../../docs/runbooks/sandbox-twin.md)

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [analytics-sync](https://wiki.packiot.app/understand/components/analytics-sync/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
