// Package amqp owns the fan-out consumer: it binds a durable queue to the SOURCE
// tenant's routing key(s) on the `oee` topic exchange, re-tenants each delivery
// (retenant.Retenant), and republishes the clone on the TARGET tenant's routing
// key so the target's oeecloud-worker queue writes its enterprise's F3 rows.
//
// # No self-feedback loop
//
// The consumer binds `sparkplug.data` and `sparkplug.data.<source>` (both EXACT
// keys — a topic exchange without wildcards matches only the literal key). It
// republishes to `sparkplug.data.<target>`, which equals NEITHER binding, so the
// clone is never delivered back to this queue. The retenant transform's
// ownership check (group==source) is a second guard: even a hypothetical
// loop-back (group==target) is reported not-ours and dropped.
//
// # No double-count
//
// The clone is published ONLY to the target key. The source tenant's own
// pipeline (its legacy/per-tenant worker queue, a SEPARATE queue also bound to
// the source key — the exchange fans a COPY to each bound queue) is untouched
// and keeps writing the source enterprise's rows exactly once. Source and target
// enterprises have disjoint equipment ids and F3 rows, so the source can never
// be double-counted. This is why a CROSS-tenant fan-out is safe where the
// retired SAME-tenant mirror-worker-go had to be the sole writer.
//
// # Delivery semantics (at-least-once, idempotent)
//
//   - Undecodable body (deterministic poison) → drop + count, never retry.
//   - Not-ours (another tenant on the shared key) → ack (skip), never republish.
//   - Ours → republish with a broker publish-confirm; ack the source ONLY after
//     a confirmed republish. A broker nack/timeout/connection error → the source
//     is nacked with requeue so it is retried. A crash between confirm and ack
//     redelivers the source → a duplicate clone, which is safe because the target
//     worker's writes are UPSERTs (ON CONFLICT) keyed by natural keys.
package amqp

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-fanout/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-fanout/internal/retenant"
	amqp "github.com/rabbitmq/amqp091-go"
)

// Fanout owns one AMQP connection + consume/publish channels + the consume loop.
// Topology is re-declared on every (re)connect so broker restarts self-heal.
type Fanout struct {
	cfg     *config.Config
	amqpURL string
	tcfg    retenant.Config
	logger  *slog.Logger

	// counters — read by /health.
	delivered   atomic.Uint64
	republished atomic.Uint64
	skipped     atomic.Uint64 // not-ours (other tenant) — acked, not republished
	dropped     atomic.Uint64 // undecodable — acked, not republished
	failed      atomic.Uint64 // republish failed → nacked+requeued

	mu           sync.RWMutex
	healthy      bool
	lastErr      string
	startedAt    time.Time
	lastDelivery atomic.Int64 // unix nano
}

func NewFanout(cfg *config.Config, amqpURL string, logger *slog.Logger) *Fanout {
	return &Fanout{
		cfg:       cfg,
		amqpURL:   amqpURL,
		tcfg:      retenant.Config{SourceGroup: cfg.SourceGroup, TargetGroup: cfg.TargetGroup},
		logger:    logger,
		startedAt: time.Now(),
	}
}

// Run blocks until ctx is cancelled, reconnecting with capped backoff+jitter on
// any failure.
func (f *Fanout) Run(ctx context.Context) error {
	attempt := 0
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		err := f.connectAndConsume(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		f.mu.Lock()
		f.healthy = false
		if err != nil {
			f.lastErr = err.Error()
		}
		f.mu.Unlock()
		if err != nil {
			attempt++
			delay := backoff(attempt)
			f.logger.Warn("fanout connection failed, retrying",
				slog.String("err", err.Error()),
				slog.Duration("delay", delay),
				slog.Int("attempt", attempt))
			select {
			case <-time.After(delay):
			case <-ctx.Done():
				return ctx.Err()
			}
		} else {
			attempt = 0
		}
	}
}

func backoff(attempt int) time.Duration {
	const maxDelay = 30 * time.Second
	base := time.Duration(1<<min(attempt, 5)) * time.Second
	if base > maxDelay {
		base = maxDelay
	}
	factor := 0.75 + rand.Float64()*0.5
	return time.Duration(float64(base) * factor)
}

