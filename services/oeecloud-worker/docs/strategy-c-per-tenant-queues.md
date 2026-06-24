# Strategy C — Per-Tenant Queues

Design doc for issue **#42** of the oeecloud-worker scaling roadmap.

> **Status (2026-06-24):** **DESIGN + STAGING IMPLEMENTATION**. Unlike
> Strategy A (which stays design-only until load triggers fire), Strategy
> C is being shaped into the staging code now so the Q3/Q4 2026
> production migration is architecturally a no-op. The production stack
> has ~10 tenants today; we don't want to discover topology surprises
> during cutover.

---

## 1. Why this exists

The production environment has **~10 active clients** (factories), each
running their own edge-node-red instance publishing Sparkplug B data.
Today they all funnel through one GCP PubSub topic into one
oeecloud-node-red instance.

When `oeecloud-worker` replaces `oeecloud-node-red` in production
(planned Q3/Q4 2026), we have two architectural choices:

1. **Mirror the existing single-funnel shape**: one `oeecloud-worker-q`
   queue receiving all 10 tenants' traffic. Same noisy-neighbor profile
   as today's PubSub topology, with a faster consumer.
2. **Adopt per-tenant queues from day 1**: each tenant gets their own
   `oeecloud-worker-q-{tenant}` queue. Isolation, scoped debugging,
   per-tenant capacity quotas.

We pick **(2)**. The reasoning:

- **One migration, not two.** Adding per-tenant queues to the same
  cutover that replaces oeecloud-node-red is incremental complexity.
  Bolting them on six months later would be a separate coordinated
  change to a live production system.
- **Future-proofing for one large tenant.** Today's clients have roughly
  uniform volume (within 2-3× of each other). One future "big" client
  shouldn't trigger an architectural rewrite at onboarding time.
- **Operational hygiene scales with tenants, not volume.** Per-tenant
  debugging, deployment surgery, and per-tenant capacity caps are
  load-independent benefits.

**Staging's role**: code-ready for 10 tenants even though only CPACK
flows live data. Validates the topology, onboarding flow, monitoring
shape, and migration playbook before the production cutover.

---

## 2. Constraints — what we must preserve

1. **Backward compatibility with current staging** during the migration.
   edge-nodered + worker must keep working as a single funnel until the
   per-tenant cutover lands. Parallel-running pattern (see §10).
2. **AMQP heartbeat per channel**. amqp091-go runs heartbeat per
   Connection, not per Channel. N channels on one Connection → one
   heartbeat goroutine; if Connection dies, all N tenant consumers
   reconnect together.
3. **DLX retry topology** (per [[amqp-dlx-retry-topology]]) — preserved
   per tenant. Each tenant gets its own retry + failed queue pair so
   one tenant's DLX noise doesn't pollute another's.
4. **CS Admin onboarding remains the source of truth** for tenant
   identity. New tenants get added to `packml_register` first; the
   worker discovers them from DB, not from a separate config file.
5. **RabbitMQ user permissions stay least-privilege** — the
   `oeecloud-worker` AMQP user gets pattern-based perms (`...-q-*`),
   not blanket admin.
6. **Composes with Strategy A** — when a tenant's volume triggers
   Strategy A (`≥100 msg/s sustained`), N goroutines spin up *for that
   tenant's queue specifically*, not globally.
7. **Connection reconnect re-establishes ALL Channels.** N Channels
   on one Connection means one TCP socket failure drops all N
   tenant consumers. Reconnect logic (existing exponential-backoff
   in `consumer.go`) must re-declare topology + re-open all Channels
   atomically — partial recovery leaves some tenants silent.
8. **DB unreachable at startup is fatal-after-retry**, not fail-fast.
   Tenant discovery queries `packml_register` — if Postgres is down
   at boot, retry with exponential backoff up to 5 minutes, then
   crash the container (Docker will restart it). Don't proceed with
   an empty tenant list — that would silently route nothing.

---

## 3. Topology design

### 3a. Exchange + queue layout (target state)

