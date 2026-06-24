# Strategy A — In-Process Worker Pool

Design doc for issue **#41** of the oeecloud-worker scaling roadmap.

> **Status (2026-06-24):** DESIGN-ONLY. Do not ship until a load trigger
> fires. Current load is ~10 msg/s; the single-goroutine ceiling is
> ~252 msg/s, so we have ~25× headroom.

> **Revision (2026-06-24, post-review):** v1 of this doc had a shutdown
> deadlock bug in the pump (§6), wrong arithmetic in §5, hand-waved
> the PgBouncer pool ceiling, and overstated the per-equipment ordering
> guarantee. All fixed inline. See §11 (Review log) for the audit
> trail.

---

## 1. Why this exists

The consumer loop in `internal/amqp/consumer.go` reads deliveries from a
single AMQP channel via a single goroutine and dispatches each one
inline. The handler runs synchronously before the loop pulls the next
delivery. With `prefetch=50` we let RabbitMQ buffer up to 50 unacked
messages, but only one is being **worked** at a time:

```go
case d, ok := <-deliveries:
    if !ok { return errors.New("...") }
    c.handleDelivery(ctx, ch, d)  // ← serial, blocks next pull
```

That gives an effective concurrency of **1**. Throughput ceiling is
`1 / handler_p_avg`. From the live Prometheus data (24h+ window,
~871k deliveries):

| Quantity | Value |
|----------|-------|
| Handler p_avg | ~3.97 ms |
| Single-goroutine ceiling | ~252 msg/s |
| Current sustained load | ~10 msg/s |
| Headroom | ~25× |

When the load trigger fires (≥100 msg/s sustained OR a second live
tenant arrives), Strategy A unblocks the ceiling without changing
RabbitMQ topology or deployment topology.

---

## 2. Constraints — what we must preserve

These are NOT negotiable; the design must keep them intact:

1. **Manual ack semantics** — ack/nack/republish-to-failed must remain
   correct per message. RabbitMQ counts unacked messages toward
   `prefetch`; if we lose a delivery without acking, that slot is gone
   until the connection drops.
2. **DLX retry topology** — nack-requeue=false → `oee-retry` → 30s TTL
   → back to source. Strategy A must not interfere with the retry path.
3. **/metrics + /health surfaces** — Prometheus counters
   (`amqp_deliveries_total{result=…}`, `handler_duration_seconds`)
   must stay accurate. Writer stats on /health must keep working.
4. **Graceful shutdown** — on SIGTERM, in-flight handlers must finish
   before the channel closes. Otherwise unacked messages bounce back
   to source uncleanly.
5. **Memory bound** — staging app EC2 has finite RAM (4 GB total, of
   which docker compose sets `mem_limit=256m` on the worker container).
   Goroutine count must stay bounded.
6. **CPU budget** — the worker container has `cpus: 0.5` (half a CPU)
   in `compose.staging.yml`. At N goroutines with default
   `GOMAXPROCS=NumCPU()`, the Go runtime sees the host's CPU count
   (likely 2) and over-schedules against the CFS quota, burning the
   gain on context switches. **Ship with `GOMAXPROCS=1`** (or
   `go.uber.org/automaxprocs` to auto-derive from cgroups).
7. **PgBouncer transaction-mode** — pgx is forced to
   `QueryExecModeSimpleProtocol` (no prepared statements) to coexist
   with PgBouncer's transaction pooling. This caps per-connection
   throughput by ~10-15%. Already in place; calling out so future
   N-tuning doesn't try to "fix" it.

---

## 3. Concurrency safety audit

The good news: **almost everything is already thread-safe.**

