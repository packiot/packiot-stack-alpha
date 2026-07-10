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
	"strconv"
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
		sdktrace.WithSampler(samplerFromEnv()),
	)
	otel.SetTracerProvider(tp)

	return func(ctx context.Context) error {
		ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		return tp.Shutdown(ctx)
	}, nil
}

// samplerFromEnv returns the HEAD sampler, honoring OTEL_TRACES_SAMPLER_ARG (a
// float ratio in [0,1], the OTel-standard env name). Unset/invalid → sample
// everything (the prior behavior, so this is a no-op for services that don't
// set it).
//
// ParentBased is the key: only the ROOT span's sampling decision uses the
// ratio; a span that already has a (remote) parent inherits the parent's
// decision. So dialing edge-transformer — the high-volume MQTT root — down to
// e.g. 0.1 drops 90% of traces AT THE SOURCE, and the whole downstream chain
// (worker consume, DB spans) drops or is kept WITH it. You never get a
// half-sampled trace, and low-volume roots (operator actions) can stay at 1.0.
func samplerFromEnv() sdktrace.Sampler {
	ratio := 1.0
	if v := os.Getenv("OTEL_TRACES_SAMPLER_ARG"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 && f <= 1 {
			ratio = f
		}
	}
	return sdktrace.ParentBased(sdktrace.TraceIDRatioBased(ratio))
}