```
                  ┌─────────────────────────────────────┐
                  │  exchange: "oee"  (topic, durable)  │
                  │  publishers: N × edge-nodered       │
                  └────────────────┬────────────────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            │ "sparkplug.data.cpack" │ "sparkplug.data.acme" │ ...
            ▼                        ▼                        ▼
  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
  │ oeecloud-worker-q-  │  │ oeecloud-worker-q-  │  │ oeecloud-worker-q-  │
  │    cpack            │  │    acme             │  │    foo              │
  │  x-dlx: oee-retry   │  │  x-dlx: oee-retry   │  │  x-dlx: oee-retry   │
  └──────────┬──────────┘  └──────────┬──────────┘  └──────────┬──────────┘
             │ nack                    │ nack                    │ nack
             ▼                         ▼                         ▼
  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
  │ ...-q-cpack-retry-  │  │ ...-q-acme-retry-   │  │ ...-q-foo-retry-    │
  │      30s            │  │      30s            │  │      30s            │
  │ x-message-ttl: 30s  │  │ ...                 │  │ ...                 │
  │ x-dlx: oee (source) │  │ ...                 │  │ ...                 │
  └──────────┬──────────┘  └──────────┬──────────┘  └──────────┬──────────┘
             │ TTL expire              │                         │
             └─────────────┬───────────┴─────────────────────────┘
                           ▼  back to source exchange (re-routed by same key)

  After MaxRetries (consumer-side x-death check):
                       publish to oee-failed
                              │
                ┌─────────────┼─────────────┐
                ▼             ▼             ▼
       …-q-cpack-failed  …-q-acme-failed  …-q-foo-failed
       (no TTL, no DLX — terminal, human inspection)
```

**Three exchanges remain** (`oee`, `oee-retry`, `oee-failed`); they're
unchanged. What multiplies is the **queue count**: 3 queues × 10
tenants = 30 queues total. At RabbitMQ's scale that's nothing.

### 3b. Bindings + routing keys

- **Source exchange `oee`** — each tenant queue binds with routing key
  `sparkplug.data.{tenant_id}`. Wildcard binding (`#`) is *removed*
  from the worker queues — only the catch-all DLQ retains it during
  the migration.
- **Retry exchange `oee-retry`** — each tenant retry queue binds with
  the same `sparkplug.data.{tenant_id}` pattern. When the worker
  nacks-to-retry, the message lands in `oee-retry` with its original
  routing key (Rabbit preserves it through DLX), which routes to the
  *correct tenant's* retry queue.
- **Failed exchange `oee-failed`** — same pattern. Tenant-scoped DLQs.

### 3c. Why this exact shape over alternatives

| Alternative | Why we rejected it |
|---|---|
| **One shared retry queue + one shared failed queue across tenants** | Simpler ops dashboard (one DLQ to inspect) but loses the per-tenant debugging benefit *exactly where it matters most*. When client X says "we're seeing duplicates", you want their DLQ separate. |
| **Tenant ID in routing key prefix instead of suffix** (e.g. `cpack.sparkplug.data`) | Less consistent with current convention. Bindings would have to be `cpack.#` style. Either works; we picked suffix for human-readability. |
| **Per-tenant exchange (instead of shared exchange + per-tenant queue)** | Adds a routing layer with no benefit. Topic exchange already does the per-tenant routing via key match. Per-tenant exchange would force publishers to know exchange names per tenant, leaking config. |
| **Dedicated AMQP Connection per tenant** | Wasteful (each connection holds a TCP socket + heartbeat goroutine). Multiple Channels on one Connection is the canonical AMQP pattern; we use that. |

---

## 4. Tenant identity — group_id from Sparkplug

Decided 2026-06-24: **tenant identity is the lowercased Sparkplug
`group_id`**, which is the first `/`-separated segment of the topic.

```
Sparkplug topic:  CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent
                  ^^^^^
                  group_id

tenant_id      :  cpack  (lowercased)
routing_key    :  sparkplug.data.cpack
queue          :  oeecloud-worker-q-cpack
```

**Why this works for us:**

- The PLC's Sparkplug config already encodes group_id. No new
  per-tenant config needed at the factory.
- `internal/sparkplug/parse.go` already splits the topic on `/`
  (lines 120, 166, 187, 212) — extracting `parts[0]` is free.
- Human-readable routing keys make debugging trivial — you can read
  `sparkplug.data.cpack` and know exactly what's flowing.

**Caveats** (worth knowing before this design ages poorly):

1. **All current clients must have a clean group_id**. If any client's
   PLC sends `Customer-A/...` (with hyphens) or other oddities, we may
   need to normalise (slugify) or add a mapping table later.
