# Strategy A — In-Process Worker Pool

Design doc for issue **#41** of the oeecloud-worker scaling roadmap.

> **Status (2026-06-24):** DESIGN-ONLY. Do not ship until a load trigger
> fires. Current load is ~10 msg/s; the single-goroutine ceiling is
> ~252 msg/s, so we have ~25× headroom.

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

---

## 3. Concurrency safety audit

The good news: **almost everything is already thread-safe.**

| Component | Mechanism | Safe for parallel handlers? |
|-----------|-----------|-----------------------------|
| `Resolver.cache` | `sync.RWMutex` (resolver.go:45) | ✅ already |
| Counter atomics (`delivered`, `acked`, etc.) | `atomic.Uint64` | ✅ already |
| `pgx` pool | pool hands out per-goroutine conns | ✅ already |
| Writers (`equipment_values`, `uns_metrics`, `po_parameter`) | pure builders, no state | ✅ already |
| Prometheus counters/histograms | client-side mutex internal | ✅ already |
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
| Partition-by-equipment-id | Adds complexity for a problem we don't have: per-equipment ordering doesn't matter (writers UPSERT by `(ts_value, id_equipment)` which is monotonic from PLC, ON CONFLICT makes duplicates idempotent). Reconsider only if a future write surface introduces non-idempotent state. |
| Per-tenant queues (Strategy C) | Different problem (isolation between tenants, not throughput). Out of scope for #41. |

---

## 5. Sizing N — how many workers?

Two upper bounds:

- **Prefetch ceiling** — Rabbit will only hand out up to
  `prefetch` unacked messages at once. With `prefetch=50` we cap at
  50 in-flight; more workers than 50 just sit idle waiting for the
  channel.
- **DB pool ceiling** — every concurrent handler holds a `pgx`
  connection during its `Batch.SendBatch()`. PgBouncer is configured
  `MAX_CLIENT_CONN=100`, `DEFAULT_POOL_SIZE=5` (transaction-mode). The
  worker shares this pool with edge-api + simulator. Real ceiling is
  whatever fraction we're entitled to — call it ~10 connections.

So `N` should be `min(prefetch, db_pool_share)`. Reasonable defaults:

| Scenario | Recommended N | Reasoning |
|----------|---------------|-----------|
| Today (1 tenant, 10 msg/s) | 1 (current) | No need |
| ≥100 msg/s sustained | 4 | 4 × 252 / 4 ≈ 252 msg/s with comfortable per-worker latency |
| 2+ tenants, < 100 msg/s | 4 | Same reasoning; lets bursty tenants not starve quiet ones |
| ≥500 msg/s sustained | 8 (and reconsider Strategy C) | Approaches pgx pool cap; needs PgBouncer pool review |

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

    // Pump deliveries → workers. Drains workCh on shutdown.
    for {
        select {
        case <-ctx.Done():
            close(workCh)
            wg.Wait()
            return ctx.Err()
        case e := <-closeCh:
            close(workCh)
            wg.Wait()
            if e == nil { return nil }
            return fmt.Errorf("channel closed: %w", e)
        case d, ok := <-deliveries:
            if !ok {
                close(workCh)
                wg.Wait()
                return errors.New("delivery channel closed")
            }
            workCh <- d
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

Before shipping the impl, run an isolated benchmark to confirm scaling
is real (Amdahl's law eats early throughput gains if there's hidden
serialization).

```
services/oeecloud-worker/internal/amqp/consumer_bench_test.go
```

The benchmark feeds N pre-built Sparkplug payloads into a mock channel
and times `BenchmarkConsume_PoolN` for N ∈ {1, 2, 4, 8, 16}.

Expected curve: roughly linear up to ~4 (handler is mostly DB-bound, so
parallel DB writes scale until pgx pool saturates), then sublinear, then
flat at ~8-10 depending on pool tuning.

Real benchmark needs the staging DB or a pgx-mock; if the latter, we're
benchmarking the *coordination overhead*, not the real ceiling. The
former is more honest but harder to run in CI. Start with mock for
unit tests, run real benchmark manually before shipping.

---

## 8. Triggers — when to ship this

Per the scaling roadmap:

- **≥100 msg/s sustained over 1h** (load trigger)
- **≥2nd active tenant in `packml_register`** (multi-tenancy trigger)

Watch via the new Prometheus dashboard (`08-oeecloud-worker`):

- `rate(oeecloud_worker_amqp_delivered_total[5m])` — current rate
- Active tenants: query `packml_register WHERE active=true GROUP BY
  enterprise_id`

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
