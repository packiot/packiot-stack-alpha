# Worker tier — horizontal scale + Kubernetes orchestration & monitoring (#279)

Design for running the OEE ingest/rollup worker tier (`stream-engine`, formerly
`oeecloud-worker`) as a horizontally-scalable, orchestrated, observable service —
on the org's target platform (Kubernetes + ArgoCD GitOps, `api-gitops` /
`packiot-stack`). It documents what already exists (a lot), the two hard
constraints any orchestration must respect, and the staged path from today's
single docker-compose container to a KEDA-autoscaled K8s deployment.

> **Status:** design. The horizontal-scale *mechanism* is already implemented and
> flag-gated off (Strategy D, below). This doc adds the K8s/KEDA/monitoring layer
> on top of it. No production behavior changes until each phase is opted into.

---

## 1. What already exists (don't rebuild it)

`stream-engine` is a single Go binary that does **two jobs in one process**:

1. **Ingest** — consumes per-tenant SparkPlug queues (`stream-engine-q-<tenant>`),
   decodes counters, writes `silver.equipment_values` / `_events`.
2. **Rollup** — computes OEE aggregates (`gold.equipment_oee_*`) on a ticker.

The horizontal-scale foundation is **Strategy D** (see
`services/stream-engine/docs/strategy-d-shared-pool-sac.md`), already in the code:

- **Single-Active-Consumer (SAC)** per-tenant main queues (`x-single-active-consumer`):
  every replica subscribes to every tenant queue, RabbitMQ keeps exactly **one
  active consumer per queue** (ordered), spreads different tenants' active
  consumers across replicas, and **fails over automatically**. Flag:
  `WORKER_POOL_SAC_ENABLED` (default off) + a one-time queue migration.
- **Dynamic tenant discovery** — `DiscoverActive` re-runs every
  `TENANT_DISCOVERY_INTERVAL_SECONDS`; a new client starts flowing with no restart.
- **`deploy.replicas`** honored by compose (`OEECLOUD_WORKER_REPLICAS`).
- **Observability already wired** (#180): Prometheus, Grafana, Tempo (OTLP tracing:
  publish→consume→DB is one trace via otelpgx), Loki, Alloy.

SAC was chosen over competing-consumers (breaks ordering), consistent-hash
(no auto-failover), and in-app leader election (reinvents the broker). That
decision stands; K8s does not change it.

---

## 2. The two hard constraints (why naive scaling corrupts data)

Any orchestration MUST preserve both, or it silently corrupts OEE:

1. **Ingest ordering is per-tenant.** Counter values are cumulative; increments are
   deltas differenced from a process-local per-topic baseline. Two consumers on one
   tenant's stream, out of order → corrupted counts. **SAC** enforces one active
   consumer per tenant queue. A failover re-seeds the baseline on first observation,
   exactly like a reconnect — safe.
2. **Rollup must not run concurrently for a tenant.** The rollup/provision path holds
   a **session-scoped `pg_advisory_lock`** keyed `<db>:runtime`
   (`internal/rollup/provision.go:80`) across ~17 provision-fn calls. This makes the
   rollup **self-serializing**: run it in N replicas and only one holds the lock at a
   time; the rest skip. So the rollup is already replica-safe — but N-1 replicas waste
   a tick contending on the lock. (The #259 incident — a ~100× line-lead rollup that
   froze compute — is the failure mode to alert on: lock held far too long.)

---

## 3. Target K8s architecture

### 3a. Split the two jobs into two Deployments

Today one container does ingest + rollup. In K8s, split them — the scaling axes are
different and the split removes the wasted rollup lock-contention:

| Deployment | Replicas | Scales on | Why |
|---|---|---|---|
| `stream-engine-ingest` | N (autoscaled) | RabbitMQ backlog | SAC consumers; throughput scales with tenant count |
| `stream-engine-rollup` | 1 (fixed) | — | Serialized by the advisory lock; more replicas = pure waste |