| Component | Mechanism | Safe for parallel handlers? |
|-----------|-----------|-----------------------------|
| `Resolver.cache` | `sync.RWMutex` (resolver.go:45) | ✅ already |
| Counter atomics (`delivered`, `acked`, etc.) | `atomic.Uint64` | ✅ already |
| `pgx` pool | pool hands out per-goroutine conns *— but pool size must be ≥ N or conns queue* | ⚠ size check needed |
| Writers (`equipment_values`, `uns_metrics`, `po_parameter`) | pure builders, no state | ✅ already |
| Prometheus counters/histograms | client-side mutex internal | ✅ already |
| `*slog.Logger` | stdlib goroutine-safe | ✅ already |
| `Dispatcher.handlers` map | read-only after init (built in `Register` calls at startup) | ✅ already |
| `Consumer.lastDelivery` | `atomic.Int64` | ✅ already |
| **AMQP channel send** (ack/nack/publish) | **`*amqp.Channel` is NOT goroutine-safe** | ⚠ **must serialize** |

The one real hazard: `amqp091-go`'s `*Channel` is **not** safe for
concurrent writes. If two handler goroutines call `d.Ack(false)` on the
same channel simultaneously, the protocol framing can interleave and
break the connection.

Two ways to handle this:

- **a)** Wrap channel writes in a `sync.Mutex`. Simple, but every ack
  serializes through one lock.
- **b)** Move ack/nack/publish into a single "writer" goroutine fed by
  a `chan ackDecision`. Lock-free, but adds a channel.

We pick **(a) Mutex**. Ack/nack writes are tiny (one frame each) and
the mutex hold time is microseconds. Pattern is identical to how the
Go stdlib `net/http` package guards `Response.Write` in HTTP/2.

---

## 4. Design — bounded worker pool reading from the AMQP channel

The recommended shape:

```
       ┌────────────────────────────┐
       │ amqp091.Channel.Consume()  │
       │ → <-chan amqp091.Delivery  │
       └─────────────┬──────────────┘
                     │
        ┌────────────┼────────────┬──────────┐
        ▼            ▼            ▼          ▼
   worker[0]    worker[1]    worker[2]   worker[N-1]
   (goroutine)  (goroutine)  (goroutine) (goroutine)
        │            │            │          │
        └────────────┴─────┬──────┴──────────┘
                           ▼
            ┌───────────────────────────────┐
            │ ch.mu.Lock() ... ack/nack ... │
            └───────────────────────────────┘
```

`N` goroutines all read from the same `<-chan amqp091.Delivery`. Go
guarantees fan-out from a single channel reader to N receivers via
`select` — each `<-deliveries` operation atomically claims one
delivery. RabbitMQ doesn't care that multiple goroutines read; the
ack on the original `amqp091.Delivery` is bound to the channel that
delivered it, which is still the single Channel we hold.

**Why this shape over alternatives:**

| Alternative | Why we rejected it |
|-------------|--------------------|
| `go c.handleDelivery(...)` (unbounded) | No goroutine cap. Stalled handlers (DB outage) could spawn thousands of pending goroutines exhausting RAM. |
| Partition-by-equipment-id | Adds complexity for a problem we mostly don't have today: writers UPSERT by `(ts_value, id_equipment)` and write disjoint columns per message kind, so concurrent execution rarely produces a "wrong" final state. **Residual race**: two messages with the same `(ts_value, id_equipment)` AND same column (rare — Sparkplug coalescing usually makes this not happen) can land in either order; for monotonic counters this gives either snapshot value, both downstream-correct. **Becomes load-bearing** only if a future writer adds read-modify-write semantics — that's the trigger to reconsider this. |
| Per-tenant queues (Strategy C) | Different problem (isolation between tenants, not throughput). Out of scope for #41. |
| Single ack-writer goroutine (option B from §3) | Lock-free but adds latency (chan send + receive + dispatch per ack) and complexity. Mutex contention at our ack rate is negligible — picked simpler design. Revisit if mutex shows up in profiling. |

---

## 5. Sizing N — how many workers?

Three upper bounds, in order of how-hard-they-bind:

- **Prefetch ceiling** — Rabbit will only hand out up to
  `prefetch` unacked messages at once. With `prefetch=50` we cap at
  50 in-flight; more workers than 50 just sit idle.
