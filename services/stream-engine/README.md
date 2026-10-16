# stream-engine

The new stack's OEE engine: consumes decoded SparkPlug envelopes from RabbitMQ, writes Bronze and
Silver in the analytics DB, and runs the scheduled jobs that compute Gold OEE, events, production-order
runtime, UNS live tables and customer reports.

## What it does

stream-engine has two halves in one process. The **ingest consumer** reads envelopes from the `oee`
exchange (one queue per tenant plus a firehose queue), resolves each metric's topic to an equipment
through `packml_register` (cached), and writes one `pgx.Batch` per delivery: `silver.equipment_values`
upserts keyed on `(ts_value, id_equipment)`, `bronze.equipment_values_raw` appends, event mints for
`status_type = 4` state metrics, live metrics, and PO-control parameters. The **scheduled jobs** (about
15 ticker loops, each behind a flag) recompute `gold.equipment_oee_*` grains from Silver, the continuous
aggregates and `silver.equipment_events`, derive and close events, compute PO runtime, refresh UNS live
tables and write customer report pools. It began as a port of the legacy Node-RED `oeecloud` flow and the
PL/pgSQL OEE engine (ADR-0014). Its old name, `oeecloud-worker`, survives in the main package
(`cmd/oeecloud-worker`), the network alias, the Prometheus job and the metric prefix.

## Where it fits

```text
sparkplug-decoder ──▶ RabbitMQ `oee`  (keys sparkplug.data.<tenant>, sparkplug.data)
                          │  stream-engine-q-<tenant> (+ -retry-30s, -failed), stream-engine-q
                          ▼
                     stream-engine ──▶ analytics DB packiot_analytics (direct to the DB host)
                          │             bronze.* (raw) · silver.* (values, events, live) ·
                          │             gold.* (OEE grains, PO runtime) · core.* · customer_reports.*
                          ▼
         read-api, Superset, Grafana, historian live tier read Silver/Gold
```

## Status and environments

| Environment | Where | Image | Ports | Health |
|---|---|---|---|---|
| dev (ADR-0060) | `dev/services/stream-engine.yml` · `stream-engine` (`LEGACY_INGEST_ENABLED=false`, firehose queue only) | built from `services/stream-engine/Dockerfile` (Go 1.25 → distroless) | 9101 in-network | `GET /health` |
| staging | `compose.staging.yml` · `stream-engine` (no profile), IP 172.18.0.20, alias `oeecloud-worker`; waits for `db-migrate` | same, built on deploy, entrypoint `/usr/local/bin/stream-engine` | 9101 in-network | `GET /health`; healthcheck `stream-engine --healthcheck` |
| production | defined in `compose.production.yml` · `stream-engine` (no profile; fewer jobs on); new-stack production is not promoted | same | 9101 | same |

Subcommands: `--healthcheck` (container probe) and `--identity-sentinel` (deploy gate: no
`running_time` above the bucket span for `BAKE_ENTERPRISE_IDS`).

## Interfaces

### HTTP

No OpenAPI spec (no API beyond ops).

| Method | Path | Auth | What |
|---|---|---|---|
| GET | `/health` | none | consumer snapshot + writer stats; healthy = AMQP connection up |
| GET | `/metrics` | none | Prometheus |

### Messaging

Topology is declared in code at boot (`internal/amqp/topology.go`); queue arguments are immutable, so
`dev/rabbitmq/definitions.dev.template.json` must match it.

| Exchange (topic) | Queue | Binding |
|---|---|---|
| `oee` | `stream-engine-q` (firehose) | `sparkplug.data` (exact; the old `#` binding is removed at boot) |
| `oee` | `stream-engine-q-<tenant>` per discovered tenant | `sparkplug.data.<tenant>` |
| `oee-retry` | `…-retry-30s` (TTL `RETRY_TTL_MS`, dead-letters back to `oee`) | same keys |
| `oee-failed` | `…-failed` | after `MAX_RETRIES` |

