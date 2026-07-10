// Package tracing bootstraps OpenTelemetry → Tempo (OTLP/gRPC). It is the
// copy-me pattern for adding distributed tracing to a Go service in this stack:
// call Init at startup, defer the returned shutdown, then wrap the HTTP server
// with otelhttp, the outbound http.Client with otelhttp.NewTransport, and the
// pgx pool with otelpgx — and a single operator action becomes one trace
// spanning receive → resolve (DB) → edge-api call.
//
// Tracing is OPT-IN: with OTEL_EXPORTER_OTLP_ENDPOINT unset, Init installs
// nothing and returns a no-op shutdown, so the service runs exactly as before.
// The W3C propagator is always set when enabled, so this service's outbound
// traceparent links into downstream services even before they export their own
// spans.
package tracing

import (
	"context"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// Init configures the global TracerProvider + W3C propagator for serviceName.
// Returns a shutdown func (always non-nil, always safe to call) that flushes
// pending spans. Disabled — no-op shutdown — when OTEL_EXPORTER_OTLP_ENDPOINT
// is empty.
func Init(ctx context.Context, serviceName string) (func(context.Context) error, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		return func(context.Context) error { return nil }, nil
	}

	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	exp, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpointURL(endpoint), // e.g. http://tempo:4317
		otlptracegrpc.WithInsecure(),            // internal compose network, no TLS
	)
	if err != nil {
		return nil, err
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(semconv.ServiceName(serviceName)),
	)
	if err != nil {
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	return func(ctx context.Context) error {
		ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		return tp.Shutdown(ctx)
	}, nil
}
