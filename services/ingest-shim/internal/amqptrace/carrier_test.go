package amqptrace

import (
	"context"
	"testing"

	amqp "github.com/rabbitmq/amqp091-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

// The whole point of the package: a span context injected on the producer side
// must be recoverable, byte-for-byte, on the consumer side after crossing the
// AMQP header map. If this breaks, every data-plane trace silently splits into
// two disconnected halves — exactly the failure the primitive exists to prevent.
func TestInjectExtractRoundTrip(t *testing.T) {
	// tracing.Init sets this in prod; set it here so the test exercises real
	// W3C propagation instead of the default no-op propagator.
	otel.SetTextMapPropagator(propagation.TraceContext{})

	tid, _ := trace.TraceIDFromHex("0123456789abcdef0123456789abcdef")
	sid, _ := trace.SpanIDFromHex("0123456789abcdef")
	sc := trace.NewSpanContext(trace.SpanContextConfig{
		TraceID:    tid,
		SpanID:     sid,
		TraceFlags: trace.FlagsSampled,
		Remote:     true,
	})
	parent := trace.ContextWithSpanContext(context.Background(), sc)

	headers := Inject(parent, amqp.Table{})
	if _, ok := headers["traceparent"]; !ok {
		t.Fatalf("Inject wrote no traceparent header: %v", headers)
	}

	// Fresh consumer-side context must recover the same trace + span IDs.
	got := trace.SpanContextFromContext(Extract(context.Background(), headers))
	if got.TraceID() != tid {
		t.Errorf("trace id: got %s want %s", got.TraceID(), tid)
	}
	if got.SpanID() != sid {
		t.Errorf("span id: got %s want %s", got.SpanID(), sid)
	}
	if !got.IsSampled() {
		t.Error("sampled flag lost across the AMQP hop")
	}
}

// Real deliveries arrive with headers=nil when nobody injected — must not panic.
func TestExtractNilHeadersIsSafe(t *testing.T) {
	if ctx := Extract(context.Background(), nil); ctx == nil {
		t.Fatal("Extract(nil) returned a nil context")
	}
}

// Inject must allocate a table when handed nil so the caller can hand the
// result straight to amqp.Publishing.Headers.
func TestInjectNilTableAllocates(t *testing.T) {
	otel.SetTextMapPropagator(propagation.TraceContext{})
	if h := Inject(context.Background(), nil); h == nil {
		t.Fatal("Inject(nil) returned a nil table")
	}
}