Tenants are discovered from active `packml_register` topics (first segment, lowercased), intersected
with `WORKER_TENANT_ALLOWLIST`, at boot and every `TENANT_DISCOVERY_INTERVAL_SECONDS`. **Per-tenant
queues are consumed only when `LEGACY_INGEST_ENABLED=true`** (the name is historical); with staging's
per-tenant routing, turning it off stops ingest. Each queue has `CONSUME_LANES` consumers.
`source_type` selects the destination: `refactored` → the analytics pool; `""` → the main pool
(`public`, the single-flow production shape); `go` is acked and dropped.

### Database

All in the analytics DB `packiot_analytics` on staging (both pools point there). Ingest writes
`silver.equipment_values`, `bronze.equipment_values_raw` (`BRONZE_RAW_APPEND`),
`silver.equipment_events` and `bronze.equipment_events_raw` (state mints), `silver.equipment_live_metrics`,
PO lifecycle tables (`core.production_orders`, `gold.production_orders_runtime`,
`silver.equipment_live_job`, `identity.user_logs`) for parameters 30700/30800-series/30810–30814/…
when `PO_CONTROL_ENABLED`, and `silver.data_quality_event`. Jobs read the caggs
(`silver.equipment_categorical_1min/_1hour`, `silver.ca_discrete_changes_1s`) and write
`gold.equipment_oee_{hourly,daily,weekly,monthly,shift}`, `gold.area_oee_*`, `gold.site_oee_shift`,
`silver.equipment_live_*`, `silver.area_live_*` and `customer_reports.*`. Reads `packml_register`,
`areas`, `equipments`, `sites`, `shift_hours`, `client_descriptors` (line-lead profile). At boot it starts
the TimescaleDB scheduler (`_timescaledb_functions.start_background_workers()`, through the wrapper below).

#### Database role

Staging logs in as the least-privilege **`stream_engine`** role
([`db/migrations/t-stream-engine-role/`](../../db/migrations/t-stream-engine-role/)), never the Postgres
admin. NOSUPERUSER, NOBYPASSRLS, NOINHERIT, owns nothing.

| What the engine does | Privilege |
|---|---|
| reads dimensions and caggs: `core.{enterprises,sites,areas,shifts,shift_hours,shifts_exception_period,client_descriptors,box_production_bridges,downtime_reason,equipment_downtime_reason,equipment_validation_shift,po_number_corrections}`, `config.{label_formats,production_targets,equipment_out_of_service}`, `silver.{equipment_categorical_1min/1hour,agg_equipment_values_1min/1hour,ca_discrete_changes_1s,plc_endpoint_equipment,plc_link_minutes}` | SELECT |
| inferspeed (`core.equipments`), 30700 topology (`core.packml_register` view → `core.topic_routing`) | SELECT, UPDATE |
| PO control 30800–30805 (`core.production_orders`, `products`, `product_families`, `clients`) | SELECT, INSERT, UPDATE |
| ingest + live tables (`silver.equipment_values`, `equipment_events_man`, `data_quality_event`, `equipment_live_*`, `area_live_*`) | SELECT, INSERT, UPDATE |
| event deriver / CPAC deriver rewrite windows (`silver.equipment_events`, `equipment_events_cpac_shadow`) | SELECT, INSERT, UPDATE, DELETE |
| gold grains + `gold.production_orders_runtime` (provision + rollups) | SELECT, INSERT, UPDATE |
| bronze raw append, `identity.user_logs` | INSERT |
| customer reports (`production_data_sync`, `sap_data_sync`, `boxes`; `shift` is delete-and-reinsert) | SELECT, INSERT, UPDATE / SELECT, INSERT, DELETE |
| sequences behind serial INSERT targets (9, incl. `core.production_orders_internal_id_order_seq` used by the PO-number trigger) | USAGE |
| rollup temp tables (`ON COMMIT DROP`, indexed, `ANALYZE`d) | TEMPORARY on the database |
| INVOKER engine functions: `public.piot_get_*` (6), `public.piot_create_*` (11), `serving.data_sync`, `serving.report_shift`, `core.try_int4/8`, the RLS helpers | EXECUTE |
| the one superuser-only call, `_timescaledb_functions.start_background_workers()` | EXECUTE on the SECURITY DEFINER wrapper `public.ensure_timescaledb_workers()` (no args, pinned `search_path`, does only that, granted to `stream_engine` alone) |