// connectAndConsume does one dial → declare → consume cycle. Returns when the
// channel drops (nil on clean close) or ctx cancels.
func (f *Fanout) connectAndConsume(ctx context.Context) error {
	conn, err := amqp.Dial(f.amqpURL)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	if err := f.declareTopology(conn); err != nil {
		return fmt.Errorf("topology: %w", err)
	}

	// Dedicated publish channel in confirm-select mode. Separate from the
	// consume channel so publish confirms never interleave with consume acks.
	pubCh, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("publish channel: %w", err)
	}
	defer pubCh.Close()
	if err := pubCh.Confirm(false); err != nil {
		return fmt.Errorf("enable publish confirms: %w", err)
	}
	confirms := pubCh.NotifyPublish(make(chan amqp.Confirmation, 1))

	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("consume channel: %w", err)
	}
	defer ch.Close()
	if err := ch.Qos(f.cfg.Prefetch, 0, false); err != nil {
		return fmt.Errorf("qos: %w", err)
	}
	deliveries, err := ch.Consume(f.cfg.FanoutQueue, "", false, false, false, false, nil)
	if err != nil {
		return fmt.Errorf("consume %s: %w", f.cfg.FanoutQueue, err)
	}

	f.mu.Lock()
	f.healthy = true
	f.lastErr = ""
	f.mu.Unlock()
	f.logger.Info("fanout consuming",
		slog.String("queue", f.cfg.FanoutQueue),
		slog.Any("source_routing_keys", f.cfg.SourceRoutingKeys),
		slog.String("target_routing_key", f.cfg.TargetRoutingKey),
		slog.String("source_group", f.cfg.SourceGroup),
		slog.String("target_group", f.cfg.TargetGroup),
		slog.Int("prefetch", f.cfg.Prefetch))

	closeCh := ch.NotifyClose(make(chan *amqp.Error, 1))
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case e := <-closeCh:
			if e == nil {
				return nil
			}
			return fmt.Errorf("consume channel closed: %w", e)
		case d, ok := <-deliveries:
			if !ok {
				return fmt.Errorf("delivery channel closed")
			}
			f.handle(ctx, pubCh, confirms, &d)
		}
	}
}

// declareTopology asserts the source exchange (idempotent), the durable fan-out
// queue, and its binding(s) to the source routing key(s).
func (f *Fanout) declareTopology(conn *amqp.Connection) error {
	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("topology channel: %w", err)
	}
	defer ch.Close()

	// The `oee` exchange is owned by the worker/transformer; declaring it topic
	// + durable is idempotent and matches their declaration.
	if err := ch.ExchangeDeclare(f.cfg.SourceExchange, "topic", true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare exchange %s: %w", f.cfg.SourceExchange, err)
	}
	// Durable queue, no DLX: an undecodable body is dropped in-handler (never
	// nacked) and a transient publish failure is requeued in-place, so there is
	// no poison path that needs a dead-letter queue.
	if _, err := ch.QueueDeclare(f.cfg.FanoutQueue, true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare queue %s: %w", f.cfg.FanoutQueue, err)
	}
	for _, rk := range f.cfg.SourceRoutingKeys {
		if err := ch.QueueBind(f.cfg.FanoutQueue, rk, f.cfg.SourceExchange, false, nil); err != nil {
			return fmt.Errorf("bind %s → %s (%s): %w", f.cfg.FanoutQueue, rk, f.cfg.SourceExchange, err)
		}
	}
	f.logger.Info("fanout topology declared",
		slog.String("exchange", f.cfg.SourceExchange),
		slog.String("queue", f.cfg.FanoutQueue),
		slog.Any("bindings", f.cfg.SourceRoutingKeys))
	return nil
}