2. **One tenant ≠ one group_id**. A future customer might span multiple
   group_ids (e.g. `ACME-USA` + `ACME-EU`). We'd handle that by binding
   their queue to multiple routing keys: `sparkplug.data.acme-usa`
   AND `sparkplug.data.acme-eu` → `oeecloud-worker-q-acme`.
3. **The mapping is currently implicit**. If we ever need to decouple
   "what the PLC says" from "how we name the tenant", we'd add a
   `tenant_slug` column to `enterprises` and the routing decision
   moves to edge-nodered's lookup.

The escape hatch (option 3 from the design conversation) stays
available; we just don't pay for it today.

---

## 5. Consumer shape — single process, N channels

**Recommended**: one worker process, one AMQP Connection, N Channels
(one per tenant), one consumer goroutine per Channel.

```
oeecloud-worker container
  │
  ├─ amqp091.Connection (one TCP socket + heartbeat goroutine)
  │     │
  │     ├─ Channel[cpack] ──> ch.Consume(oeecloud-worker-q-cpack) ──> goroutine A
  │     ├─ Channel[acme]  ──> ch.Consume(oeecloud-worker-q-acme)  ──> goroutine B
  │     ├─ Channel[foo]   ──> ch.Consume(oeecloud-worker-q-foo)   ──> goroutine C
  │     └─ ...
  │
  ├─ shared resolver (sync.RWMutex'd packml_register cache)
  ├─ shared pgx pool (per-goroutine conn acquisition)
  ├─ shared Prometheus registry
  └─ shared /health server
```

**Why one Channel per tenant, not one Channel total:**

- AMQP `*Channel` is the unit of consumer registration. `ch.Consume()`
  binds a Channel to a specific queue.
- Per-tenant Channels mean per-tenant `chanMu` (when Strategy A composes
  in) — one tenant's ack contention doesn't bottleneck another's.
- Per-tenant Channels mean per-tenant `Qos(prefetch)` — we can tune
  prefetch per tenant later if some need more / less in-flight.
- AMQP Connection-level limits (default 2047 channels) are nowhere
  close to a problem at 10 tenants.

**Why one process, not N (one container per tenant):**

- N containers = N deployment surfaces, N sets of resource limits, N
  /metrics endpoints to scrape. Operational overhead per tenant grows
  linearly.
- Shared resolver + shared pgx pool are valuable — caching `packml_register`
  lookups crosses tenants beneficially when they share infrastructure
  in DB.
- We can revisit and split to one-container-per-tenant if a specific
  tenant needs isolation we can't get from per-Channel scoping (e.g.
  per-tenant CPU/memory caps).

### 5a. Goroutine sketch

```go
// pseudocode — one consumer goroutine per tenant Channel
for _, tenant := range tenants {
    ch, err := conn.Channel()  // independent Channel per tenant
    if err != nil { return err }

    ch.Qos(cfg.Prefetch, 0, false)
    deliveries, err := ch.Consume(queueName(tenant), "", false, false, false, false, nil)
    if err != nil { return err }

    wg.Add(1)
    go func(t Tenant, ch *amqp.Channel, deliveries <-chan amqp.Delivery) {
        defer wg.Done()
        var chanMu sync.Mutex  // per-tenant; not shared

        // Strategy A composes here: spawn N goroutines for THIS tenant
        // when WORKER_POOL_SIZE > 1. Today N=1 == current behavior.
        for d := range deliveries {
            handleDeliveryLocked(ctx, ch, &chanMu, d)
        }
    }(tenant, ch, deliveries)
}
wg.Wait()
```

---

## 6. Tenant discovery — auto-discover from `packml_register`

When the worker boots, it queries the DB for distinct active group_ids:

```sql
SELECT DISTINCT split_part(packml_topic, '/', 1) AS group_id
FROM packml_register
WHERE active = true;
```

For each row, it declares the tenant's three queues (worker / retry /
failed), binds them with the appropriate routing keys, and spawns the
consumer.

**Why DB-driven over config-file-driven:**

- Source of truth alignment: CS Admin already creates packml_register
  rows during onboarding (per project CLAUDE.md). No second config file
  to keep in sync.
- New tenants come "online" on next worker restart, not on config
  redeploy.
- Stale tenants (no active register rows) are automatically excluded —
  no orphan queues consuming heartbeats.

**Worker restart semantics:**

- On startup: declare queues for every currently-active tenant. Existing
  queues are no-ops (declarations are idempotent).