Not granted: DDL, TRUNCATE, REFERENCES, TRIGGER, COPY, `identity.users`, anything in `ops`. None of
the engine's SQL needs them (no cagg refresh, compress/decompress, jobs API, `SET ROLE` or
`session_replication_role` in the shipped binary). `SET LOCAL
timescaledb.max_tuples_decompressed_per_dml_transaction`, `SET statement_timeout` and `SET search_path` are
user-settable, and DML on compressed chunks needs only the hypertable's grants.

**RLS.** The engine is cross-tenant by design: every loop walks all enterprises and ingest writes any
tenant. Instead of BYPASSRLS, the role is NOBYPASSRLS with a role-level default
`app.tenant_id = '-1'`, the all-tenant sentinel (`is_all_tenant()`), as `histgw_ro` already uses. The
reach is the same, but every policy is still evaluated, so a future policy without the sentinel fails
closed for the engine instead of being skipped.

**Proof.** `verify.sql` pins the exact grant set (V4: 69 table and sequence grants, missing/extra/wrong
= 0|0|0). The real binary ran as the role on the dev seed with every loop staging enables, plus the
report jobs, CPAC (shadow + live), boxes, widerow events and legacy ingest:
- Every job tick was `ok` (`provisional-speed-inference` fails the same way as the admin login, on
  a seed column it does not have).
- Ingest wrote silver and bronze rows.
- Published PO-control parameters ran: 30805, 30800, 30801, 30810–30814, 30820, 30861, 30862 and 30880.
  30700 failed on a seed data NOT NULL, the same as the admin login.

That run found two grants the static inventory missed: the PO-number trigger's sequence and its
`core.po_number_corrections` lookup, both now granted. In CI, the dev-slices "pipeline" slice runs the
engine as the role.

## Configuration

Every name below is read by `internal/config/config.go`, `internal/secrets/` or `internal/tracing/`.
Booleans are on only when exactly `true`. Staging values are in `compose.staging.yml`.

**Connectivity and ingest**