// handle processes one delivery: drop (undecodable), skip (not-ours), or
// re-tenant + republish + ack.
func (f *Fanout) handle(ctx context.Context, pubCh *amqp.Channel, confirms <-chan amqp.Confirmation, d *amqp.Delivery) {
	f.delivered.Add(1)
	f.lastDelivery.Store(time.Now().UnixNano())

	out, ours, err := retenant.Retenant(d.Body, f.tcfg)
	if err != nil {
		// Deterministic poison — the bytes are fixed, retry can't help. Drop.
		if n := f.dropped.Add(1); n%64 == 1 {
			f.logger.Warn("fanout: undecodable envelope — dropping (sampled 1/64)",
				slog.String("routing_key", d.RoutingKey),
				slog.Int("body_len", len(d.Body)),
				slog.String("err", err.Error()))
		}
		_ = d.Ack(false)
		return
	}
	if !ours {
		// Another tenant's traffic on the shared `sparkplug.data` binding, or an
		// already-target message. Ack without republishing — the core
		// no-cross-contamination guard.
		f.skipped.Add(1)
		_ = d.Ack(false)
		return
	}

	if err := f.republish(ctx, pubCh, confirms, out); err != nil {
		f.failed.Add(1)
		// Requeue for retry — writes downstream are idempotent so a duplicate is
		// safe. A tiny sleep throttles a hot-loop during a sustained broker issue.
		_ = d.Nack(false, true)
		f.logger.Warn("fanout: republish failed, nacked+requeued",
			slog.String("target_routing_key", f.cfg.TargetRoutingKey),
			slog.String("err", err.Error()))
		select {
		case <-time.After(250 * time.Millisecond):
		case <-ctx.Done():
		}
		return
	}
	f.republished.Add(1)
	if ackErr := d.Ack(false); ackErr != nil {
		f.logger.Error("fanout: ack failed after republish", slog.String("err", ackErr.Error()))
	}
}

// republish publishes the re-tenanted body to the target routing key and waits
// for the broker's publish confirm. Returns an error on nack/timeout so the
// caller requeues the source delivery.
func (f *Fanout) republish(ctx context.Context, pubCh *amqp.Channel, confirms <-chan amqp.Confirmation, body []byte) error {
	timeout := time.Duration(f.cfg.PublishConfirmTimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	if err := pubCh.PublishWithContext(ctx, f.cfg.SourceExchange, f.cfg.TargetRoutingKey, false, false,
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent,
			Body:         body,
		}); err != nil {
		return fmt.Errorf("publish: %w", err)
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case c, ok := <-confirms:
		if !ok {
			return fmt.Errorf("confirms channel closed")
		}
		if !c.Ack {
			return fmt.Errorf("broker nacked publish")
		}
		return nil
	case <-timer.C:
		return fmt.Errorf("publish confirm timeout after %s", timeout)
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Snapshot renders the /health JSON body + healthy flag.
type snapshot struct {
	Healthy           bool   `json:"healthy"`
	StartedAt         string `json:"started_at"`
	LastError         string `json:"last_error,omitempty"`
	Delivered         uint64 `json:"delivered"`
	Republished       uint64 `json:"republished"`
	Skipped           uint64 `json:"skipped_other_tenant"`
	Dropped           uint64 `json:"dropped_undecodable"`
	Failed            uint64 `json:"republish_failed"`
	SourceGroup       string `json:"source_group"`
	TargetGroup       string `json:"target_group"`
	TargetRoutingKey  string `json:"target_routing_key"`
	LastDeliveryAgoMs int64  `json:"last_delivery_ago_ms,omitempty"`
}

func (f *Fanout) Snapshot() ([]byte, bool, error) {
	f.mu.RLock()
	s := snapshot{
		Healthy:          f.healthy,
		StartedAt:        f.startedAt.UTC().Format(time.RFC3339),
		LastError:        f.lastErr,
		Delivered:        f.delivered.Load(),
		Republished:      f.republished.Load(),
		Skipped:          f.skipped.Load(),
		Dropped:          f.dropped.Load(),
		Failed:           f.failed.Load(),
		SourceGroup:      f.cfg.SourceGroup,
		TargetGroup:      f.cfg.TargetGroup,
		TargetRoutingKey: f.cfg.TargetRoutingKey,
	}
	healthy := f.healthy
	f.mu.RUnlock()
	if last := f.lastDelivery.Load(); last > 0 {
		s.LastDeliveryAgoMs = (time.Now().UnixNano() - last) / int64(time.Millisecond)
	}
	body, err := json.Marshal(s)
	if err != nil {
		return nil, false, fmt.Errorf("marshal snapshot: %w", err)
	}
	return body, healthy, nil
}
