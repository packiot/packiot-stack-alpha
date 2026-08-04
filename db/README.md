# db — the PostgreSQL / TimescaleDB layer

Everything needed to **build the stack's single production database** lives here:
the Docker image (Postgres 15 + TimescaleDB + `pg_cron`), the first-boot init
scripts, the local-dev bootstrap schema, and the greenfield-prod **F3 schema
assembly** with its correctness gate.

The DB is the compute engine of the platform, not a passive store. The Go
services (`edge-transformer`, `oeecloud-worker`) write **raw** data —
`equipment_values`, `equipment_events`, `uns_metrics` — and the database turns
it into OEE via TimescaleDB **continuous aggregates** and PL/pgSQL rollup
functions. **Hasura** sits in front for GraphQL; `pg_dump` against prod is
blocked, so inspect schema via `information_schema` / the Hasura console.

> **The schema comes in two shapes.** *F1/legacy* is the historical
> flow-1 schema (edge-api knex + the old `oeecloud-node-red` DDL). *F3* is the
> refactored **single-flow** schema — the same one staging carries in its
> `packiot_shadow` schema — that a greenfield prod DB is **born with** directly,
> skipping the long ADR-0012/0032 migration. New production is F3-only.

---

## Layout

```
db/
├── Dockerfile                         Postgres 15 + TimescaleDB + pg_cron (compiled from source)
├── clang-19-stub.sh                   build shim: no-op clang so pg_cron's pgxs JIT step passes on Alpine
│
├── docker-entrypoint-initdb.d/        run ONCE on first boot of an empty PGDATA (postgres-image convention)
│   ├── 00-init-extensions.sh          CREATE EXTENSION timescaledb + pg_cron; GRANT USAGE ON SCHEMA cron
│   └── 01-create-authentik-db.sh      create the `authentik` role + database (Authentik's own DB) + pgcrypto
│
├── init/                              LOCAL-DEV bootstrap schema + a set of F3/F2 migration & hardening fixups
│   ├── README.md
│   ├── 00-schema.sql                  core OEE hierarchy + production tables (dev; mounted by compose.development.yml)
│   ├── 01-seed.sql                    demo enterprise (id=1), sample machines, packml topics, downtime reasons
│   ├── 02-refactored-rollup-bigint-widen.sql   widen week/month rollup int4→bigint (int4 SUM overflow denial guard)
│   ├── 03-purge-nonstate-event-pollution.sql   one-time cleanup of stray open (ts_end NULL) events
│   ├── 04-capture-observations.sql             ADR-0045 live-capture evidence table (agent writes / edge-api reads)
│   ├── 04-equipments-production-speed-source.sql  provenance flag for provisional ideal-speed inference
│   ├── 05-oee-silver-runtime-hardening.sql     reversible tuning on the high-churn OEE rollup tables
│   ├── 06-eqvalues-index-prune.MANUAL.sql       ⚠ RUN MANUALLY, outside a txn (DROP INDEX CONCURRENTLY / VACUUM FULL)
│   ├── 07-oee-output-clamp-backfill-and-checks.sql  ADR-0037 output-invariant backfill (oee ≤ 1)
│   ├── 08-oee-full-bounds-and-po-summary.sql    ADR-0037 tightened: *_oee_bounds BETWEEN 0 AND 1 on 7 tables
│   ├── 09-packml-register-device-key.sql         ADR-0046 device_key column + per-tenant unique index
│   └── 10-packml-register-device-key-global-unique.sql  promote device_key to a GLOBAL unique index
│
└── init-f3/                          GREENFIELD-PROD: assemble the F3 schema as `public` + prove it
    ├── README.md                     ← read this first for any prod-schema work
    ├── MANIFEST.f3-target            authoritative F3 target manifest (curated, SELECT-only from live packiot_shadow)
    ├── DEBRIS.exclude                regex patterns of staging debris that must NOT enter prod
    ├── knex-baseline.sql             fake-baseline edge-api's knex against F3 so db-migrate doesn't rebuild F1 over F3
    ├── assemble.sh                   reviewable fragment-scaffold (authoring aid; does NOT reach parity by itself)
    └── snapshot/                     the AUTHORITATIVE F3 DDL that compose.production.yml applies
        ├── README.md
        ├── 00-packiot_shadow-schema.sql   curated schema-only pg_dump (152 tables, 129 fns, 10 views) — best-effort
        ├── 05-f3-cagg-agg.sql              equipment_values hypertable + 9 agg_* continuous aggregates — strict
        └── 10-f3-timescale-supplement.sql  3 remaining raw hypertables + 5 ca_* continuous aggregates — strict
```

