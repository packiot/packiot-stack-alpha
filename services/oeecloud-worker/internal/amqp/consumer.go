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

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/handlers"
	amqp "github.com/rabbitmq/amqp091-go"
	"golang.org/x/sync/errgroup"
)

// Consumer owns the lifecycle of a single AMQP connection + channel +
// consume loop. Re-establishes the topology + consumer on every connect
// so broker restarts heal automatically.
type Consumer struct {
	cfg        *config.Config
	amqpURL    string // built from secrets at startup; not in cfg to keep cfg secret-free
	dispatcher *handlers.Dispatcher
	logger     *slog.Logger

	// tenants is the snapshot of active group_ids resolved at startup
	// (via tenants.DiscoverActive on packml_register). Used by
	// DeclareTopology to declare per-tenant queues + bindings on each
	// reconnect — same list reused; new tenants require a worker restart
	// (Strategy C v1 behaviour, see strategy-c-per-tenant-queues.md §6).
	tenants []string

	// Optional callback letting writers contribute to /health JSON
	// without forcing Consumer to import the writers package. main wires
	// it; nil means "no writers section".
	writerStats func() any

	// Optional Prometheus hooks — nil-safe. Set via SetMetrics.
	// Same decoupling pattern as writerStats: amqp doesn't import metrics.
	metricsDeliveries func(routingKey, result string)
	metricsDuration   func(routingKey string, seconds float64)

	// Metrics — read by /health for the JSON body.
	delivered     atomic.Uint64
	acked         atomic.Uint64
	nackedRetry   atomic.Uint64
	publishedFail atomic.Uint64
	lastDelivery  atomic.Int64 // unix nano

	// Liveness — set when the consume loop is actively reading the channel.
	// Set false during reconnect; read by /health.
	mu        sync.RWMutex
	healthy   bool
	lastErr   string
	startedAt time.Time
}

func NewConsumer(cfg *config.Config, amqpURL string, d *handlers.Dispatcher, tenants []string, logger *slog.Logger) *Consumer {
	return &Consumer{
		cfg:        cfg,
		amqpURL:    amqpURL,
		dispatcher: d,
		tenants:    tenants,
		logger:     logger,
		startedAt:  time.Now(),
	}
}

// SetWriterStats registers a callback that returns any JSON-marshalable
// value to embed under the "writers" key of /health. Call before Run.
func (c *Consumer) SetWriterStats(fn func() any) { c.writerStats = fn }

// SetMetrics wires Prometheus recording callbacks. Both args may be nil.
// Call before Run.
func (c *Consumer) SetMetrics(deliveries func(routingKey, result string), duration func(routingKey string, seconds float64)) {
	c.metricsDeliveries = deliveries
	c.metricsDuration = duration
}

// Snapshot getter accessors so the metrics package can read counters
// without importing the Snapshot struct or holding a lock-aware copy.
func (c *Consumer) DeliveredCount() uint64         { return c.delivered.Load() }
func (c *Consumer) AckedCount() uint64             { return c.acked.Load() }
func (c *Consumer) NackedToRetryCount() uint64     { return c.nackedRetry.Load() }
func (c *Consumer) PublishedToFailedCount() uint64 { return c.publishedFail.Load() }

// Run blocks until ctx is cancelled. On any connection/channel failure,
// it logs + sleeps with exponential backoff (capped at 30s) and reconnects.
// One Run() call serves the worker for its entire lifetime.
func (c *Consumer) Run(ctx context.Context) error {
	attempt := 0
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		err := c.connectAndConsume(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			c.mu.Lock()
			c.healthy = false
			c.lastErr = err.Error()
			c.mu.Unlock()
			attempt++
			delay := backoff(attempt)
			c.logger.Warn("amqp connection failed, retrying",
				slog.String("err", err.Error()),
				slog.Duration("delay", delay),
				slog.Int("attempt", attempt),
			)
			select {
			case <-time.After(delay):
			case <-ctx.Done():
				return ctx.Err()
			}
		} else {
			// connectAndConsume returned nil — channel closed cleanly,
			// reset backoff and reconnect immediately.
			attempt = 0
		}
	}
}

func backoff(attempt int) time.Duration {
	// 1s base, doubles to a 30s cap, then ¾–1.25x random jitter to avoid
	// thundering-herd when multiple workers reconnect after a broker
	// restart. Single-worker today but cheap to do correctly.
	const maxDelay = 30 * time.Second
	base := time.Duration(1<<min(attempt, 5)) * time.Second
	if base > maxDelay {
		base = maxDelay
	}
	// rand.Float64() ∈ [0,1) → factor ∈ [0.75, 1.25)
	factor := 0.75 + rand.Float64()*0.5
	return time.Duration(float64(base) * factor)
}

