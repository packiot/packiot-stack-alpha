// Package amqptrace bridges W3C trace context and AMQP message headers so a
// trace continues across a RabbitMQ hop: the producer injects the active span's
// context into amqp.Publishing.Headers, and the consumer extracts it to start a
// child span. This is the copy-me primitive for AMQP propagation in this stack
// (paired with internal/tracing).
//
// It is a no-op when tracing is disabled: the global propagator defaults to an
// empty composite (Inject writes nothing, Extract returns ctx unchanged), so
// keeping these calls on the hot path costs a map alloc and nothing else.
package amqptrace

import (
	"context"

	amqp "github.com/rabbitmq/amqp091-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
)

// tableCarrier adapts an amqp.Table (map[string]interface{}) to the
// TextMapCarrier the W3C propagator reads/writes traceparent through. AMQP
// header values are interface{}; traceparent/tracestate are always strings.
type tableCarrier amqp.Table

func (c tableCarrier) Get(key string) string {
	if v, ok := c[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

func (c tableCarrier) Set(key, value string) { c[key] = value }

func (c tableCarrier) Keys() []string {
	keys := make([]string, 0, len(c))
	for k := range c {
		keys = append(keys, k)
	}
	return keys
}

var _ propagation.TextMapCarrier = tableCarrier(nil)

// Inject writes the trace context from ctx into h (allocating a fresh table if
// h is nil) and returns it for use as amqp.Publishing.Headers.
func Inject(ctx context.Context, h amqp.Table) amqp.Table {
	if h == nil {
		h = amqp.Table{}
	}
	otel.GetTextMapPropagator().Inject(ctx, tableCarrier(h))
	return h
}

// Extract returns a context carrying the trace context found in the delivery
// headers, or ctx unchanged if none is present.
func Extract(ctx context.Context, h amqp.Table) context.Context {
	if h == nil {
		return ctx
	}
	return otel.GetTextMapPropagator().Extract(ctx, tableCarrier(h))
}
