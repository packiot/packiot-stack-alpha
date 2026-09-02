# Cloud Services & OEE Compute

The cloud is a **control plane** (`edge-api`) and a **data plane** (RabbitMQ →
`oeecloud-worker` → Postgres) meeting at one Postgres/TimescaleDB, with `refdata-api`
serving reads back to front4.

> **The through-line:** OEE math no longer lives in the database. Per ADR-0014 the
> compute was lifted out of the retired `oeecloud-node-red` + `pg_cron` + `piot_*`
> PL/pgSQL engine into the **Go worker**, which ships SQL and runs it as set-based
> `UPDATE`s on a job ticker. TimescaleDB owns *storage*; the app owns *compute*.

## edge-api — the NestJS control plane

- **Vertical slices**: each feature is `usecases/{domain}/{feature}/` with its own
  controller (thin) → service (orchestration) → DAO (all SQL). DB via `pg-promise`
  (`providers/database/postgres-adapter.ts`); DAOs bound by string token + `useFactory`.
- **Dual-accept auth** (`middleware/auth.middleware.ts`): a present `Authorization:
  Bearer` **commits and fails closed** (bad token → 401, never downgraded). CS-Admin
  cross-tenant escalation honors `?idEnterprise=N` only when the verified
  `cognito:groups` include `cs-admin`. Otherwise the api-key path (`x-api-key`; `?token=`
  deprecated but accepted). Either path sets `res.locals.callerEnterpriseId`, the single
  tenant authority every write fences on.
- **Audit logger** (`middleware/logger.middleware.ts`): every ≤399 response persists a
  `UserLogsDTO` from `res.locals.logData`.
- **Owns**: hierarchy CRUD; PO control (status 1=available/2=running/3=finished/4=paused);
  downtimes; shifts; `packml-register`; the onboarding descriptor
  (`usecases/onboarding/` — upsert/generate/validate/capture/apply-register/cutover); edge
  deploy (`usecases/edge-bundle/` — fires GitHub Actions, **not** AWS SSM); plc-status;
  users/roles; targets; teams; i18n; session/login; superset-embed.

## refdata-api — the read plane

A small Go binary (`services/refdata-api/`), the **Hasura replacement for reads**
(ADR-0015/0027). Two surfaces: ~12 fixed `/v1/*` legacy routes, and a composable
`GET /v1/catalog` + `POST /v1/query` (metric × dimension × grain × window compiled to
allowlisted cagg SQL, window-capped). Named datasets (`datasets.go`) replace front4's
direct Hasura reads. **Tenancy is load-bearing** — `id_enterprise` is never
client-supplied; it's derived from the credential and injected as `$1`; `api_key`/
`operator_pw_hash` are projected out. Redis cache-aside (5-min TTL) fronts uid→enterprise.

## oeecloud-worker (== stream-engine) — ingest + compute

One Go binary, two halves (`services/oeecloud-worker/`):

- **Half A — AMQP → Postgres ingest.** Consumes RabbitMQ, classifies each SparkPlug
  metric, UPSERTs into `equipment_values` (`ON CONFLICT (ts_value, id_equipment) DO
  UPDATE`), plus `equipment_events` / `uns_current_metrics` / PO params. Metric map:
  `ProdProcessedCount→net`, `ProdConsumedCount→gross`, `ProdDefectiveCount→scrap`,
  `StateCurrent→state`. Routes on `source_type` (`""`→F1, `"go"`→shadow, `"refactored"`→F3).
- **Half B — scheduled compute** (`internal/jobs.Loop` ticker, replaced pg_cron).

> "stream-engine" is the **prod rename** of `oeecloud-worker` (Prometheus scrapes
> `stream-engine:9101`; compose still builds `./services/oeecloud-worker`). Same binary.

> **Where decode runs — cloud vs. on-prem.** By default the SparkPlug **decode**
> (edge-transformer) is a *cloud* step: the box is a thin reader, and only the
> cloud has the `packml_register` mapping that resolves a topic → `id_equipment`.
> The opt-in **fat edge** ([On-Prem Offline Operation](11-on-prem-offline-operation.md))
> runs the *same* transformer image **on the box** in `LOCAL_DECODE_ONLY` mode — it
> decodes to a local current-state cache for an offline dashboard and **never
> publishes to cloud RabbitMQ**. So on such a box decode happens in *both* places,
> but only the cloud copy is authoritative and computes OEE; the on-box copy is a
> read-cache. `id_equipment` resolution still only happens cloud-side.

## The OEE computation

**OEE = Availability × Performance × Quality**, all in the Go worker
(`internal/rollup/`). For each grain the pattern is identical — A and Q measured
directly, **P back-solved as the residual** so the waterfall closes:

