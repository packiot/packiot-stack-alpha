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

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/handlers"
	amqp "github.com/rabbitmq/amqp091-go"
	"golang.org/x/sync/errgroup"
)

// Consumer owns the lifecycle of a single AMQP connection + N per-tenant
// Channels + N consume loops. Re-establishes the topology + consumers
// on every reconnect so broker restarts heal automatically.
//
// AMQP Channel-not-goroutine-safe discipline (zettel
// `amqp-channel-not-goroutine-safe`): each per-tenant consume loop owns
// its own *amqp.Channel. Shared *amqp.Connection. Never share a Channel
// across goroutines — even for the publish-on-exhaustion call, the
// consume goroutine that holds the Channel does the publish.
//
// Lifted from services/oeecloud-worker/internal/amqp/consumer.go per
// ADR-0009 reuse rule (Errata Correction 2). Only the metric/log labels
// change; the structure is byte-for-byte the proven pattern.
type Consumer struct {
	cfg        *config.Config
	amqpURL    string // built from secrets at startup; not in cfg to keep cfg secret-free
	dispatcher *handlers.Dispatcher
	logger     *slog.Logger

	// tenants is the snapshot of active tenants resolved at startup
	// (today: from clientconfig; one element in the factory mode).
	// Used by DeclareTopology + Consumer to declare/consume per-tenant
	// queues on each reconnect.
	tenants []string

	// Optional callback letting future writers contribute to /health
	// JSON without forcing Consumer to import a writers package.
	// Skeleton: shadow.go doesn't expose any stats yet, so nil.
	writerStats func() any

	// Optional Prometheus hooks — nil-safe. Set via SetMetrics.
	// Decoupling pattern: amqp doesn't import metrics.
	metricsDeliveries func(routingKey, tenant, result string)
	metricsDuration   func(routingKey, tenant string, seconds float64)

	// Counters — read by /health for the JSON body.
	delivered     atomic.Uint64
	acked         atomic.Uint64
	nackedRetry   atomic.Uint64
	publishedFail atomic.Uint64
	lastDelivery  atomic.Int64 // unix nano

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

// SetWriterStats registers a callback returning any JSON-marshalable
// value to embed under the "writers" key of /health. Call before Run.
func (c *Consumer) SetWriterStats(fn func() any) { c.writerStats = fn }

// SetMetrics wires Prometheus recording callbacks. Both args may be nil.
// Per-tenant labels are MANDATORY — see oeecloud-worker PR #56
// silent-metric-coverage-gap; tenant routing changes must be visible
// per-tenant on the metric or breakage stays silent. ADR-0009 reuse
// rule calls this out explicitly.
func (c *Consumer) SetMetrics(
	deliveries func(routingKey, tenant, result string),
	duration func(routingKey, tenant string, seconds float64),
) {
	c.metricsDeliveries = deliveries
	c.metricsDuration = duration
}

// Counter accessors so the metrics package can read without importing
// the Snapshot struct or holding a lock-aware copy.
func (c *Consumer) DeliveredCount() uint64         { return c.delivered.Load() }
func (c *Consumer) AckedCount() uint64             { return c.acked.Load() }
func (c *Consumer) NackedToRetryCount() uint64     { return c.nackedRetry.Load() }
func (c *Consumer) PublishedToFailedCount() uint64 { return c.publishedFail.Load() }

// Run blocks until ctx is cancelled. On any connection/channel failure
// it sleeps with exponential backoff (capped at 30s) and reconnects.
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
			attempt = 0
		}
	}
}

func backoff(attempt int) time.Duration {
	// 1s base, doubles to a 30s cap, then ¾–1.25x random jitter.
	const maxDelay = 30 * time.Second
	base := time.Duration(1<<min(attempt, 5)) * time.Second
	if base > maxDelay {
		base = maxDelay
	}
	factor := 0.75 + rand.Float64()*0.5
	return time.Duration(float64(base) * factor)
}

// connectAndConsume does one full dial → declare → consume cycle.
//
// Spawns one consumer goroutine per per-tenant queue via errgroup. Each
// goroutine owns its own AMQP Channel — no cross-tenant lock contention.
// When ANY goroutine returns an error, egctx cancels and the others wind
// down; eg.Wait returns the first error. Conn.Close (defer) closes all
// Channels.
func (c *Consumer) connectAndConsume(ctx context.Context) error {
	conn, err := amqp.Dial(c.amqpURL)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	declCh, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("decl channel: %w", err)
	}
	if err := DeclareTopology(ctx, declCh, c.cfg, c.tenants, c.logger); err != nil {
		declCh.Close()
		return fmt.Errorf("topology: %w", err)
	}
	declCh.Close()

	// Per-tenant queues only — the legacy catch-all queue is unbound
	// (see topology.go) so we never consume from it in normal operation.
	queues := c.perTenantQueueNames()

	c.mu.Lock()
	c.healthy = true
	c.lastErr = ""
	c.mu.Unlock()
	c.logger.Info("consuming",
		slog.Any("queues", queues),
		slog.Int("prefetch", c.cfg.Prefetch),
	)

	eg, egctx := errgroup.WithContext(ctx)
	for i, q := range queues {
		queue := q             // capture for closure
		tenant := c.tenants[i] // per-queue tenant for metric labels
		eg.Go(func() error {
			return c.consumeOne(egctx, conn, queue, tenant)
		})
	}
	return eg.Wait()
}

