# historian-gateway

A Postgres query gateway (pg_duckdb + postgres_fdw) that serves hot analytics-DB rows and the cold
S3 Parquet historian as one set of relations, so read-api, Superset and SQL tools can query any
time range with plain SQL.

## What it does

The gateway is the stock `pgduckdb/pgduckdb:16-main` image plus one init script
(`docker-entrypoint-initdb.d/10-historian-gateway.sh`); there is no application code. The init
builds, in database `packiot_historian`: foreign tables in schema `live` over the analytics DB
(postgres_fdw), cold-source views in schema `cold` over `s3://<HISTORIAN_BUCKET>/…/*-legacy.parquet`
(pg_duckdb `read_parquet`), and union views `silver.equipment_values`, `silver.equipment_events`
and `silver.production_orders`. A per-enterprise boundary keeps the two sides disjoint (cold owns
time up to the cutover, hot owns time after it), and an allow-list (`promoted_enterprise`) decides
which tenants get cold rows at all. It is a separate container because pg_duckdb is a glibc build
and the analytics DB image is Alpine/musl, and because heavy archive scans must stay off the OLTP
database.

## Where it fits

```text
 legacy DB packiot40 ── nightly copy (systemd timer, scripts/historian-*.sh) ──▶ S3 historian bucket
                                                                                 *-legacy.parquet
 read-api /v1/historian/*  ─┐                                                         ▲ pg_duckdb
 Superset historian_union  ─┼─ SQL ──▶ hist-gateway :5432 (packiot_historian) ─────────┘
 CloudBeaver (read-only)   ─┘          silver.* = live ∪ cold                ─ postgres_fdw ─▶
                                                                    analytics DB packiot_analytics
```

## Status and environments

| Environment | Where (compose file · service · profile) | Image | Ports | Health |
|---|---|---|---|---|
| dev | none: needs an S3 endpoint option and a cold archive in MinIO (`dev/README.md`, "Not in dev") | — | — | — |
| staging | `compose.historian-gateway.yml` · `historian-gateway` (container `hist-gateway`) on the external network `stack_packiot-net`; started by hand, **not** by the deploy workflow | `pgduckdb/pgduckdb:16-main` | in-network 5432; no host publish | `pg_isready -U postgres`; `start_period` 20 min (first boot seeds the cutover by scanning the archive) |
| production | not in `compose.production.yml` | — | — | — |

Limits (2026-09-28 audit): `mem_limit: 2560m`; DuckDB `memory_limit`/`max_memory` 1024 MB,
`threads` 2, `max_temp_directory_size` 8 GB, set as `postgres -c` flags in the compose file
(they override both config files).

## Interfaces

### HTTP

N/A: Postgres wire protocol only. No OpenAPI spec. read-api's `/v1/historian/*` routes (see
[read-api](../read-api/README.md)) are the HTTP surface over it.

### Messaging

N/A.

### Database

| Object (in `packiot_historian`) | What |
|---|---|
| `live.equipment_values`, `live.equipment_values_1hour`, `live.equipment_events`, `live.production_orders` | postgres_fdw foreign tables on `packiot_analytics` (server `live_pg`), pinned to the served columns |
| `cold.equipment_values`, `cold.equipment_values_daily`, `cold.equipment_events`, `cold.production_orders` | pg_duckdb views over the Parquet archive (hive partitions `enterprise=/year=/month=`) |
| `silver.equipment_values`, `silver.equipment_events`, `silver.production_orders` | the hot ∪ cold union views consumers query |
| `cold.ev_union_boundary`, `ee_union_boundary`, `po_union_boundary` | per-enterprise cutover timestamps that keep hot and cold disjoint |
| `cold.promoted_enterprise` | allow-list: the only tenants that get cold rows (archive ids collide with new-stack tenant ids) |
| `cold.ev_daily_watermark`, `cold.cold_append_watermark` | daily-rollup coverage and last-append stamps |
| roles `historian_svc`, `historian_readers`, `cloudbeaver_histro` | read-api/Superset service login; the group allowed to run pg_duckdb; read-only browser role |

On the analytics side the FDW logs in as the least-privilege role `histgw_ro` when `HISTGW_RO_PASS`
is set (else as `FDW_USER`).

## Configuration

Read by the init script on a **fresh volume only** (`compose.historian-gateway.yml`); on staging the
values come from `/opt/packiot/.env.historian-gateway`, not the main `.env`.

| Name | Default | Required | Effect |
|---|---|---|---|
| `POSTGRES_PASSWORD` (from `HIST_GW_PASSWORD`) | — | yes | Gateway superuser `postgres` |
| `POSTGRES_DB` | `packiot_historian` (set in compose) | — | Database the init provisions |
| `FDW_HOST` / `FDW_PORT` / `FDW_DB` / `FDW_USER` (from `DB_HOST`/`DB_PORT`/`DB_NAME`/`DB_USER`) | staging DB EC2 / `5432` / `packiot_analytics` / `postgres` | no | Hot side (`live_pg` server and the superuser mapping) |
| `FDW_PASS` (from `DB_PASSWORD`) | — | yes | Password for that mapping |
| `HISTORIAN_BUCKET` | — | yes | S3 bucket of the archive (`terraform/staging/historian-gateway.tf`) |
| `AWS_REGION` | `us-east-1` | no | S3 region |
| `HIST_AWS_KEY` / `HIST_AWS_SECRET` | — | yes | Read-only key of IAM user `svc-historian-gateway`; source of truth Secrets Manager `packiot/staging/historian-gateway-s3`, rotated with `scripts/rotate-historian-s3-key.sh`. Instance-role credentials do not work (IMDSv2 through the Docker hop) |
| `HIST_GW_SVC_PASSWORD` | `""` | no | Creates `historian_svc`; unset skips it. deploy-staging.yml mirrors it into the main `.env` from Secrets Manager `packiot/staging/historian-svc` for read-api |
| `CLOUDBEAVER_HISTRO_PASSWORD` | `""` | no | Creates the read-only browser role; unset skips it |
| `HISTGW_RO_PASS` | `""` | no | Password of the remote `histgw_ro` role (`db/migrations/t282-historian-gateway-glue/`); unset falls back to the FDW superuser with a warning |