- On a NEW tenant being added mid-run: that tenant's data lands in the
  exchange but no queue is bound → messages drop unless we add a
  catch-all queue OR restart the worker.
- For staging this is fine (restart on tenant onboarding). For
  production we'd add a small **catch-all queue** (`oeecloud-worker-q-unrouted`)
  binding `sparkplug.data.*` to catch any tenant not yet onboarded.
  Alarms fire if it has > 0 messages.

---

## 7. RabbitMQ user permissions

Today's `oeecloud-worker` user (per session 62 CO-5 phase 2 work in
[[project_oeecloud_worker_migration]]) has perms scoped to its specific
queue names. Strategy C broadens this to a pattern:

```bash
# Before (per CO-5 phase 2):
rabbitmqctl set_permissions -p / oeecloud-worker \
  '^(oeecloud-worker-q|oeecloud-worker-q-retry-30s|oeecloud-worker-q-failed)$' \
  '^(oee-failed)$' \
  '^(oee|oee-retry)$'

# After (Strategy C):
rabbitmqctl set_permissions -p / oeecloud-worker \
  '^oeecloud-worker-q-.*$' \
  '^oee-failed$' \
  '^(oee|oee-retry|oeecloud-worker-q-.*)$'
```

(configure / write / read patterns; the worker needs to **declare** its
queues — that's the configure pattern — **publish** to `oee-failed`,
and **consume** from its own queues + read source exchanges.)

The Terraform-managed AMQP secret (`packiot/staging/rabbitmq-oeecloud-creds`)
stays as-is; only the broker-side permission expressions change.

---

## 8. Monitoring — per-tenant Grafana

### 8a. Metrics shape

Strategy A's existing instrumentation already carries `routing_key` as
a label on every counter — that becomes the *tenant* label for free:

```
oeecloud_worker_amqp_acked_total{routing_key="sparkplug.data.cpack"}
oeecloud_worker_amqp_acked_total{routing_key="sparkplug.data.acme"}
```

Add a Prometheus relabel rule (in `monitoring/prometheus/prometheus.yml`
metric_relabel_configs) that extracts tenant from routing_key:

```yaml
metric_relabel_configs:
  - source_labels: [routing_key]
    regex: 'sparkplug\.data\.(.+)'
    target_label: tenant
    replacement: '${1}'
```

Now every metric has a `tenant` label without changing the worker code.

### 8b. Dashboard changes

`grafana/dashboards/08-oeecloud-worker.json` evolves to:

1. **New template variable**: `$tenant` (Prometheus values query:
   `label_values(oeecloud_worker_amqp_acked_total, tenant)`).
   `includeAll = true`, `current = $__all` (per the
   [[grafana-template-variable-default-trap]] zettel).
2. **All existing panels become tenant-aware**: the PromQL gains a
   `{tenant=~"$tenant"}` filter.
3. **New row**: "Tenant fleet overview" — one stat panel per tenant
   showing current throughput, total acked in window, last delivery
   age. Use repeat-by-variable to auto-grow with tenant count.
4. **Per-tenant queue-depth panel** (new) — Prometheus would need a
   RabbitMQ exporter for this. Defer until rabbitmq-prometheus plugin
   is enabled on staging broker (separate task).

---

## 9. Onboarding flow

A new client lands on staging this way today:

1. CS Admin creates enterprise + site + area + equipments rows.
2. CS Admin creates `packml_register` rows (one per equipment) with
   `active=true`.
3. (NEW under Strategy C) On next worker restart, the worker auto-discovers
   the new group_id, declares its queues + bindings, spawns the consumer.

To make this hands-off, we add a small piece:

- **Trigger worker restart on packml_register changes**: a `NOTIFY`
  hook or an AWS SSM-mediated restart from CS Admin's tenant-create
  flow. Deferred for v1 — for now, document "restart worker after
  onboarding new client" in the CS Admin runbook.

Optionally, the worker can run a periodic `packml_register` poll
(every 60s) to detect new tenants without restart and declare their
queues dynamically. Adds complexity; deferred until we onboard a
tenant during a window where we can't restart.

---

## 10. Migration plan — staging single-queue → per-tenant

We can't atomically swap topology while messages are in flight, but
we can run both in parallel during the cutover.

### Phase 1: declare per-tenant queues alongside legacy queue (no traffic change)