// consumeOne owns one AMQP Channel + ch.Consume on one queue. Returns
// when its channel drops or ctx cancels.
func (c *Consumer) consumeOne(ctx context.Context, conn *amqp.Connection, queue, tenant string) error {
	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("channel for %s: %w", queue, err)
	}
	defer ch.Close()

	if err := ch.Qos(c.cfg.Prefetch, 0, false); err != nil {
		return fmt.Errorf("qos for %s: %w", queue, err)
	}

	// Empty consumer tag → broker generates one. autoAck=false → manual ack.
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
			c.handleDelivery(ctx, ch, d, tenant)
		}
	}
}

// perTenantQueueNames builds "<prefix>-<tenant>" for every active tenant.
// Matches the names declared in DeclareTopology.
func (c *Consumer) perTenantQueueNames() []string {
	out := make([]string, 0, len(c.tenants))
	for _, t := range c.tenants {
		out = append(out, fmt.Sprintf("%s-%s", c.cfg.WorkerQueue, t))
	}
	return out
}

// handleDelivery is the per-message decision tree:
//
//  1. If x-death count >= MaxRetries, publish to failed exchange and ack
//     the original so it doesn't loop forever.
//  2. Dispatch to a handler (today: shadow log-only).
//  3. Handler returns nil → ack. Returns error → nack(requeue=false) →
//     DLX → retry queue → TTL → back to source → re-delivered.
func (c *Consumer) handleDelivery(ctx context.Context, ch *amqp.Channel, d amqp.Delivery, tenant string) {
	c.delivered.Add(1)
	c.lastDelivery.Store(time.Now().UnixNano())
	start := time.Now()

	defer func() {
		if c.metricsDuration != nil {
			c.metricsDuration(d.RoutingKey, tenant, time.Since(start).Seconds())
		}
	}()

	retries := xDeathCount(d.Headers)
	if retries >= c.cfg.MaxRetries {
		err := ch.PublishWithContext(ctx, c.cfg.FailedExchange, d.RoutingKey, false, false, amqp.Publishing{
			ContentType: d.ContentType,
			Body:        d.Body,
			Headers:     d.Headers,
		})
		if err != nil {
			c.logger.Error("publish to failed exchange",
				slog.String("err", err.Error()),
				slog.String("routing_key", d.RoutingKey),
				slog.String("tenant", tenant),
			)
			return
		}
		_ = d.Ack(false)
		c.publishedFail.Add(1)
		if c.metricsDeliveries != nil {
			c.metricsDeliveries(d.RoutingKey, tenant, "exhausted_failed")
		}
		c.logger.Warn("message exceeded retry limit, sent to failed queue",
			slog.Int("retries", retries),
			slog.String("routing_key", d.RoutingKey),
			slog.String("tenant", tenant),
			slog.Int("body_len", len(d.Body)),
		)
		return
	}

	if err := c.dispatcher.Handle(ctx, &d); err != nil {
		_ = d.Nack(false, false)
		c.nackedRetry.Add(1)
		if c.metricsDeliveries != nil {
			c.metricsDeliveries(d.RoutingKey, tenant, "nacked_retry")
		}
		c.logger.Warn("handler error, nacked to retry",
			slog.String("err", err.Error()),
			slog.Int("retries_so_far", retries),
			slog.String("routing_key", d.RoutingKey),
			slog.String("tenant", tenant),
		)
		return
	}

	if err := d.Ack(false); err != nil {
		c.logger.Error("ack failed", slog.String("err", err.Error()), slog.String("tenant", tenant))
		return
	}
	c.acked.Add(1)
	if c.metricsDeliveries != nil {
		c.metricsDeliveries(d.RoutingKey, tenant, "acked")
	}
}

// xDeathCount sums the count fields of all x-death header entries.
// Each "round trip" through the retry queue adds an entry.
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

// Snapshot — fields read by /health.
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
	s := c.snapshotStruct()
	body, err := json.Marshal(s)
	if err != nil {
		return nil, false, fmt.Errorf("marshal snapshot: %w", err)
	}
	return body, s.Healthy, nil
}

// snapshotStruct is the internal shared helper — both Snapshot (bytes) and
// the ComponentSnapshotter methods below rely on it.
func (c *Consumer) snapshotStruct() Snapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
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
	return s
}

// ── ADR-0011 P0-4: ComponentSnapshotter for /healthz aggregation ─────────────

// Component satisfies health.ComponentSnapshotter — the name used in the
// aggregated JSON response.
func (c *Consumer) Component() string { return "amqp_consumer" }

// SnapshotDetail returns the per-component JSON body — the Snapshot struct,
// which json.Marshal handles natively.
func (c *Consumer) SnapshotDetail() any { return c.snapshotStruct() }

// Degraded surfaces the reason when the consumer is unhealthy.
// ADR-0011 rule 4: silent-degrade is a bug.
func (c *Consumer) Degraded() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if !c.healthy {
		if c.lastErr != "" {
			return c.lastErr
		}
		return "consumer not healthy (no specific reason recorded)"
	}
	return ""
}

// BootSnapshot is used by /health BEFORE Consumer.Run reaches steady
// state — so /healthz returns 200 within a few hundred ms of process
// start (Docker healthcheck has start_period=30s but the smoke check
// in deploy-staging is tighter). Returns the same shape with Healthy=true
// + StartedAt set; once Run flips state, normal Snapshot takes over.
//
// TODO(ADR-0009 Phase 2): replace this with a proper "boot-then-steady"
// state machine in Consumer; today the lifecycle gap is small enough
// that the simple boolean is fine.
func (c *Consumer) BootSnapshot() ([]byte, bool, error) {
	c.mu.Lock()
	if c.startedAt.IsZero() {
		c.startedAt = time.Now()
	}
	c.mu.Unlock()
	return c.Snapshot()
}
