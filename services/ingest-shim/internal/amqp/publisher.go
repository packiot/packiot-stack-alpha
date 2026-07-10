// Package amqp owns the shim's single RabbitMQ connection + confirm-mode
// publish channel, plus the reconnect/backoff loop that heals broker drops.
//
// Publisher-confirms discipline (same lesson as edge-transformer's
// shadowpub + ADR-0011 rule 1): a plain PublishWithContext returns nil the
// instant the bytes leave our TCP socket, whether or not the broker ever
// persisted them. That is silent loss. We enable confirm-select mode on the
// channel and wait for the broker's ack before telling the HTTP caller 202.
// nack or timeout → the caller gets 503 and can retry.
package amqp

import (
	"context"
	"errors"
	"log/slog"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/trace"

	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/amqptrace"
)

// Sentinel errors the HTTP layer maps to 503.
var (
	ErrNotConnected   = errors.New("amqp: not connected")
	ErrNack           = errors.New("amqp: broker nacked publish")
	ErrConfirmTimeout = errors.New("amqp: publisher confirm timed out")
	ErrChannelClosed  = errors.New("amqp: confirm channel closed")
)

// Publisher is safe for concurrent use — every Publish holds mu, so the
// single confirm-mode channel sees exactly one in-flight publish at a time
// and the 1:1 publish↔confirmation ordering the amqp091 NotifyPublish
// contract guarantees holds trivially.
type Publisher struct {
	amqpURL        string
	exchange       string
	routingKey     string
	confirmTimeout time.Duration
	logger         *slog.Logger

	mu       sync.Mutex
	conn     *amqp.Connection
	ch       *amqp.Channel
	confirms chan amqp.Confirmation

	connected atomic.Bool
}

// NewPublisher builds the publisher but does NOT dial — call Connect (or let
// StartConnectionMonitor establish the first connection).
func NewPublisher(amqpURL, exchange, routingKey string, confirmTimeout time.Duration, logger *slog.Logger) *Publisher {
	return &Publisher{
		amqpURL:        amqpURL,
		exchange:       exchange,
		routingKey:     routingKey,
		confirmTimeout: confirmTimeout,
		logger:         logger,
	}
}

// Connect dials the broker, opens a channel, and puts it in confirm mode.
// Safe to call repeatedly (reconnect path).
func (p *Publisher) Connect() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.connectLocked()
}

func (p *Publisher) connectLocked() error {
	// Tear down any prior conn/channel first.
	if p.ch != nil {
		_ = p.ch.Close()
		p.ch = nil
	}
	if p.conn != nil {
		_ = p.conn.Close()
		p.conn = nil
	}
	p.connected.Store(false)

	conn, err := amqp.Dial(p.amqpURL)
	if err != nil {
		return err
	}
	ch, err := conn.Channel()
	if err != nil {
		_ = conn.Close()
		return err
	}
	if err := ch.Confirm(false); err != nil {
		_ = ch.Close()
		_ = conn.Close()
		return err
	}
	p.conn = conn
	p.ch = ch
	// Buffer of 1 is enough: publishes are serialized under mu, so at most
	// one confirmation is outstanding at a time.
	p.confirms = ch.NotifyPublish(make(chan amqp.Confirmation, 1))
	p.connected.Store(true)
	return nil
}

// Healthy reports whether the broker connection is currently up. Backs
// GET /healthz.
func (p *Publisher) Healthy() bool { return p.connected.Load() }

// Publish sends body VERBATIM to the configured exchange/routing key as
// application/json, persistent, and blocks until the broker confirms (202),
// nacks (ErrNack), or the confirm times out (ErrConfirmTimeout).
func (p *Publisher) Publish(ctx context.Context, body []byte) error {
	// Producer span (no-op unless tracing is enabled). Started before the lock
	// so its duration covers the whole publish+confirm; the injected
	// traceparent below lets oeecloud-worker's consume continue this trace.
	ctx, span := otel.Tracer("ingest-shim").Start(ctx, "publish "+p.routingKey,
		trace.WithSpanKind(trace.SpanKindProducer))
	defer span.End()

	p.mu.Lock()
	defer p.mu.Unlock()

	if p.ch == nil || !p.connected.Load() {
		return ErrNotConnected
	}

	// Drain any stale confirmation left over from a previous timed-out
	// publish so we don't mistake it for this message's ack.
	select {
	case <-p.confirms:
	default:
	}

	if err := p.ch.PublishWithContext(ctx, p.exchange, p.routingKey, false, false, amqp.Publishing{
		ContentType:  "application/json",
		Body:         body,
		DeliveryMode: amqp.Persistent,
		Timestamp:    time.Now(),
		// Carry the trace context onto the message so the consumer continues
		// this trace across the broker (W3C traceparent in the AMQP headers).
		Headers: amqptrace.Inject(ctx, amqp.Table{}),
	}); err != nil {
		// A publish error usually means the channel is dead — mark unhealthy
		// so the monitor reconnects and /healthz flips.
		p.connected.Store(false)
		return err
	}

	timer := time.NewTimer(p.confirmTimeout)
	defer timer.Stop()
	select {
	case c, ok := <-p.confirms:
		if !ok {
			p.connected.Store(false)
			return ErrChannelClosed
		}
		if !c.Ack {
			return ErrNack
		}
		return nil
	case <-timer.C:
		return ErrConfirmTimeout
	case <-ctx.Done():
		return ctx.Err()
	}
}

// StartConnectionMonitor spawns a goroutine that watches the connection's
// NotifyClose and reconnects with jittered exponential backoff. Runs until
// ctx is cancelled. Call once after NewPublisher.
func (p *Publisher) StartConnectionMonitor(ctx context.Context) {
	go p.monitor(ctx)
}

func (p *Publisher) monitor(ctx context.Context) {
	attempt := 0
	for {
		if ctx.Err() != nil {
			return
		}

		p.mu.Lock()
		conn := p.conn
		p.mu.Unlock()

		if conn == nil || !p.connected.Load() {
			if err := p.Connect(); err != nil {
				attempt++
				delay := backoff(attempt)
				p.logger.Warn("amqp reconnect failed, retrying",
					slog.String("err", err.Error()),
					slog.Duration("delay", delay),
					slog.Int("attempt", attempt))
				select {
				case <-time.After(delay):
				case <-ctx.Done():
					return
				}
				continue
			}
			attempt = 0
			p.logger.Info("amqp connected")
			continue
		}

		notifyClose := conn.NotifyClose(make(chan *amqp.Error, 1))
		select {
		case <-ctx.Done():
			return
		case e := <-notifyClose:
			p.connected.Store(false)
			if e != nil {
				p.logger.Warn("amqp connection closed, will reconnect", slog.String("err", e.Error()))
			}
		}
	}
}

func backoff(attempt int) time.Duration {
	const maxDelay = 30 * time.Second
	base := time.Duration(1<<min(attempt, 5)) * time.Second
	if base > maxDelay {
		base = maxDelay
	}
	factor := 0.75 + rand.Float64()*0.5 // [0.75, 1.25)
	return time.Duration(float64(base) * factor)
}

// Close tears down the connection. Safe to call once at shutdown.
func (p *Publisher) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.connected.Store(false)
	if p.ch != nil {
		_ = p.ch.Close()
		p.ch = nil
	}
	if p.conn != nil {
		_ = p.conn.Close()
		p.conn = nil
	}
}