- Worker boot declares **both**: legacy `oeecloud-worker-q` AND the new
  `oeecloud-worker-q-{tenant}` queues *for every active tenant in
  `packml_register`*. **Phase 1 must complete this for ALL active
  tenants before Phase 2 begins** — otherwise a tenant whose queue
  isn't declared yet would have their Phase 2 traffic silently
  dropped by the exchange.
- Legacy queue keeps its `#` binding. Per-tenant queues bind
  `sparkplug.data.{tenant_id}` — but since edge-nodered still publishes
  the bare `sparkplug.data` key, nothing routes to them yet.
- **Also declare a catch-all safety queue** `oeecloud-worker-q-unrouted`
  bound to `sparkplug.data.*` on the source exchange. This catches
  traffic from any tenant whose queue *isn't* declared yet (newly
  onboarded between deploys, misconfigured publisher, etc.).
  Alert fires if `unrouted` queue depth > 0.
- Worker consumes from the legacy queue only at this phase.
- **Validates**: queue topology declares correctly; permissions work;
  per-tenant /metrics labels exist (with zero values).

### Phase 2: edge-nodered cutover — publish per-tenant routing keys

**Critical ordering**: AMQP topic exchanges deliver to **all matching
bindings**. If we change edge-nodered to publish `sparkplug.data.cpack`
BEFORE unbinding legacy queue's `#` from the source exchange, every
message lands in BOTH the legacy queue AND the cpack queue — worker
processes it twice (duplicate DB writes; ON CONFLICT makes that
idempotent, but burns capacity for no gain).

**Correct ordering** (do both at the cutover moment, fast):

1. `rabbitmqctl clear_permissions ... && rabbitmqctl set_permissions ...`
   (no — wrong layer; this is permission, not binding).
2. **Unbind** legacy queue from source exchange:
   `rabbitmqctl --queue oeecloud-worker-q --binding-key '#' delete-binding`
   *(actual command: `delete_queue` is too aggressive; use the
   management API or rabbitmqadmin to delete the specific binding)*.
3. **Restart edge-nodered** with the new publish routing-key
   `sparkplug.data.${group_id}`.

Between steps 2 and 3, messages publishing the OLD key `sparkplug.data`
have no matching binding → they're discarded by the exchange (with no
DLX since there's no binding match). This is a brief outage window —
seconds, if the edge-nodered restart is automated.

Alternative for zero-loss: temporarily bind legacy queue to
`sparkplug.data` exactly (more specific than `#`) before unbinding `#`,
then drain it before Phase 3.

- Worker consumes from **both** legacy + per-tenant queues until Phase 3.
- Legacy queue drains in the next 1-2 minutes (prefetch=50 × ~10 msg/s).

### Phase 3: remove legacy queue

- Once legacy queue has 0 ready + 0 unacked messages for a 5-minute
  window, stop consuming from it.
- Delete the queue: `rabbitmqctl delete_queue oeecloud-worker-q`.
- Remove the legacy queue declaration from `internal/amqp/topology.go`.
- Verify per-tenant /metrics carry full traffic.

Staging cutover risk: low. Single tenant. Total cutover time: ~5
minutes including verification. Production cutover follows the same
phases but spans tenants — Phase 2 can be done one tenant at a time
by changing each edge-nodered separately (the others keep publishing
bare `sparkplug.data` and land in legacy until their own cutover).

---

## 11. Implementation sketch