// connectAndConsume does one full dial → declare → consume cycle.
// Returns when ANY consumer goroutine drops (nil for clean close, error
// otherwise). The outer Run() loop then reconnects with backoff.
//
// Strategy C Phase 2a: declares topology on a dedicated channel, then
// spawns one consumer goroutine per queue. Each goroutine owns its own
// AMQP Channel — no cross-tenant lock contention. Channel writes
// (ack/nack/publish) are single-goroutine per Channel so no chanMu
// needed yet (Strategy A adds it when N goroutines share one Channel).
//
// Shutdown: errgroup.WithContext means when ANY goroutine returns an
// error, egctx cancels and the others wind down. eg.Wait returns the
// first error. Conn.Close (defer) closes all Channels.
func (c *Consumer) connectAndConsume(ctx context.Context) error {
	conn, err := amqp.Dial(c.amqpURL)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	// Topology declaration uses its own short-lived channel. Once declared
	// we close it; each consumer opens its own.
	declCh, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("decl channel: %w", err)
	}
	if err := DeclareTopology(ctx, declCh, c.cfg, c.tenants, c.logger); err != nil {
		declCh.Close()
		return fmt.Errorf("topology: %w", err)
	}
	declCh.Close()

	// Build the queue list: legacy first (still receives all current
	// traffic via the `#` binding), then one per tenant (currently empty
	// — receives traffic only after edge-nodered's Phase 2b cutover).
	queues := append([]string{c.cfg.WorkerQueue}, c.perTenantQueueNames()...)

	c.mu.Lock()
	c.healthy = true
	c.lastErr = ""
	c.mu.Unlock()
	c.logger.Info("consuming",
		slog.Any("queues", queues),
		slog.Int("prefetch", c.cfg.Prefetch),
	)

	eg, egctx := errgroup.WithContext(ctx)
	for _, q := range queues {
		queue := q // capture for closure
		eg.Go(func() error {
			return c.consumeOne(egctx, conn, queue)
		})
	}
	return eg.Wait()
}

// consumeOne owns one AMQP Channel + ch.Consume on one queue. Returns
// when its channel drops or ctx cancels.
func (c *Consumer) consumeOne(ctx context.Context, conn *amqp.Connection, queue string) error {
	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("channel for %s: %w", queue, err)
	}
	defer ch.Close()

	if err := ch.Qos(c.cfg.Prefetch, 0, false); err != nil {
		return fmt.Errorf("qos for %s: %w", queue, err)
	}

	// Consumer tag empty → broker generates one. autoAck=false → manual ack.
	deliveries, err := ch.Consume(queue, "", false, false, false, false, nil)
	if err != nil {
		return fmt.Errorf("consume %s: %w", queue, err)
	}

	closeCh := ch.NotifyClose(make(chan *amqp.Error, 1))

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case e := <-closeCh:
			if e == nil {
				return nil // clean close
			}
			return fmt.Errorf("channel closed for %s: %w", queue, e)
		case d, ok := <-deliveries:
			if !ok {
				return fmt.Errorf("delivery channel closed for %s", queue)
			}
			c.handleDelivery(ctx, ch, d)
		}
	}
}

// perTenantQueueNames builds "<prefix>-<tenant>" for every active tenant.
// Matches the queue names declared in DeclareTopology.
func (c *Consumer) perTenantQueueNames() []string {
	out := make([]string, 0, len(c.tenants))
	for _, t := range c.tenants {
		out = append(out, fmt.Sprintf("%s-%s", c.cfg.WorkerQueue, t))
	}
	return out
}