| Name | Default | Effect |
|---|---|---|
| `CREDS_SOURCE` | unset | `env` = `DB_*` / `RABBITMQ_USER`/`RABBITMQ_PASSWORD` from env (dev only; staging leaves it unset) |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | `postgres`, `5432`, `packiot`, –, – | DB in env mode (user/password required; dev: `stream_engine` / `dev`) |
| `AWS_REGION`, `PG_SECRET_ID`, `RABBITMQ_SECRET_ID` | `us-east-1`, **none** (empty = boot error, never the admin `packiot/staging/db`), `packiot/staging/rabbitmq-stream-engine-creds` | Secrets Manager ids. Staging `PG_SECRET_ID` = `${STREAM_ENGINE_PG_SECRET_ID:-packiot/staging/stream-engine-db-creds}` (`stream_engine` role) |
| `RABBITMQ_HOST`, `RABBITMQ_PORT` | `rabbitmq`, `5672` | broker |
| `POSTGRES_ANALYTICS_DB_NAME` | empty | analytics pool DB; empty = `refactored` routes to the main pool |
| `POSTGRES_MAX_CONNS`, `POSTGRES_ANALYTICS_MAX_CONNS` | `5`, `15` | pool sizes |
| `SOURCE_EXCHANGE`, `WORKER_QUEUE`, `RETRY_EXCHANGE`, `RETRY_QUEUE`, `FAILED_EXCHANGE`, `FAILED_QUEUE` | `oee`, `stream-engine-q`, `oee-retry`, `stream-engine-q-retry-30s`, `oee-failed`, `stream-engine-q-failed` | topology names |
| `RETRY_TTL_MS`, `MAX_RETRIES`, `PREFETCH`, `CONSUME_LANES` | `30000`, `5`, `50`, `1` | retry and concurrency (staging lanes `4`) |
| `LEGACY_INGEST_ENABLED` | `true` | consume per-tenant queues (see Messaging) |
| `WORKER_TENANT_ALLOWLIST` | empty = all | staging `cpack,sbxcpack,bispharmastaging,incoplast` |
| `TENANT_DISCOVERY_INTERVAL_SECONDS` | `60` | re-discovery cadence |
| `WORKER_POOL_SAC_ENABLED` | `false` | single-active-consumer queues (changes queue args) |
| `BIRTHBIND_VERIFY` | `true` | ADR-0061 D7 count-only verification of birth-bound ids |
| `BIRTHBOUND_SWITCHED_ENTERPRISES` | empty | enterprises whose counters resolve by the decoder's birth-bound id |
| `BRONZE_RAW_APPEND` | `false` | Bronze append (staging on) |
| `COUNTER_TOTALS_PUBLIC` | `false` | also write float8 `*_total` columns on the `public` route |
| `SHIFT_RESOLVER_ENABLED`, `SHIFT_FILL_FOLDED` | `false`, `false` | Go shift fill; fold shift columns into the upsert (staging both on) |
| `INCREMENT_SANITY_CLAMP_ENABLED`, `INCREMENT_SANITY_CLAMP_K`, `INCREMENT_SANITY_CLAMP_MIN_DT_SECONDS`, `INCREMENT_SANITY_CLAMP_SPIKE_FLOOR`, `INCREMENT_SANITY_CLAMP_SPIKE_FRACTION` | `false`, `4.0`, `60`, `1000`, `0.5` | ADR-0037 Silver increment clamp (staging on) |
| `HEALTH_PORT`, `LOG_LEVEL` | `9101`, `info` | |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER_ARG` | unset, `1.0` | tracing (staging Tempo) |

**Rollups and OEE**

| Name | Default | Effect |
|---|---|---|
| `RUNTIME_ROLLUP_ENABLED` | `false` | the 1-min grain cascade (hour → day → shift → week/month → area/site → DQ → clamp) |
| `ROLLUP_BACKFILL_ENABLED`, `ROLLUP_BACKFILL_INTERVAL_SECONDS`, `ROLLUP_BACKFILL_LIMIT` | `true`, `30`, `200` | flagged-hour backfill (staging 7 s, 50) |
| `ROLLUP_SHIFT_LIMIT` | `300` | most shift rows per tick (staging 75); the batch adapts below it |
| `ROLLUP_SHIFT_BUDGET_SECONDS`, `ROLLUP_BACKFILL_BUDGET_SECONDS` | `120`, `120` | a shift / backfill batch over its budget rolls back alone and the next is halved (`rollup/batch.go`) |
| `ROLLUP_MACHINE_LEVEL_ENTERPRISES` | `6` | enterprises whose machines join the shift grain |
| `RUNTIME_PROVISION_ENABLED`, `RUNTIME_PROVISION_INTERVAL_HOURS` | `false`, `6` | pre-create future grain rows |
| `DQ_ALARMS_ENABLED`, `SILVER_CLAMP_ENABLED` | `true`, `true` | data-quality events; clamp served Gold to invariants (each change logged as a DQ event) |
| `CHANGEOVER_AVAILABILITY_ENABLED` | `false` | count changeover as availability loss |
| `AVAILABILITY_EXCLUSIONS_ENABLED` | `true` | subtract out-of-service windows and PLC no-data time |
| `OEE_AVAIL_FLOOR_ENABLED`, `OEE_CANONICAL_APQ_ENABLED` | `false`, `false` | ADR-0049 availability floor; store `oee = A·P·Q` (staging both on) |
| `COUNTERS_ONLY_AVAILABILITY_ENABLED`, `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS`, `COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS` | `false`, empty, `300` | availability from count activity for state-less machines |
| `COUNTERS_ONLY_LINE_LEAD_ENABLED`, `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` | `false`, empty | line-lead pass (staging `3,5,2000003`); descriptors can add enterprises |
| `PROVISIONAL_SPEED_INFERENCE_ENABLED`, `PROVISIONAL_SPEED_EQUIPMENTS`, `PROVISIONAL_SPEED_WINDOW_HOURS`, `PROVISIONAL_SPEED_MIN_MINUTES`, `PROVISIONAL_SPEED_PERCENTILE`, `PROVISIONAL_SPEED_FLOOR` | `false`, empty, `72`, `240`, `0.95`, `1.0` | infer `production_speed` for opted-in lines |
| `STRANDED_FLAG_SWEEP_ENABLED` | `true` | hourly clear of `recalc_needed` flags no job can drain |
| `BAKE_ENTERPRISE_IDS` | `3` | enterprises checked by `--identity-sentinel` |

**Events, production orders, UNS, reports**

| Name | Default | Effect |
|---|---|---|
| `EVENTS_DERIVER_ENABLED`, `EVENTS_DERIVER_INTERVAL_MINUTES` | `false`, `1` | `status_type = 4` state → interval events |
| `EVENTS_EXCLUDED_AREAS`, `EVENTS_EXCLUDED_ENTERPRISES`, `EVENTS_WIDEROW_STATE_ENTERPRISES` | empty | deriver scope (staging wide-row: `4`) |
| `CPAC_EVENT_DERIVATION_ENABLED`, `CPAC_EVENT_DERIVATION_INTERVAL_MINUTES`, `CPAC_EVENT_ENTERPRISES`, `CPAC_EVENT_LIVE_ENTERPRISES`, `CPAC_STOP_THRESHOLD_DEFAULT_SEC`, `CPAC_EVENT_TARGET_TABLE` | `false`, `1`, empty, empty, `300`, `equipment_events_cpac_shadow` | count-silence stop deriver (shadow table, or live for the live list; staging live `5`) |
| `EVENTS_CLOSE_STALE_ENABLED`, `EVENTS_CLOSE_STALE_ENTERPRISES`, `EVENTS_CLOSE_STALE_INTERVAL_SEC`, `EVENTS_CLOSE_STALE_THRESHOLD_DEFAULT_SEC`, `EVENTS_CLOSE_STALE_HORIZON_HOURS`, `EVENTS_CLOSE_STALE_LONG_HORIZON_DAYS` | `false`, empty, `60`, `300`, `72`, `60` | close stale open events (staging `3,4,5,2000003`) |
| `PO_CONTROL_ENABLED` | `false` | PackML 30800-series PO lifecycle on ingest |
| `PO_RECALC_ENABLED`, `PO_RECALC_INTERVAL_MINUTES`, `PO_RECALC_WINDOW`, `PO_RECALC_EXCLUDED_ENTERPRISES`, `PO_RECOMPUTE_SWEEP_HOURS` | `false`, `1`, `1 month`, `6`, `24` | PO runtime compute + headline OEE; periodic recompute of closed POs |
| `PO_AVAILABILITY_ENABLED` | `false` | PO-grain availability/performance (staging on) |
| `UNS_REFRESH_ENABLED`, `UNS_INTERVAL_MINUTES`, `UNS_CURRENT_METRICS_ENABLED`, `UNS_CURRENT_METRICS_INTERVAL_MINUTES` | `false`, `5`, `false`, `1` | UNS live tables |
| `SHIFT06_REPORT_ENABLED`, `SHIFT06_INTERVAL_MINUTES`, `SHIFT06_CUSTOMER_ID` | `false`, `15`, `6` | enterprise 6 shift report |
| `SAP13_REPORT_ENABLED`, `SAP13_INTERVAL_MINUTES`, `SAP13_CUSTOMER_ID`, `SAP13_REASONS_FROM_DIM` | `false`, `15`, `13`, `false` | enterprise 13 SAP sync |
| `SYNC06_REPORT_ENABLED`, `SYNC06_INTERVAL_MINUTES`, `SYNC06_ENTERPRISE_ID` | `false`, `15`, `6` | enterprise 6 data sync |
| `BOXES13_REPORT_ENABLED`, `BOXES13_INTERVAL_MINUTES`, `BOXES_BRIDGE_ENABLED` | `false`, `5`, `false` | box-scan aggregation and box → count bridge |

`cmd/port-parity` reads `PARITY_DSN`.

## Run locally

```sh
make dev SVC="seed-replay stream-engine"     # replay → decoder → stream-engine (+ read-api)
make dev-smoke SVC="stream-engine"           # fresh silver rows at "now"
cd services/stream-engine && go test ./...
DATABASE_URL=postgres://… go test -tags golden -run Golden ./internal/rollup/ ./internal/events/ ./internal/pocontrol/
```

The golden tests run verified SQL against an ephemeral Postgres (CI job "stream-engine — golden
fixtures" in `.github/workflows/go-services.yml`); a test failing because you "fixed" legacy behaviour
is working as intended — change the port and its golden together. `dev/e2e/replay-parity.sql` checks
replayed gross against the seed. `cmd/port-parity` renders legacy-vs-Go diff SQL; `cmd/recompute-render`
renders the history-recompute SQL from the current code (see the runbook below).

## Provisioning the DB role

Once per environment, **before** the compose change that points the engine at the role is deployed (a
deploy without the secret exits at boot: `fetch db secret failed`). This is the OEE engine for every
tenant, so do it in a quiet window and watch step 6. Staging commands; no password leaves a host.

1. **Apply the migration** on the DB host (`packiot-staging-db`), as in
   [Add a migration, steps 8–9](../../docs/wiki/build/develop/add-a-migration.md#8-dry-run-on-staging):
   - Dry-run `01-up.sql` with `COMMIT` changed to `ROLLBACK`, then apply it.
   - Run `verify.sql`. Every `V` line matches its label, and `I1` is `f`.
   - V10 runs as the role inside `BEGIN … ROLLBACK`: a cross-tenant read through FORCE RLS, the
     wrapper, and the TRUNCATE/DDL/DELETE denials.
2. **Copy `scripts/ops/provision-db-role.py`** to the app host (`base64 -w0`, as in the barcode-service
   README), unless it is already there.
3. **Create the secret and set the password:** `python3 /root/provision-db-role.py --service stream-engine`.
   - It creates `packiot/staging/stream-engine-db-creds` =
     `{host: 10.10.10.89, port: 5432, user: stream_engine, password, name: packiot_analytics}` (direct, like
     today).
   - It sets the SCRAM verifier, then logs in as the role.
   - Expect `4. login OK as stream_engine via 10.10.10.89/packiot_analytics (app.tenant_id=-1; …)`.
4. **Re-run `verify.sql`**: `I1` is now `t`.
5. **Merge and deploy.** "Deploy to Staging" recreates `stream-engine` with no `.env`. Its own tuning keys
   from `.env` (`CPAC_EVENT_*` and the rest) still arrive through the explicit pass-through block.
6. **Verify, in the first 15 minutes:**
   - `docker logs stream-engine 2>&1 | grep -E 'secrets fetched|background workers'` shows
     `postgres://stream_engine:***@10.10.10.89…` and `ensured … background workers are running`.
   - `docker logs --since 15m stream-engine 2>&1 | grep -c 'permission denied'` returns `0`.
   - `oeecloud_worker_job_ticks_total{outcome="error"}` stays flat, and `EngineJobErrorStreak` and
     `WritePathDry` stay quiet.
   - Fresh `silver.equipment_values` rows arrive per tenant.
   - On the DB host, `SELECT usename, count(*) FROM pg_stat_activity WHERE application_name LIKE 'oeecloud-worker%' GROUP BY 1;`
     lists only `stream_engine`.
   - `docker inspect stream-engine --format '{{json .Config.Env}}' | grep -c -E 'POSTGRES_(USER|PASSWORD)|RABBITMQ_(USER|PASSWORD)'`
     returns `0`.

