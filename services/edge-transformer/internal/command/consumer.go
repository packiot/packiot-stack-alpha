package command

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
	"golang.org/x/sync/errgroup"

	amqptopo "github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/amqp"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/config"
)

// errPublisherNotReady is returned when an ack/failed publish is attempted
// before the publish channel is established (or after it dropped).
var errPublisherNotReady = errors.New("command: publish channel not ready")

// amqpPublisher owns a dedicated publish channel for acks + failed-routing.
// AMQP channels are NOT goroutine-safe and multiple per-tenant consume
// goroutines share this one publisher, so every publish is serialized under a
// mutex. The channel is swapped on each (re)connect via setChannel.
type amqpPublisher struct {
	mu          sync.Mutex
	ch          *amqp.Channel
	ackExchange string
	logger      *slog.Logger
}

func (p *amqpPublisher) setChannel(ch *amqp.Channel) {
	p.mu.Lock()
	p.ch = ch
	p.mu.Unlock()
}

// PublishAck satisfies AckPublisher — routes the ack to the command exchange.
func (p *amqpPublisher) PublishAck(ctx context.Context, routingKey string, body []byte) error {
	return p.publish(ctx, p.ackExchange, routingKey, body)
}

func (p *amqpPublisher) publish(ctx context.Context, exchange, routingKey string, body []byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.ch == nil {
		return errPublisherNotReady
	}
	return p.ch.PublishWithContext(ctx, exchange, routingKey, false, false, amqp.Publishing{
		ContentType:  "application/json",
		DeliveryMode: amqp.Persistent,
		Body:         body,
	})
}

// Consumer subscribes the per-tenant command queues, runs the Executor per
// delivery, and translates the Result into a broker ack/nack (+ failed-routing).
// It is the machine-write path, so it is GATED: Run is a no-op that blocks on
// ctx when EDGE_COMMANDS_ENABLED=false. Ships inert.
type Consumer struct {
	cfg      *config.Config
	amqpURL  string
	tenants  []string
	executor *Executor
	pub      *amqpPublisher
	logger   *slog.Logger

	// health counters
	delivered atomic.Uint64
	acked     atomic.Uint64
	rejected  atomic.Uint64
	retried   atomic.Uint64
	exhausted atomic.Uint64

	mu        sync.RWMutex
	healthy   bool
	lastErr   string
	startedAt time.Time
}

// NewConsumer builds the command consumer + its Executor. device is the DCMD
// sink (MQTT in production, a mock in tests); it may be nil ONLY when
// CommandsEnabled is false (the inert path never touches it).
func NewConsumer(cfg *config.Config, amqpURL string, tenants []string, device DevicePublisher, metrics Metrics, logger *slog.Logger) *Consumer {
	if logger == nil {
		logger = slog.Default()
	}
	pub := &amqpPublisher{ackExchange: cfg.CommandsExchange, logger: logger}
	exec := NewExecutor(Config{
		Allowed:  cfg.CommandsAllowed,
		Exchange: cfg.CommandsExchange,
		EdgeNode: cfg.CommandsEdgeNode,
		DedupCap: cfg.CommandsDedupCap,
	}, device, pub, metrics, logger)
	return &Consumer{
		cfg:       cfg,
		amqpURL:   amqpURL,
		tenants:   tenants,
		executor:  exec,
		pub:       pub,
		logger:    logger,
		startedAt: time.Now(),
	}
}

// Executor exposes the underlying executor (tests + boot logging).
func (c *Consumer) Executor() *Executor { return c.executor }

// Run blocks until ctx is cancelled. When the command channel is disabled it
// returns nothing but the ctx-done — inert, no dial, no subscribe.
func (c *Consumer) Run(ctx context.Context) error {
	if !c.cfg.CommandsEnabled {
		c.logger.Info("edge command channel DISABLED (EDGE_COMMANDS_ENABLED=false) — consumer inert",
			slog.String("adr", "ADR-0019 C1"))
		<-ctx.Done()
		return nil
	}
	c.logger.Info("edge command channel ENABLED — starting command consumer",
		slog.Any("tenants", c.tenants),
		slog.Any("allowed_verbs", c.cfg.CommandsAllowed),
		slog.String("edge_node", c.cfg.CommandsEdgeNode))

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
			c.logger.Warn("command: amqp connection failed, retrying",
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
	if err := amqptopo.DeclareCommandTopology(ctx, declCh, c.cfg, c.tenants, c.logger); err != nil {
		declCh.Close()
		return fmt.Errorf("command topology: %w", err)
	}
	declCh.Close()

	// Dedicated publish channel for acks + failed-routing, shared across the
	// per-tenant consume goroutines (serialized in amqpPublisher).
	pubCh, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("publish channel: %w", err)
	}
	defer pubCh.Close()
	c.pub.setChannel(pubCh)
	defer c.pub.setChannel(nil)

	c.mu.Lock()
	c.healthy = true
	c.lastErr = ""
	c.mu.Unlock()

	eg, egctx := errgroup.WithContext(ctx)
	for _, t := range c.tenants {
		tenant := t
		eg.Go(func() error { return c.consumeOne(egctx, conn, tenant) })
	}
	return eg.Wait()
}

