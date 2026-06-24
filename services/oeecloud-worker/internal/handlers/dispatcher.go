// Package handlers owns per-routing-key processing.
//
// This session: only a placeholder (LogOnly) is registered. Returning nil
// makes the consumer ack the message — perfect for a parallel-run validation
// phase where we want to see what shapes/topics arrive without writing to DB.
//
// Future sessions: register one handler per equivalent oeecloud-node-red
// path. Suggested shape:
//
//	"sparkplug.equipment_values":      writeEquipmentValues
//	"sparkplug.equipment_events":      writeEquipmentEvents
//	"sparkplug.uns_metrics":           writeUnsMetrics
//	"sparkplug.po.parameter_30700":    handlePOParam30700
//	... etc.
//
// Each handler returns:
//
//	nil           → consumer acks (success)
//	non-nil error → consumer nacks → DLX → retry queue → re-delivered after TTL
//
// After MaxRetries the consumer publishes the message to oee-failed
// without invoking the handler again. Handlers should be IDEMPOTENT
// (postgres UPSERT, not blind INSERT) because retries are at-least-once.
package handlers

import (
	"context"
	"log/slog"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Handler processes one delivery. Return nil to ack, error to retry.
type Handler func(ctx context.Context, d *amqp.Delivery) error

type Dispatcher struct {
	logger   *slog.Logger
	handlers map[string]Handler
	fallback Handler
}

func NewDispatcher(logger *slog.Logger) *Dispatcher {
	return &Dispatcher{
		logger:   logger,
		handlers: make(map[string]Handler),
		fallback: LogOnly(logger),
	}
}

func (d *Dispatcher) Register(routingKey string, h Handler) {
	d.handlers[routingKey] = h
}

// Handle dispatches by routing key. Unknown routing keys go to the
// fallback (LogOnly) so the cursor still advances + we observe what's
// arriving rather than nacking everything to retry.
func (d *Dispatcher) Handle(ctx context.Context, msg *amqp.Delivery) error {
	if h, ok := d.handlers[msg.RoutingKey]; ok {
		return h(ctx, msg)
	}
	return d.fallback(ctx, msg)
}

// LogOnly is the placeholder handler. It logs the delivery's shape +
// returns nil so the consumer acks. Useful for parallel-run validation
// before real handlers are written.
func LogOnly(logger *slog.Logger) Handler {
	return func(_ context.Context, d *amqp.Delivery) error {
		preview := d.Body
		if len(preview) > 200 {
			preview = preview[:200]
		}
		logger.Info("received message (log-only, no write)",
			slog.String("routing_key", d.RoutingKey),
			slog.String("exchange", d.Exchange),
			slog.String("content_type", d.ContentType),
			slog.Int("body_len", len(d.Body)),
			slog.String("body_preview", string(preview)),
		)
		return nil
	}
}