**Emergency rollback (no redeploy):** set `STREAM_ENGINE_PG_SECRET_ID=packiot/staging/db` in
`/opt/packiot/.env`, then run `docker compose -f compose.staging.yml -p stack up -d --force-recreate stream-engine`.
The engine is back on the admin login. Fix the grant, then remove the override. **Full rollback:** revert the
compose change and redeploy, then run `rollback.sql`. **Rotate:** `provision-db-role.py --service stream-engine
--rotate`, then recreate the container. **Production** still runs the pre-split `public` layout as
`packiot/production/db` and is unchanged here. Its role belongs to the production promotion: the transplant
makes it the analytics layout, and this migration applies there as-is.

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`), which
  also runs the `--identity-sentinel` int-overflow gate ("F3 int-overflow sentinel" step).
- **Metrics** (Prometheus job `oeecloud-worker`): `oeecloud_worker_amqp_deliveries_total{routing_key,result}`,
  `oeecloud_worker_handler_duration_seconds`, `oeecloud_worker_batch_writes_total{dest,tenant,result}`,
  `oeecloud_worker_job_ticks_total{job,outcome}`, `packml_unresolved_topic_total{tenant}`,
  `oeecloud_worker_birthbind_verify_total`, `oeecloud_worker_birthbound_resolve_total`,
  `oeecloud_worker_po_control_ops_total`, `oeecloud_worker_writer_po_parameter_ops_total`.
  Dashboards: `library/04-engine.json`, `audience/00-overview.json`, `audience/01-cs-client-health.json`,
  `audience/03-pipeline-data.json`, `audience/04-ingest-debug.json`, `library/16-database-dbm.json`.
- **Alerts** (`monitoring/prometheus/rules.yml`): `EngineJobErrorStreak`, `StreamEngineJobStalled`,
  `EngineStalled`, `IngestSilent`, `WritePathDry`, `BatchWriteErrors`, `ClientIngestStopped`,
  `PackmlUnroutableTopic`, `BirthBindVerifyMismatch`.
- **Rules learned the hard way:** one writer per row (two writers caused the line double count #456 and
  the mint/deriver overflow); new behaviour ships behind a default-off flag; pools use the simple
  protocol; re-flag history only within the engine windows (hour backfill 10 days, shift line-lead 25 days) — use the
  history-recompute runbook beyond that; a slow shift tick rolls back the whole shift transaction, so
  keep `ROLLUP_SHIFT_LIMIT` bounded.

## Code layout

| Path | What |
|---|---|
| `cmd/oeecloud-worker/` | main: pools, topology, consumers, job wiring, subcommands |
| `cmd/port-parity/`, `cmd/recompute-render/` | parity harness, history-recompute SQL renderer |
| `internal/amqp/`, `internal/handlers/`, `internal/tenants/` | topology, consumer lanes, dispatcher + SparkPlug handler, tenant discovery |
| `internal/sparkplug/`, `internal/writers/` | envelope parse + topic resolver; Silver/Bronze/PO/UNS SQL builders, increment clamp |
| `internal/rollup/` | OEE grains, backfill, provision, PO compute/recalc, availability, line-lead, DQ, clamps |
| `internal/events/`, `internal/pocontrol/`, `internal/shiftresolver/` | event derivers and closer, PO state machine, shift fill |
| `internal/uns/`, `internal/reports/` | UNS live tables, customer report writers |
| `internal/jobs/`, `internal/flows/`, `internal/oeeprofile/`, `internal/birthverify/`, `internal/bake/` | ticker loop, destinations, line-lead profile, ADR-0061 verification, identity sentinel |
| `internal/config/`, `internal/secrets/`, `internal/db/`, `internal/health/`, `internal/metrics/`, `internal/tracing/` | plumbing |
| `docs/` | worker-pool strategies, per-tenant queues, tenant onboarding |
| `scripts/` | `parity-check.sql`, `migrate-tenant-queues-sac.sh` |

## Related docs

- [docs/onboarding-new-tenant.md](docs/onboarding-new-tenant.md),
  [docs/strategy-c-per-tenant-queues.md](docs/strategy-c-per-tenant-queues.md),
  [docs/strategy-d-shared-pool-sac.md](docs/strategy-d-shared-pool-sac.md)
- [History recompute runbook](../../docs/runbooks/history-recompute.md)
- [ADR-0014 extract OEE math to the app](../../docs/adr/0014-extract-oee-math-from-database-to-app.md)
- [ADR-0032 collapse to single flow](../../docs/adr/0032-collapse-to-single-flow-f3.md)
- [ADR-0036 medallion](../../docs/adr/0036-data-architecture-medallion.md)
- [ADR-0037 OEE correctness remediation](../../docs/adr/0037-oee-correctness-remediation.md)
- [ADR-0049 OEE correctness](../../docs/adr/0049-oee-correctness.md)
- [ADR-0061 remove PackML from the cloud](../../docs/adr/0061-remove-packml-from-the-cloud.md)
- [`docs/PORTING.md`](../../docs/PORTING.md) — port rules

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [stream-engine](https://wiki.packiot.app/understand/components/stream-engine/) |
| Rollup internals | [stream-engine rollup internals](https://wiki.packiot.app/understand/components/stream-engine-rollup-internals/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