The same binary runs both modes today; add a mode flag (`WORKER_ROLE=ingest|rollup|both`)
so one image serves both Deployments. `both` stays the default → compose is unchanged.
`stream-engine-rollup` at `replicas: 1` with the advisory lock as a backstop is the
simplest correct choice (no K8s Lease/leader-election dependency needed; the lock
already guarantees ≤1 active even during a rolling restart's brief 2-pod overlap).

### 3b. Autoscaling: KEDA on RabbitMQ queue depth — **with a hard ceiling**

KEDA's `rabbitmq` scaler scales `stream-engine-ingest` by queue backlog
(`messages`/`messageRate`), summed across `stream-engine-q-<tenant>`.

**The non-obvious ceiling (get this wrong and you burn pods for nothing):** under SAC,
a queue has exactly **one active consumer**. Replicas beyond the tenant count become
**hot standbys** that process nothing — they add failover resilience, not throughput.
So:

- `maxReplicaCount ≈ number_of_active_tenants + small failover headroom`. Scaling past
  that is wasted pods (a KEDA-on-backlog default of 30 would spawn 30 idle standbys for
  3 tenants).
- `minReplicaCount ≥ 2` (never 0): SAC needs a live consumer, and scale-to-zero would
  drop the counter baseline (re-seeds fine but adds cold-start latency + a gap). Two
  replicas give failover.
- The real throughput lever within a tenant is **in-process concurrency** (Strategy A),
  not more pods — a single tenant's stream is one ordered SAC consumer regardless of
  replica count.

`stream-engine-rollup` is **not** autoscaled (fixed 1).

### 3c. Health probes

The binary is distroless and self-probes via `--healthcheck` (in-container `:9101`,
no host port). Map to:
- **liveness** = process alive.
- **readiness** = broker connected AND DB pool ready (mirror the existing
  "gateway pool ready" gate) — so K8s doesn't route/rebalance to a pod that can't
  consume yet.

---

## 4. Monitoring in K8s

Reuse the existing Prometheus/Grafana/Tempo/Loki stack; add K8s-native wiring:

- **Prometheus `ServiceMonitor`** scraping `stream-engine` `:9101/metrics`.
- **Key SLIs** (alert on these):
  | Signal | Why it matters |
  |---|---|
  | per-tenant queue depth / age | backlog growing = KEDA not keeping up or `maxReplicas` hit |
  | active-consumer present per tenant queue | SAC failover stuck → a tenant silently stops ingesting |
  | rollup lock-hold duration | the #259 class — a stuck/slow rollup freezes OEE |
  | rollup lag (now − max `gold.*.computed_at`) | OEE going stale |
  | DB pool saturation | shared analytics pool is the bottleneck under scale |
  | `-failed` DLQ depth | poison messages accumulating |
  | msg process p99 | per-message latency regression |
- **Tracing** (Tempo): already publish→consume→DB per message; add pod/replica labels
  so you can see *which* replica is active per tenant.
- **Grafana dashboards**: per-tenant throughput, replica→tenant active-consumer map,
  rollup progress per grain, DLQ trend.

---

## 5. Staged migration (each phase opt-in, reversible)

0. **Today** — compose, single `stream-engine`, SAC off, `both` mode. (current)
1. **Validate the scale model on compose** — run `migrate-tenant-queues-sac.sh`, set
   `WORKER_POOL_SAC_ENABLED=true` + `OEECLOUD_WORKER_REPLICAS=2`, comment out
   `container_name`/static IP. Prove SAC active + tenant spread in the broker UI. No K8s yet.
2. **Lift-and-shift to K8s** — one `Deployment` (`both` mode, `replicas: 1`), `ServiceMonitor`,
   liveness/readiness probes, secrets via External Secrets Operator → AWS Secrets Manager
   (matches today's `PG_SECRET_ID`). Validate wiring; no autoscale.
3. **Split ingest/rollup** — two Deployments (`WORKER_ROLE`), rollup fixed at 1.
4. **KEDA autoscale ingest** — `ScaledObject` on RabbitMQ backlog, `maxReplicaCount ≈
   tenant count + headroom`, `minReplicaCount = 2`.
5. **Multi-AZ failover** — `podAntiAffinity` spreads replicas across nodes/AZs so an SAC
   failover lands on a *different* host.

All manifests land in `api-gitops` (ArgoCD/Kustomize); `packiot-stack` stays the
compose/dev source of truth.

---

## 6. Open decisions (gate before Phase 2+)

- **Rollup singleton mechanism**: fixed `replicas:1` Deployment + advisory-lock backstop
  (recommended, simplest) vs K8s Lease leader-election (only if you ever need the rollup
  hot-standby'd across nodes). The advisory lock already makes this correct; the Deployment
  replica count is just to avoid wasted ticks.
- **Broker**: stays external (RabbitMQ) — do NOT move it into the same autoscaling group;
  its connection count is an SLI (a spike = a leak, per the RabbitMQ topology doc).
- **Cluster**: EKS is implied by the AWS footprint; confirm node sizing against the shared
  analytics DB pool ceiling (the real scale bottleneck is DB connections, not worker CPU).

## 7. References
- `services/stream-engine/docs/strategy-d-shared-pool-sac.md` — the SAC pool design
- `docs/ops/rabbitmq-topology.md` — canonical queue topology + connection-count SLI
- `internal/rollup/provision.go` — the `pg_advisory_lock` rollup serialization
- CLAUDE.md — K8s/ArgoCD target (`api-gitops`, `packiot-stack`)