```go
// internal/config/config.go: add tenant discovery toggle
type Config struct {
    // ... existing fields ...
    TenantDiscoveryMode string // "db" | "static" | "single-queue"
    StaticTenants       []string // comma-separated, used when mode = "static"
}

// internal/amqp/topology.go: tenant-aware declarations
func declareTopology(ch *amqp.Channel, cfg Config, tenants []string) error {
    // declare exchanges (unchanged from today)
    for _, ex := range []string{cfg.SourceExchange, cfg.RetryExchange, cfg.FailedExchange} {
        ch.ExchangeDeclare(ex, "topic", true, false, false, false, nil)
    }

    // declare per-tenant worker queue + retry queue + failed queue
    for _, t := range tenants {
        workerQ := fmt.Sprintf("%s-%s", cfg.WorkerQueuePrefix, t)  // e.g. oeecloud-worker-q-cpack
        retryQ  := fmt.Sprintf("%s-retry-30s", workerQ)
        failedQ := fmt.Sprintf("%s-failed", workerQ)
        routingKey := fmt.Sprintf("sparkplug.data.%s", t)

        ch.QueueDeclare(workerQ, true, false, false, false, amqp.Table{
            "x-dead-letter-exchange": cfg.RetryExchange,
        })
        ch.QueueBind(workerQ, routingKey, cfg.SourceExchange, false, nil)

        ch.QueueDeclare(retryQ, true, false, false, false, amqp.Table{
            "x-message-ttl":          int32(cfg.RetryTTLMs),
            "x-dead-letter-exchange": cfg.SourceExchange,
        })
        ch.QueueBind(retryQ, routingKey, cfg.RetryExchange, false, nil)

        ch.QueueDeclare(failedQ, true, false, false, false, nil)
        ch.QueueBind(failedQ, routingKey, cfg.FailedExchange, false, nil)
    }
    return nil
}

// internal/amqp/consumer.go: spawn one consumer goroutine per tenant
func (c *Consumer) Start(ctx context.Context, tenants []string) error {
    var wg sync.WaitGroup
    for _, t := range tenants {
        ch, _ := c.conn.Channel()
        ch.Qos(c.cfg.Prefetch, 0, false)
        queueName := fmt.Sprintf("%s-%s", c.cfg.WorkerQueuePrefix, t)
        deliveries, _ := ch.Consume(queueName, "", false, false, false, false, nil)

        wg.Add(1)
        go c.consumeTenant(ctx, t, ch, deliveries, &wg)
    }
    wg.Wait()
    return nil
}

// internal/tenants/discovery.go: NEW package — query packml_register for active tenants
func DiscoverFromDB(ctx context.Context, pool *pgxpool.Pool) ([]string, error) {
    rows, err := pool.Query(ctx, `
        SELECT DISTINCT lower(split_part(packml_topic, '/', 1)) AS tenant
        FROM packml_register
        WHERE active = true
        ORDER BY 1
    `)
    // ... scan into []string ...
}
```

---

## 12. Open questions / followups

1. **Catch-all queue for unrouted tenants** — ✅ **DECIDED v2**: yes,
   ship from day 1 (see §10 Phase 1). Bound to `sparkplug.data.*` on
   the source exchange. Worker does NOT consume it — it's an alarm
   reservoir, not a processing path. Grafana alert on
   `rabbitmq_queue_messages{queue="oeecloud-worker-q-unrouted"} > 0`.