A running gateway is brought to the init's role state with `apply-hardening.sh`
(`HIST_GW_SVC_PASSWORD=… services/historian-gateway/apply-hardening.sh`; may restart the container).

## Run locally

No dev slice and no tests in this directory. The nearest check is the integrity monitor
(`scripts/historian-integrity-monitor.sh`, `scripts/historian-cutover-coverage-check.sh`,
`scripts/historian-ee-coverage-check.sh`) run against staging.

## Operating it

- **Deploy (staging app host):** the deploy workflow does not touch this container. Recreate it by hand:
  ```sh
  cd /opt/packiot && docker compose -p packiot --env-file .env.historian-gateway \
    -f compose.historian-gateway.yml up -d historian-gateway
  ```
  Init SQL runs only on an empty volume; to change objects on a running gateway, apply the SQL by hand.
- **Daily pipeline** (`scripts/install-historian-pipeline.sh` installs it; units in `systemd/`):
  `historian-staging-append.timer` (02:30 UTC) runs `scripts/historian-staging-run-append.sh`: copy
  legacy equipment values, production orders and shift OEE to Parquet, stamp watermarks, then run `refresh-equipment_values-cutover.sql`,
  `refresh-ee-cutover.sql` and `refresh-po-cutover.sql`; `scripts/historian-ev-daily-rollup.sh` writes
  the daily rollup. `historian-integrity-monitor.timer` (04:00 UTC) checks the result.
- **Monitoring:** Prometheus job `blackbox-historian` (TCP probe `hist-gateway:5432`), alert
  `HistorianGatewayDown` (5 min); backup alerts for `db="packiot_historian"` and `historian_parquet`
  in `monitoring/prometheus/rules.yml`; the probe feeds the "Synthetic probes OK" stat in `grafana/dashboards/audience/02-platform-sre.json`.
- **Rules that keep it correct and fast:**
  1. Re-run the cutover refresh after every archive append or backfill, as a **top-level** statement:
     pg_duckdb cannot scan Parquet inside a function. A stale boundary double-counts.
  2. Put the tenant in the query as a literal (`id_enterprise = 3`). DuckDB has no session context, so
     GUC-based RLS (`current_setting`) does not work on the cold side.
  3. Add a `year`/`month` predicate: DuckDB prunes only on partition columns, not on `ts_value`
     (measured 59 files / 171 s vs 1 file / 0.6 s for one day).
  4. Never bound a `live.*` query with `now()`: postgres_fdw does not ship stable functions, so the
     whole remote table is pulled (173 s vs 59 ms). Use literal timestamps; check `Remote SQL:` in
     `EXPLAIN (VERBOSE)`.
  5. Long windows read the daily rollup (`cold.equipment_values_daily` before
     `ev_daily_watermark.covered_until`, `live.equipment_values_1hour` after), never per-second rows.
  6. Use the simple query protocol for anything touching `cold.*` (pg_duckdb does not apply the S3
     secret on the prepared-statement path).
- **Failure modes:** DuckDB "Out of Memory … failed to offload data block" on wide cold scans (the
  2026-09-29 refresh failure: now reads Parquet footers instead); a missing `promoted_enterprise` row →
  tenant sees no cold history; read-api `/v1/historian/*` answers 503 when `HIST_GW_PASSWORD` is unset
  or the gateway is down.

## Code layout

| Path | What |
|---|---|
| `docker-entrypoint-initdb.d/10-historian-gateway.sh` | first-boot init: extensions, FDW server and foreign tables, S3 secret, cold views, boundaries, unions, roles |
| `apply-hardening.sh` | bring a running gateway to the `historian_svc` / `historian_readers` role state |
| `refresh-equipment_values-cutover.sql`, `refresh-ee-cutover.sql`, `refresh-po-cutover.sql` | recompute the per-enterprise boundaries (run after every append) |
| `../../compose.historian-gateway.yml` | the container definition |
| `../../terraform/staging/historian-gateway.tf` | IAM user and read-only bucket policy |

## Related docs

- [ADR-0036 — medallion data architecture](../../docs/adr/0036-data-architecture-medallion.md)
- [ADR-0041 — GCP exit and lakehouse](../../docs/adr/0041-gcp-exit-lakehouse.md)
- [ADR-0060 — local development environment](../../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md)

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [historian-gateway](https://wiki.packiot.app/understand/components/historian-gateway/) |
| Backups and known gaps | [Backups & restore](https://wiki.packiot.app/build/operate/backups-and-restore/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