func (c *Consumer) consumeOne(ctx context.Context, conn *amqp.Connection, tenant string) error {
	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("channel for %s: %w", tenant, err)
	}
	defer ch.Close()

	if err := ch.Qos(c.cfg.Prefetch, 0, false); err != nil {
		return fmt.Errorf("qos for %s: %w", tenant, err)
	}

	mainQ, _, _, _ := amqptopo.CommandQueueNames(c.cfg, tenant)
	deliveries, err := ch.Consume(mainQ, "", false, false, false, false, nil)
	if err != nil {
		return fmt.Errorf("consume %s: %w", mainQ, err)
	}
	closeCh := ch.NotifyClose(make(chan *amqp.Error, 1))
	c.logger.Info("command: consuming", slog.String("queue", mainQ), slog.String("tenant", tenant))

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case e := <-closeCh:
			if e == nil {
				return nil
			}
			return fmt.Errorf("channel closed for %s: %w", mainQ, e)
		case d, ok := <-deliveries:
			if !ok {
				return fmt.Errorf("delivery channel closed for %s", mainQ)
			}
			c.handleDelivery(ctx, d, tenant)
		}
	}
}

// handleDelivery is the per-command decision tree:
//
//  1. Retry-exhausted (x-death >= MaxRetries) → route the original to the
//     failed exchange + ack, so a persistently-failing command lands in the
//     terminal queue for human triage instead of looping forever.
//  2. Execute. Transient error (broker/MQTT down) → nack(false,false) → DLX →
//     retry queue → TTL → back to source. The command is redelivered.
//  3. Rejected (bad verb / params / mapping) → the reject is DETERMINISTIC, so
//     retrying is pointless: route the original straight to the failed exchange
//     (dead-letter it) + ack. The ack-rejected has already been published by
//     the executor.
//  4. Delivered → ack.
func (c *Consumer) handleDelivery(ctx context.Context, d amqp.Delivery, tenant string) {
	c.delivered.Add(1)

	if xDeathCount(d.Headers) >= c.cfg.MaxRetries {
		c.deadLetter(ctx, d, tenant, "retry_exhausted")
		c.exhausted.Add(1)
		return
	}

	res, err := c.executor.Execute(ctx, d.Body)
	if err != nil {
		// Transient — nack to the retry queue for redelivery.
		_ = d.Nack(false, false)
		c.retried.Add(1)
		c.logger.Warn("command: transient failure, nacked to retry",
			slog.String("tenant", tenant), slog.String("err", err.Error()))
		return
	}

	switch res.Outcome {
	case OutcomeRejected:
		c.deadLetter(ctx, d, tenant, res.Reason)
		c.rejected.Add(1)
	default: // OutcomeDelivered
		if err := d.Ack(false); err != nil {
			c.logger.Error("command: ack failed", slog.String("tenant", tenant), slog.String("err", err.Error()))
			return
		}
		c.acked.Add(1)
	}
}

// deadLetter routes the original command body to the failed exchange (terminal,
// human triage) and acks the delivery so it does not loop. On a publish failure
// we nack-to-retry instead of dropping — a lost command is worse than a looped
// one.
func (c *Consumer) deadLetter(ctx context.Context, d amqp.Delivery, tenant, reason string) {
	if err := c.pub.publish(ctx, c.cfg.CommandsFailedExchange, d.RoutingKey, d.Body); err != nil {
		c.logger.Error("command: route-to-failed publish failed — nacking to retry",
			slog.String("tenant", tenant), slog.String("reason", reason), slog.String("err", err.Error()))
		_ = d.Nack(false, false)
		return
	}
	_ = d.Ack(false)
	c.logger.Warn("command: dead-lettered to failed queue",
		slog.String("tenant", tenant), slog.String("reason", reason))
}

// xDeathCount sums the count fields of x-death header entries (one per retry
// round-trip). Local copy of the ingest consumer's helper — the header shape
// is identical.
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

// ── health.ComponentSnapshotter (ADR-0011 P0-4) ──────────────────────────────

func (c *Consumer) Component() string { return "command_consumer" }

func (c *Consumer) SnapshotDetail() any {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return map[string]any{
		"enabled":         c.cfg.CommandsEnabled,
		"healthy":         c.healthy,
		"last_error":      c.lastErr,
		"delivered_total": c.delivered.Load(),
		"acked_total":     c.acked.Load(),
		"rejected_total":  c.rejected.Load(),
		"retried_total":   c.retried.Load(),
		"exhausted_total": c.exhausted.Load(),
		"tenants":         c.tenants,
	}
}

// Degraded surfaces an unhealthy consumer. When the channel is disabled it is
// never degraded (inert-by-design, like the disabled MQTT source).
func (c *Consumer) Degraded() string {
	if !c.cfg.CommandsEnabled {
		return ""
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	if !c.healthy {
		if c.lastErr != "" {
			return c.lastErr
		}
		return "command consumer not healthy"
	}
	return ""
}