- **PgBouncer pool ceiling** (the *real* bottleneck) — PgBouncer is
  in transaction mode with `DEFAULT_POOL_SIZE=5` **server-side**
  conns. That's the true ceiling regardless of how many client conns
  we open. The worker shares those 5 server slots with **edge-api,
  simulator, mirror-worker, mirror-worker-go** — five clients
  competing for five server conns. At N worker goroutines all calling
  `SendBatch` simultaneously, we'll queue at the PgBouncer side.
  `MAX_CLIENT_CONN=100` controls how big the queue can be before
  PgBouncer refuses connections — not how many can run concurrently.
- **CPU budget** — container has `cpus: 0.5`. With `GOMAXPROCS=1`
  (recommended, per Constraint 6), the runtime won't try to schedule
  more than one OS thread; goroutines time-slice via Go's
  cooperative scheduler. DB-bound handlers spend most of their time
  in syscall wait, so N>1 still helps — but the gain is sublinear
  much faster than on a 4-CPU host.

Realistic per-N expected throughput (rule-of-thumb, real measurement
required before shipping):

| N | Ideal (N / p_avg) | Realistic (PgBouncer + GOMAXPROCS=1) | Notes |
|---|---|---|---|
| 1 | 252 msg/s | ~250 msg/s (measured) | Today's state |
| 2 | 500 msg/s | ~450 msg/s | Likely linear (DB pool not yet saturated) |
| 4 | 1000 msg/s | ~700-800 msg/s | Probable PgBouncer queue pressure begins |
| 8 | 2000 msg/s | ~900-1100 msg/s | Likely flat — needs dedicated PgBouncer slice to push higher |

So `N` should be `min(prefetch, sane_pgbouncer_share)`. Reasonable
defaults to ship with:

| Scenario | Recommended N | Reasoning |
|----------|---------------|-----------|
| Today (1 tenant, 10 msg/s) | 1 (current) | 25× headroom; no need |
| ≥100 msg/s sustained | 4 | ~10× margin from trigger; well below PgBouncer saturation |
| 2+ tenants, < 100 msg/s | 4 | Same N; lets bursty tenants not starve quiet ones |
| ≥500 msg/s sustained | 8 + dedicated PgBouncer pool slice | Worker gets its own `pool_size` block in PgBouncer config; sized to ~10 |

Knob exposed as env var `WORKER_POOL_SIZE`, default `1` (== current
behavior, opt-in). Adding the knob is the first concrete change; the
default-`1` keeps shipping safe.

---

## 6. Implementation sketch (NOT to be shipped now)

The diff is small. In `consumer.go`, replace the single loop with N
loop goroutines sharing the channel + a mutex around channel writes:

```go
// pseudocode — actual impl reuses c.handleDelivery + c.chanMu
func (c *Consumer) consume(ctx context.Context, ch *amqp091.Channel,
    deliveries <-chan amqp091.Delivery, closeCh chan *amqp091.Error) error {

    var chanMu sync.Mutex
    var wg sync.WaitGroup

    workCh := make(chan amqp091.Delivery)
    defer func() { close(workCh); wg.Wait() }() // shutdown drain — runs on every exit

    // Worker goroutines
    for i := 0; i < c.cfg.PoolSize; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            for d := range workCh {
                c.handleDeliveryLocked(ctx, ch, &chanMu, d)
            }
        }()
    }

    // Pump deliveries → workers.
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case e := <-closeCh:
            if e == nil { return nil }
            return fmt.Errorf("channel closed: %w", e)
        case d, ok := <-deliveries:
            if !ok { return errors.New("delivery channel closed") }
            // NESTED select on the workCh send — without this, the pump
            // can block here forever if all workers are saturated AND
            // ctx cancels in the meantime.  v1 of this doc had the bare
            // `workCh <- d` and was deadlock-prone on shutdown.
            select {
            case <-ctx.Done():
                return ctx.Err()
            case workCh <- d:
            }
        }
    }
}
```

`handleDeliveryLocked` is `handleDelivery` with `chanMu.Lock()` /
`Unlock()` around the three places we touch the channel (publish to
failed-exchange, `Ack`, `Nack`).