2. **RabbitMQ Prometheus exporter** — needed for per-tenant queue-depth
   panel. Filed separately (not in this design's scope).
3. **Dynamic tenant addition without restart** — periodic poll vs
   trigger-on-DB-NOTIFY vs CS Admin → SSM restart hook. Deferred until
   we hit the case where restart is unacceptable.
4. **Tenant-scoped CPU/memory limits** — if a tenant's traffic
   patterns require their own container, that's the upgrade from
   "one process N channels" to "N processes one channel each". Same
   topology, just split deployments.
5. **Composition with Strategy A** — when WORKER_POOL_SIZE > 1, each
   per-tenant consumer spawns N goroutines for *its own* deliveries
   channel. Per-tenant chanMu means no cross-tenant lock contention.
6. **Should mirror-worker-go also adopt this?** Almost certainly yes —
   same architectural shape, same tenant identity question (it polls
   prod's user_logs by enterprise_id, so its "tenant" is already
   enterprise_id; routing is mostly internal). Filed for future MW-3.
7. **Deactivated tenant cleanup** — when a tenant is marked
   `active=false` in `packml_register`, their AMQP queues still exist
   and can still accumulate messages if a stale publisher exists.
   Not deleting queues automatically (too destructive — could lose
   un-drained messages). Add an alert on stale-tenant queue depth
   instead. Documented in operator runbook.

---

## 13. Composition with Strategy A

Strategy A and Strategy C answer different questions and **stack
cleanly**:

```
                        Strategy C (queue-per-tenant)
                                  │
   ┌──────────────────────────────┼──────────────────────────────┐
   ▼                              ▼                              ▼
 oeecloud-worker-q-cpack      oeecloud-worker-q-acme          ...
   │                              │
   ▼                              ▼
 Channel[cpack]              Channel[acme]
   │                              │
   ▼  Strategy A inside this lane ▼
 N goroutines reading           N goroutines reading
 from CPACK's deliveries        from ACME's deliveries
 + per-Channel chanMu           + per-Channel chanMu
```

Strategy C provides **tenant isolation**; Strategy A provides
**per-tenant throughput**. At production scale:

- ≥100 msg/s sustained for CPACK → bump CPACK's worker pool to N=4
- Acme stays at N=1 if quiet
- The two run in **independent** goroutine sets, with independent
  mutexes, on independent Channels.

The `WORKER_POOL_SIZE` env var grows to potentially `WORKER_POOL_SIZE_{TENANT}`
overrides — but for staging shipping today we use a single global.

---

## 14. References

- `internal/sparkplug/parse.go:120` — `parts[0]` is the group_id used
  for tenant routing
- `internal/amqp/topology.go:65-104` — current single-queue declaration
  (becomes per-tenant in the new design)
- `internal/amqp/consumer.go:175-190` — current single-goroutine
  consumer (becomes one per tenant)
- `internal/config/config.go:16` — Config struct that needs the
  tenant-discovery fields
- [[strategy-a-worker-pool|Strategy A — bounded worker pool]] — sibling
  design that composes inside each tenant's consumer
- [[../../../grafana/dashboards/08-oeecloud-worker.json]] — dashboard
  that grows the `$tenant` template variable
- [[../../../monitoring/prometheus/prometheus.yml]] — scrape config
  that needs `metric_relabel_configs` to extract tenant from routing_key
- Industry reference: Kafka **consumer groups + partition keys** are
  the moral equivalent. Per-tenant queues = "Kafka topic with key-based
  partitioning", per-tenant consumer goroutines = "consumer in a group".
  We're building the AMQP-shaped version of the same pattern.

---

## 15. Review log

### v1 (2026-06-24, initial)

First-pass design after the staging-ready-for-10 decision. Core
topology + tenant identity + consumer shape locked.

### v1 → v2 (2026-06-24, same-day self-review)

Same discipline as Strategy A v2's post-write review. Found 6 real
issues; all fixed inline.

1. **Phase 2 migration ordering bug** (§10) — said "remove `#` binding
   from legacy queue at cutover" but didn't specify that the unbind
   must happen *before* the publisher cutover. Otherwise messages
   double-route (legacy `#` AND per-tenant binding both match the
   new key). Fixed with explicit ordered sequence + alternative
   zero-loss path.

2. **Catch-all queue deferred → decided** (§12.1) — v1 deferred this
   as an open question. v2 commits: ship from day 1, bound to
   `sparkplug.data.*`, worker doesn't consume, alarm on depth > 0.
   This catches misconfigured publishers, newly-onboarded tenants
   between worker restarts, and routing-key typos — all symptoms
   that would otherwise be silent message loss.

3. **Phase 1 ordering for multiple tenants** (§10) — v1 didn't make
   clear that Phase 1 must declare queues for *all* active tenants
   before Phase 2 begins. Otherwise a tenant whose queue isn't
   declared yet has Phase 2 traffic dropped. Explicit precondition
   added.

4. **Connection reconnect semantics missed** (§2) — added Constraint
   7: N Channels share one Connection; reconnect must re-establish
   all N atomically. Partial recovery = silent tenants.

5. **DB unreachable at startup policy** (§2) — added Constraint 8:
   retry with exponential backoff up to 5 min, then crash (Docker
   restarts). Don't proceed with an empty tenant list.

6. **Deactivated tenant cleanup** (§12.7) — added: when a tenant is
   `active=false`, their queue keeps existing (we don't auto-delete
   to avoid losing in-flight messages); alert on stale queue depth
   instead. Operator runbook documents the cleanup path.

**Not addressed in v2 (deferred to follow-up):**

- RabbitMQ user permission pattern (§7) needs to be tested against
  the actual broker before shipping. Plan: dry-run in staging
  during Phase 1.
- Periodic DB poll for dynamic tenant discovery (§9) — staying with
  restart-on-onboarding for v1.
- Per-tenant CPU/memory limits via separate containers (§12.4) —
  defer until a specific tenant requires it.

**Process note**: the v2 review caught a real silent-message-loss bug
in the migration plan that v1 had (Phase 2 ordering). Same lesson as
Strategy A v2: 30 min of self-critique is cheaper than a post-cutover
"why did we lose 4 hours of CPACK data?" incident review.