---

## How the schema is built

There are **three** build paths — one per environment.

### 1. Local dev (`make up` / `compose.development.yml`)

The `postgres` service runs the plain **`timescale/timescaledb:2.25.2-pg16`**
image and mounts the SQL files into `/docker-entrypoint-initdb.d/`, which the
Postgres image executes **once, alphabetically, on first boot** of an empty
`pg-data` volume. The mount renumbers them to fix ordering:

| Container path | Source |
|---|---|
| `10-base-schema.sql` | `db/init/00-schema.sql` |
| `11-seed.sql` | `db/init/01-seed.sql` |
| `12-…-27-…` | `edge-node-red/db/02…24-*.sql` (production objects, operator views, shifts, triggers, UNS, fixtures) |

So dev gets the **F1/legacy** shape with full production parity plus demo data —
enough to exercise the whole pipeline (edge-nodered → DB → Hasura) locally. The
dev image auto-creates the `timescaledb` extension via its own initdb; the
`db/docker-entrypoint-initdb.d/` scripts are **not** used by dev (they belong to
the `db/Dockerfile` image — see path 2). *(VERIFY: dev relies on the base
image's auto-created `timescaledb`; `pg_cron` is not created in the dev path.)*

### 2. Staging / the DB image (`db/Dockerfile`)

`db/Dockerfile` builds `timescale/timescaledb:latest-pg15` and **compiles
`pg_cron` v1.6.5 from source** (the Alpine base ships no `pg_cron` package;
`clang-19-stub.sh` no-ops the JIT bitcode step so `pgxs` completes — only the
`.so` matters for a background worker). It bakes in
`docker-entrypoint-initdb.d/` so first boot creates the extensions + the
`authentik` DB. `shared_preload_libraries=pg_cron` and `cron.database_name` are
passed as `docker run -c` flags (the base image reads only
`$PGDATA/postgresql.conf`, so `conf.d` drop-ins are ignored). *(VERIFY: this
image is consumed by the staging DB EC2's `db_init.sh`; staging’s real schema
arrives through edge-node-red migrations, not `db/init/`.)*

### 3. Greenfield production (`compose.production.yml`, external r7g DB)

Prod's DB is an **external** TimescaleDB EC2 (`timescale/timescaledb:2.25.2-pg16`).
A chain of one-shot `postgres:16-alpine` jobs assembles F3 as `public`:

```
db-init-bootstrap   CREATE EXTENSION timescaledb (+ pg_cron best-effort)
      ▼
db-schema-f3        apply db/init-f3/snapshot/00-*.sql  (best-effort)
                    then          snapshot/05,10-*.sql  (strict, ON_ERROR_STOP)   ← real F3 schema
      ▼
db-knex-baseline    apply db/init-f3/knex-baseline.sql  (fake-baseline knex)
      ▼
db-migrate          edge-api knex migrate:latest         (only edge-api-only migrations)
```

**Why the snapshot split** (`00` best-effort, `05`/`10` strict): a plain
`pg_dump` **cannot** restore TimescaleDB continuous aggregates — it emits them as
views over `_timescaledb_internal._materialized_hypertable_NN`, which don't exist
on a fresh DB. So the caggs + hypertables are recreated timescale-aware in
`05`/`10`, while `00`'s stripped cagg residue fails benignly. This exact sequence
is **proven to `F3_MISSING=0, EXTRA=0`** against the live target manifest — see
[`init-f3/README.md`](init-f3/README.md) §5/§6.

**`assemble.sh` is not the prod path.** It concatenates canonical F3 source
fragments in dependency order and is useful for *reading/authoring* the schema,
but the fragments have diverged from live `packiot_shadow` and **do not reach
parity** (measured: neither subset nor superset of F3). The authoritative method
is the curated snapshot. Always prove a candidate with the gate:

```sh
CANDIDATE_DSN=<dsn> ./scripts/prod-f3-schema-parity-check.sh gate   # PASS ⇔ F3_MISSING=0
```

---

## Key concepts

- **Hypertables.** Raw time-series (`equipment_values`, `equipment_events`,
  `*_raw`) are TimescaleDB hypertables (`create_hypertable(...)`), auto-partitioned
  by `ts_value` for time-range pruning and retention.
- **Continuous aggregates (the OEE cagg chain).** OEE is *materialized*, not
  computed on read. Raw `equipment_values` rolls up through
  `agg_equipment_values_1min → _10min → _1hour` (+ area/site grains and the
  `ca_*` family), refreshed by TimescaleDB **continuous-aggregate policies**
  (`add_continuous_aggregate_policy(...)`, run by TimescaleDB background workers —
  e.g. the 1-min cagg refreshes every minute with a 2-hour lookback). Higher
  grains — `equipment_runtime_shift / _1hour / _1day / _1week / _1month` — are
  populated by the `piot_create_*_runtime` PL/pgSQL provisioning functions the Go
  worker invokes (it owns no DDL; it sets `search_path` and calls pre-existing
  functions). **Do not add the dev OEE-compute triggers to F3** — the Go worker +
  caggs own compute; triggers would double-count.
- **`pg_cron`.** Installed for scheduled stored-proc jobs. *(VERIFY: the specific
  `cron.schedule` jobs live in the edge-node-red DDL submodule, not in `db/`; the
  cagg **refresh** cadence is TimescaleDB policies, not `pg_cron`.)*
- **OEE output invariant (ADR-0037).** Rollup code clamps every served ratio to
  `GREATEST(LEAST(r,1),0)`; `init/07`/`08` backfill historical rows and add
  `*_oee_bounds BETWEEN 0 AND 1` CHECK constraints across 7 tables. A negative or
  >1 OEE is a bug, not data.
- **`active` soft-delete.** `active=true/false` is the soft-delete flag on
  `enterprises`, `users`, and `packml_register` (oeecloud only routes topics with
  `active=true`). The CS-Admin PR series extends `active` to `sites`, `areas`,
  `equipments` — but until downstream consumers filter on it, soft-deleted rows
  can still be visible. Check the target table's actual prod state; don't assume
  `active=true` is universally enforced. (See the repo-root `CLAUDE.md`.)
- **`device_key` (ADR-0046).** `init/09`/`10` give each equipment a stable,
  tenant-prefixed `device_key` resolved to `id_equipment` via `packml_register` —
  identity is *declared at birth*, not string-parsed from a metric name at data
  time. Promoted to a **global** unique index so the single multi-tenant
  edge-transformer can resolve any tenant's birth.

---

## Working with it locally

All targets are on the root `Makefile` (uses `compose.development.yml`):

```sh
make up                 # bring the dev stack up (runs init scripts on first boot)
make psql               # open a psql shell in the postgres container
make db-rebuild         # ⚠ wipe the pg-data volume and re-run ALL init scripts (schema parity)
                        #   RabbitMQ / Grafana data is untouched; hasura is restarted after
```

Read-only inspection helpers (thin `psql -c` wrappers):

| Target | Shows |
|---|---|
| `make db-equipments` | equipments (id, name, `tp_equipment`, area, site) |
| `make db-packml` | `packml_register` routing (topic → `id_equipment`, `active`, `id_unit`) |
| `make db-enterprises` | enterprises + `api_key` + `active` |
| `make db-sites` / `db-areas` | hierarchy layers |
| `make db-equipment-values` | last 20 raw metric rows |
| `make db-events` / `db-uns` | last 20 events / UNS metrics |
| `make db-orders` | recent production orders |
| `make db-count` | row counts for all key tables |
| `make apply-views` | re-apply operator views to a running DB + reload Hasura metadata |

`db-rebuild` drops the `packiot-stack-alpha_pg-data` volume so the Postgres image
re-runs every `initdb.d` script — the clean way to pick up a changed
`db/init/00-schema.sql` or `01-seed.sql`.

---

## Contributing

- **Schema changes follow the normal flow** — a feature branch → `development` →
  `staging`, PR-only. See the repo-root
  [CONTRIBUTING.md](https://github.com/packiot/packiot-stack-alpha/blob/staging/CONTRIBUTING.md).
- **Dev bootstrap:** add a new core table to `init/00-schema.sql`; add seed rows
  to `init/01-seed.sql` (prefer extending it over new files — init order is
  alphabetical, so keep the numeric-prefix discipline if you must split).
- **F3 / prod schema:** never hand-assemble prod from fragments. Evolve the
  schema on staging `packiot_shadow`, then **regenerate** the snapshot via
  `scripts/capture-f3-snapshot.sh` (gated — needs a staging DB read) and re-run
  `scripts/prod-f3-schema-parity-check.sh gate`. Nothing merges to the prod path
  until `F3_MISSING=0`. See [`init-f3/README.md`](init-f3/README.md).
- **`pg_dump` against prod is blocked** — inspect schema through
  `information_schema` queries or the Hasura console, not a dump.
- **Prod DB is SELECT-only** for humans: any read on the prod/staging DB EC2 runs
  under `BEGIN READ ONLY`.
