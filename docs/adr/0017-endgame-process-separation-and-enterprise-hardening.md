# ADR-0017 — Endgame target architecture: process separation + enterprise hardening

- **Status**: **Accepted** (blessed by decider Emmanuel Podestá,
  2026-07-07, relayed via session). Phase E's ADR gate is satisfied;
  its soak gate (Phase B complete) remains.
- **Context**: ADR-0016's flip consolidates onto ONE flow. This ADR
  decides what the stack looks like AFTER that: the process topology,
  the RabbitMQ topology, and the database operating standard the
  program finishes on. Execution sequencing lives in
  `overview/07-endgame-roadmap.md`.

## Context

Post-flip, `oeecloud-worker` is a **worker monolith**: one process
holding the AMQP ingest consumer AND ~12 scheduled engine jobs AND the
per-customer report writers. That was the *correct* migration shape —
one binary, one bake surface, verbatim ports — but it is the wrong
end-state:

- **Failure blast radius**: a report job OOM or a runaway engine query
  can stall the latency-sensitive ingest path in the same process.
- **Deploy coupling**: a one-line report tweak redeploys (and
  restarts) the ingest consumer.
- **Scaling shape mismatch**: ingest scales horizontally with tenant
  traffic; the engine wants singleton-per-job semantics; reports are
  bursty batch. One process = one scaling knob for three shapes.

## Decision

### 1. Process topology (split along fault + scaling boundaries)

| Service | Owns | Scaling shape |
|---|---|---|
| `edge-transformer` | MQTT/SparkPlug ingest per factory + outbox (unchanged) | per-factory instance |
| **`ingest-worker`** | AMQP consume → raw writes ONLY (`equipment_values`, UNS current-state) | horizontal; per-tenant queues |
| **`engine-worker`** | ALL scheduled computation (rollups, PO runtime, shift resolver, UNS refresh, events deriver) | singleton with a Postgres advisory-lock leader lease; per-job env flags stay |
| **`reports-worker`** | per-customer report writers (speed33, shift06, sync06, sap13, boxes) | singleton, low priority, isolated |
| `refdata-api` | read surface (legacy contract + composable query API) | horizontal, stateless |
| `mirror-worker-go` | prod→staging mirror (until prod migrates, then retires) | singleton |

Extraction rule: **packages move verbatim** (`internal/reports` →
reports-worker, `internal/rollup|uns|events|shiftresolver|pocontrol` →
engine-worker). The `jobs`, `config`, `secrets`, `db`, `metrics`,
`log`, `health` plumbing becomes a shared internal module
(`services/pkg/` or go.work workspace) — ONE copy, not three forks.
No logic rewrites during the split: this is a topology change, and it
gets the same differential discipline as any port (the split services
must produce byte-identical writes to the monolith on mirrored input
— one final, short bake).

### 2. RabbitMQ topology (the bus becomes the contract)

- Keep the `oee` topic exchange as the single data-plane entry; keep
  the existing retry/DLX/failed triple per consumer group.
- **One queue per consumer group** (`ingest-worker-q` inherits
  `oeecloud-worker-q`), quorum queues for anything durable
  (replaces classic durable queues; broker is single-node today —
  quorum still buys crash-safe semantics and is the cluster-ready
  default).
- Publisher confirms everywhere (transformer already does), consumer
  idempotency checklist (`docs/consumer-idempotency-checklist.md`)
  remains a merge gate for any new consumer.
- Control-plane events (PO lifecycle) stay DB-first (user_logs is the
  audit source of truth) — we do NOT move the control plane onto the
  bus in this ADR; revisit only with a concrete need.

### 3. Database operating standard ("full-fledged enterprise DB")

The consolidated DB (`packiot_shadow`, promoted at the flip) finishes
with:

- **Schema**: pool multi-tenancy completed (`customer_reports`,
  `customer_dashboards`), `ca_*` hierarchical CAggs (compressed),
  naming per `0012-naming-map.md` once task #86 unlocks it,
  `hist_*` history separation, per-table-class retention +
  compression policies (raw 90d compressed / grains 2y / hist frozen).
- **Roles**: one least-privilege login per service
  (`ingest_worker_rw` on raw tables only, `engine_worker_rw` on grain
  tables, `reports_worker_rw` on pools, `refdata_ro`), `migration_role`
  time-boxed for DDL, `awslambda` read-only forever. No service runs
  as `postgres`.
- **Backups**: pgBackRest (or wal-g) with WAL archiving → PITR, plus
  the existing EBS snapshots; **a restore drill is part of the
  definition of done** — an untested backup is a hope, not a backup.
- **Alerting**: Prometheus rule files land (ingest freshness, job
  failure streaks, CAgg invalidation backlog, disk) — closing the
  documented monitoring gap; every alert routes to a human channel.
- Row-level security: evaluated and (default) REJECTED for now — the
  pool pattern + server-side customer_id injection (refdata-api) gives
  the isolation we need without RLS's planner and operational costs.
  Revisit if customers ever get direct SQL access.

## Consequences

- Positive: independent deploys, contained failures, per-service SLOs
  become possible, on-call runbooks map 1:1 to processes, the stack
  reads like a system built deliberately rather than accreted.
- Negative: 3 more compose services + secrets + dashboards; a shared
  internal module to keep honest; one more (short) bake to prove the
  split. Split happens ONLY after the flip — never multiply bake
  surfaces during consolidation.
- The monolith name `oeecloud-worker` retires with the split; the
  naming ledger gains the three new clean names.

## References

ADR-0009/0010/0011 (ingest chain) · ADR-0014 (the engine this splits)
· ADR-0015 (read surface) · ADR-0016 (the flip this builds on) ·
`overview/07-endgame-roadmap.md` (sequencing) ·
Industry precedent: single-writer-per-table services (sole-writer
lessons, sessions 71-72), Google SRE production-readiness reviews,
quorum queues as RabbitMQ's replicated default.