// handleDelivery is the per-message decision tree:
//
//  1. Check x-death header for retry-count. If at MaxRetries, the message
//     has bounced through the retry queue too many times — publish to
//     oee-failed and ack the original so it doesn't loop forever.
//  2. Dispatch to a handler by routing key (or a fallback for unknown).
//  3. Handler returns nil → ack. Handler returns error → nack with
//     requeue=false so the message goes to DLX (oee-retry) → TTL → back
//     to source → re-delivered to this consumer.
func (c *Consumer) handleDelivery(ctx context.Context, ch *amqp.Channel, d amqp.Delivery) {
	c.delivered.Add(1)
	c.lastDelivery.Store(time.Now().UnixNano())
	start := time.Now()

	// Defer the duration recording so it covers EVERY exit path including
	// the early returns below (failed-exchange publish errors, etc.). The
	// histogram represents "time we spent on this message before deciding
	// ack/nack/republish" — useful regardless of outcome.
	defer func() {
		if c.metricsDuration != nil {
			c.metricsDuration(d.RoutingKey, time.Since(start).Seconds())
		}
	}()

	retries := xDeathCount(d.Headers)
	if retries >= c.cfg.MaxRetries {
		// Publish to failed exchange (terminal) and ack the original.
		err := ch.PublishWithContext(ctx, c.cfg.FailedExchange, d.RoutingKey, false, false, amqp.Publishing{
			ContentType: d.ContentType,
			Body:        d.Body,
			Headers:     d.Headers,
		})
		if err != nil {
			c.logger.Error("publish to failed exchange",
				slog.String("err", err.Error()),
				slog.String("routing_key", d.RoutingKey),
			)
			// Don't ack — let the message be redelivered on next cycle.
			return
		}
		_ = d.Ack(false)
		c.publishedFail.Add(1)
		if c.metricsDeliveries != nil {
			c.metricsDeliveries(d.RoutingKey, "exhausted_failed")
		}
		c.logger.Warn("message exceeded retry limit, sent to failed queue",
			slog.Int("retries", retries),
			slog.String("routing_key", d.RoutingKey),
			slog.Int("body_len", len(d.Body)),
		)
		return
	}

	if err := c.dispatcher.Handle(ctx, &d); err != nil {
		// nack with requeue=false → DLX (retry exchange) → retry queue → TTL → back to source.
		_ = d.Nack(false, false)
		c.nackedRetry.Add(1)
		if c.metricsDeliveries != nil {
			c.metricsDeliveries(d.RoutingKey, "nacked_retry")
		}
		c.logger.Warn("handler error, nacked to retry",
			slog.String("err", err.Error()),
			slog.Int("retries_so_far", retries),
			slog.String("routing_key", d.RoutingKey),
		)
		return
	}

	if err := d.Ack(false); err != nil {
		c.logger.Error("ack failed", slog.String("err", err.Error()))
		return
	}
	c.acked.Add(1)
	if c.metricsDeliveries != nil {
		c.metricsDeliveries(d.RoutingKey, "acked")
	}
}

// xDeathCount sums the count fields of all x-death header entries.
// Each "round trip" through the retry queue adds an entry. Returns 0 if
// the message has never been dead-lettered.
func xDeathCount(h amqp.Table) int {
	xd, ok := h["x-death"]
	if !ok {
		return 0
	}
	deaths, ok := xd.([]any)
	if !ok {
		return 0
	}
	total := 0
	for _, e := range deaths {
		entry, ok := e.(amqp.Table)
		if !ok {
			continue
		}
		if v, ok := entry["count"].(int64); ok {
			total += int(v)
		}
	}
	return total
}

// Snapshot returns counters + state for /health JSON.
type Snapshot struct {
	Healthy           bool   `json:"healthy"`
	StartedAt         string `json:"started_at"`
	LastError         string `json:"last_error,omitempty"`
	Delivered         uint64 `json:"delivered"`
	Acked             uint64 `json:"acked"`
	NackedToRetry     uint64 `json:"nacked_to_retry"`
	PublishedToFailed uint64 `json:"published_to_failed"`
	LastDeliveryAgoMs int64  `json:"last_delivery_ago_ms,omitempty"`
	Writers           any    `json:"writers,omitempty"`
}

// Snapshot returns the marshaled JSON body, the healthy flag, and any
// marshal error. Satisfies health.Snapshotter — health.go writes the
// bytes directly without a re-parse.
func (c *Consumer) Snapshot() ([]byte, bool, error) {
	c.mu.RLock()
	s := Snapshot{
		Healthy:           c.healthy,
		StartedAt:         c.startedAt.UTC().Format(time.RFC3339),
		LastError:         c.lastErr,
		Delivered:         c.delivered.Load(),
		Acked:             c.acked.Load(),
		NackedToRetry:     c.nackedRetry.Load(),
		PublishedToFailed: c.publishedFail.Load(),
	}
	if last := c.lastDelivery.Load(); last > 0 {
		s.LastDeliveryAgoMs = (time.Now().UnixNano() - last) / int64(time.Millisecond)
	}
	if c.writerStats != nil {
		s.Writers = c.writerStats()
	}
	c.mu.RUnlock()

	body, err := json.Marshal(s)
	if err != nil {
		return nil, false, fmt.Errorf("marshal snapshot: %w", err)
	}
	return body, s.Healthy, nil
}