The intermediate `workCh` (unbuffered) means "no work is queued in
the pump beyond what a worker is already handling." Backpressure
flows back to the deliveries channel which flows back to Rabbit
naturally via prefetch.

If `PoolSize=1`, this is effectively the current behavior plus a
mutex — the loop reads from `workCh`, the worker reads from `workCh`,
they ping-pong. Negligible overhead.

---

## 7. Benchmark plan

Before shipping the impl, run a benchmark to confirm scaling is real
(Amdahl's law eats early throughput gains if there's hidden
serialization).

**Commit to ONE approach: testcontainers-go + real Postgres.** Mock
benchmarks only measure coordination overhead and are misleading
because the bottleneck (PgBouncer share) is downstream of the worker.

```
services/oeecloud-worker/internal/amqp/consumer_bench_test.go
```

Setup per benchmark run:
1. `testcontainers-go` spins up Timescale + populated `packml_register`.
2. Manually start a PgBouncer container in front (transaction mode,
   `pool_size=5` mirroring staging).
3. Feed N pre-built Sparkplug payloads into a mock AMQP channel.
4. Time `BenchmarkConsume_PoolN` for N ∈ {1, 2, 4, 8, 16}.

Expected curve (rule-of-thumb, see §5 table):

```
N=1   →  ~250 msg/s   (baseline)
N=2   →  ~450 msg/s
N=4   →  ~700-800 msg/s
N=8   →  ~900-1100 msg/s    (flat — PgBouncer saturated, need slice)
```

If you see flat-from-N=2, profile for hidden serialization (`go tool
pprof` mutex profile + block profile). The likely culprit then is the
`chanMu` (unlikely to dominate at our ack rate) or PgBouncer queue
depth (much more likely).

Manual run, not in CI — testcontainers is too slow/flaky for default
CI. Required only before shipping a new N default.

---

## 8. Triggers — when to ship this

Per the scaling roadmap:

- **≥100 msg/s sustained over 1h** (load trigger)
- **≥2nd active tenant in `packml_register`** (multi-tenancy trigger)

Watch via the new Prometheus dashboard (`08-oeecloud-worker`):

- `rate(oeecloud_worker_amqp_delivered_total[5m])` — current rate
- Active tenants: query `packml_register WHERE active=true GROUP BY
  enterprise_id` (no Prometheus exporter for this yet — manual SQL check)

**Concrete alert rule to ship alongside Strategy A**:

```yaml
# grafana/alerts/oeecloud-worker-load.yml (future)
expr: avg_over_time(rate(oeecloud_worker_amqp_acked_total[5m])[1h:5m]) > 100
for: 30m
labels: { severity: action_required }
annotations:
  summary: "oeecloud-worker > 100 msg/s sustained — time to consider WORKER_POOL_SIZE bump"
```

Don't ship preemptively. The default-`1` change is no-op; the value
of having Strategy A coded is that when a trigger fires, deploy is
~1 hour, not ~1 day.

---

## 9. Open questions / followups

1. **Should `WORKER_POOL_SIZE` be a config or auto-derived?** Auto-deriving
   from `runtime.NumCPU()` is tempting but misleading — the bottleneck
   is the DB pool, not CPU. Keep it explicit.
2. **PgBouncer pool sizing** — at N=8+, the worker may saturate its
   share of `DEFAULT_POOL_SIZE=5`. Need to negotiate a dedicated
   pool slice when we ship.
3. **Per-equipment ordering** — re-audit if/when we add writers that
   do read-modify-write (e.g., decrement counters or stateful
   aggregations). Today all writers are UPSERT-idempotent.
4. **What about `mirror-worker-go`?** Same architecture, same single-
   consumer-loop pattern, same scaling answer. Once oeecloud-worker
   ships Strategy A, mirror-worker-go gets it for ~half-day porting
   cost.
5. **Pool stats on /metrics** — add `oeecloud_worker_pool_size`
   (gauge), `oeecloud_worker_pool_active` (gauge for in-flight
   workers). The /metrics surface is the source of truth for "did
   the impl actually do what we said it would."