```sql
oee   = net / NULLIF(ideal_production, 0)                     -- composite
oee_a = running_time / NULLIF(total_time - planned_downtime,0) -- AVAILABILITY
oee_q = net / NULLIF(gross, 0)                                 -- QUALITY
oee_p = oee / NULLIF(oee_a * oee_q, 0)                         -- PERFORMANCE (residual)
```

- **Availability** = `running_time / (total_time − planned_downtime)`; `running` sums
  `equipment_events` overlaps where PackML `status = 6`. `LEAST(running, total)` guard
  after a real int-overflow/double-count incident.
- **Quality** = `net / gross` (good / total processed).
- **Performance** = residual — never measured directly (a mis-set `ideal_speed` inflates
  it; ADR-0037 flags this as a weakness, now bounded by the Silver clamp + DQ events).
- **Counters-only availability fallback** (`availability.go`): for state-less Modbus
  machines, availability is reconstructed by idle-timeout sessionization over the 1-min cagg.
- **Line-lead / split instrumentation** (`line_lead.go`): for a line whose infeed and
  outfeed are **separate machines** (no single machine carries both meters), the tp=3 line
  row names `gross_machine` (infeed), `lead_machine` (outfeed/net + availability) and
  optional `scrap_machine`; the line's `gross`/`net` are read from those designated members
  (never a sum of all net members) and **scrap = GREATEST(gross − net, 0)**. Flag-gated per
  enterprise (`COUNTERS_ONLY_LINE_LEAD_ENTERPRISES`); mutually exclusive with the counters-only
  availability path per tenant. Set the designation via CS-Admin → Line configuration ("Auto-assign
  from sensors") — see [Onboarding](02-onboarding.md#designating-a-lines-infeedoutfeed-meters).

> **Per-tenant gate:** none of these rollup passes produce anything for a tenant absent from
> `BAKE_ENTERPRISE_IDS` — that env list drives the runtime-provision that *creates* the
> `equipment_runtime_shift` skeleton rows the passes fill. A tenant missing from it computes
> zero OEE regardless of shifts/meters. See [Onboarding → the three tenant gates](02-onboarding.md#after-cutover-making-oee-actually-compute-the-three-tenant-gates).

### The pipeline

```
equipment_values (raw hypertable) → agg_*_{1min,1hour,1day,1week,1month} (TimescaleDB caggs)
   → equipment_runtime_{shift,1hour,1day,…}  → production_orders_runtime → production_orders
```

`recalc_needed` is a dirty flag: write-side PO events set it; the rollup passes clear it
and re-flag the tail — incremental, bounded-per-tick work replacing "recompute on cron."

### Correctness guardrails (ADR-0036/0037 medallion)
`dq.go` side-writes invariant breaches (`OEE_GT_1`, `NET_GT_GROSS`, …) to
`data_quality_event` without altering values; `silver.go` clamps out-of-range served
values and emits a paired `INVARIANT_CLAMPED_*` — a clamp is always a visible tripwire.

## Messaging — RabbitMQ

Replaced GCP Pub/Sub + Node-RED direct-DB-write (ADR-0041). Broker boots with
users/vhosts only; **queues/exchanges/bindings are declared idempotently in Go** on every
connect (`internal/amqp/topology.go`). Exchange `oee` (source) → per-tenant queues
`oeecloud-worker-q-<tenant>` bound to `sparkplug.data.<tenant>`; failures DLX to
`oee-retry` (30s TTL) → back to `oee`; after `MAX_RETRIES=5` → `oee-failed` (poison
isolation). **Dynamic tenant discovery** (`internal/tenants/discovery.go`):
`SELECT DISTINCT lower(split_part(packml_topic,'/',1)) FROM packml_register WHERE active`
— a tenant is a lowercased SparkPlug group_id; source of truth is `packml_register.active`,
owned by CS-Admin.

## Auth / security posture

- **oauth2-proxy + Cognito** (nginx `auth_request`) is the live gate for admin UIs
  (Authentik retired). `cs-admin` group for staff UIs; any pool user for operator.
- **CloudFront + WAFv2** front `*.<env>.packiot.app`; **X-Origin-Verify** header locks the
  origin (nginx 403s any request lacking the CloudFront-injected secret).
- **edge-api in-app auth** is the last line: verifies the Bearer/api-key independently and
  fences every write on the server-derived tenant.

> Caveat: the CloudFront/WAF/oauth2-proxy edge is authoritative on `origin/staging` /
> `origin/production`; some feature branches still carry the old Authentik config.