6. **Hot-reload of pool size?** No — startup config only. Avoids the
   "what does increasing N do to in-flight messages" question. Bump
   via `WORKER_POOL_SIZE` env + container restart.
7. **Tracing context propagation** — each goroutine could carry a
   trace span ID (OpenTelemetry) to make latency drill-down easier.
   Deferred — we don't have a tracing backend deployed yet.
8. **AMQP heartbeat behavior under N saturation** — amqp091-go runs
   the heartbeat on its own goroutine, separate from consumer
   delivery. Even if all N workers stall on DB, the heartbeat keeps
   the connection alive. Worth verifying with a fault-injection test
   (DB pause for 30s, observe heartbeat continues) before shipping.

---

## 10. References

- `internal/amqp/consumer.go:175-190` — current single-goroutine loop
- `internal/amqp/consumer.go:202-298` — `handleDelivery` (what becomes
  `handleDeliveryLocked`)
- `internal/sparkplug/resolver.go:45` — RWMutex-guarded cache already
  in place
- `internal/handlers/sparkplug.go:68-127` — per-delivery batch shape
  (multi-metric, one round-trip)
- [[../../../grafana/dashboards/08-oeecloud-worker.json]] — the
  dashboard that surfaces when triggers fire
- Industry reference: Kafka consumer groups partition-by-key is the
  "Strategy C" of this design. Kafka's choice of per-partition single-
  consumer + multi-partition fan-out is what we'd evolve toward at
  much higher scale (~thousands of msg/s).

---

## 11. Review log

### v1 → v2 (2026-06-24, same-day post-write review)

Self-critique pass found **5 real issues** + 3 smaller ones. All
applied inline. Lessons worth remembering:

1. **Shutdown deadlock bug in §6 pump** — bare `workCh <- d` outside
   a select can deadlock during shutdown if workers are saturated.
   Fix: nested select on `workCh <- d` vs `<-ctx.Done()`. The
   `defer close(workCh); wg.Wait()` pattern at the top of the
   function ensures drain happens on every exit path. *Senior-grade
   pattern: every blocking send in a long-lived goroutine needs
   a cancellation escape.*
2. **Hand-waved PgBouncer share** — said "~10 DB conns" without
   measuring. Reality: PgBouncer transaction-mode pool is 5 server
   conns shared with 4 other services. The ceiling isn't connection
   count, it's queue depth at PgBouncer. Updated §5 with realistic
   bounds + a per-N expected throughput table.
3. **Arithmetic error in §5 table** — "4 × 252 / 4 ≈ 252 msg/s"
   was nonsense. Fixed to per-N realistic estimates.
4. **Overstated per-equipment ordering safety** — claimed UPSERT
   makes ordering "not matter"; actually it makes *exact duplicates*
   idempotent. Same `(ts_value, id_equipment)` + same column from
   two messages still races (rare; bounded; downstream-correct for
   monotonic counters). Re-framed as a *constraint on future
   writers* rather than a property of message ordering.
5. **Missing CPU-budget constraint** — container has `cpus: 0.5`;
   default GOMAXPROCS=NumCPU() over-schedules against the CFS quota.
   Added Constraint 6: ship with `GOMAXPROCS=1` or `automaxprocs`.

Smaller fixes:
- Added `*slog.Logger`, `Dispatcher.handlers` to the safety audit.
- Flagged pgx pool size ≥ N requirement.
- Added single-ack-writer alternative to §4 rejection table.
- Picked testcontainers-go for §7 (committed to one approach).
- Added a concrete PromQL alert rule in §8.
- Three new entries in §9 open questions (hot-reload, tracing, heartbeat behavior).

**Process note** — this self-review took ~30 minutes and found a
deadlock bug that would have shipped in v1. The lesson is the same
one I wrote about in [[../../../zettel/observe-then-port-vs-port-then-deprecate]]:
write the design, *then* attack it from the user's-going-to-find-this-bug
angle BEFORE shipping. Cheaper than the post-incident review.
