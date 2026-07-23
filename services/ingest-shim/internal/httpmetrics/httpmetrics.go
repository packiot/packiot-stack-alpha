package httpmetrics

// Package httpmetrics is a small RED (Rate / Errors / Duration) instrumentation
// middleware for this service's HTTP surface. It emits one histogram —
// http_request_duration_seconds{method,route,status} — from which Grafana reads
// request RATE (rate of _count), ERROR rate (by status class), and latency
// DURATION quantiles (histogram_quantile over _bucket). One metric, all three
// RED signals.
//
// The route label is the Go 1.22 ServeMux PATTERN (r.Pattern), set during
// routing — NOT the raw path. A parameterised route like /v1/foo/{id} stays ONE
// series instead of one-per-id; this is the cardinality trap the package exists
// to avoid. Unmatched requests (404) bucket under route="unmatched" so a
// scanner hitting random paths cannot explode the series count.

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"go.opentelemetry.io/otel/trace"
)

// New registers the histogram on reg and returns a middleware to wrap the
// service's top-level handler. Scrape (/metrics) and probe (/healthz,/health)
// traffic is skipped — it is not a business signal and would dominate the rate.
func New(reg prometheus.Registerer) func(http.Handler) http.Handler {
	dur := prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency in seconds by method, route template, and status code.",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
	}, []string{"method", "route", "status"})
	reg.MustRegister(dur)

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/metrics", "/healthz", "/health":
				next.ServeHTTP(w, r)
				return
			}
			rec := &recorder{ResponseWriter: w, status: http.StatusOK}
			start := time.Now()
			next.ServeHTTP(rec, r)
			route := r.Pattern // set by the ServeMux during ServeHTTP (Go 1.22)
			if route == "" {
				route = "unmatched"
			}
			obs := dur.WithLabelValues(r.Method, route, strconv.Itoa(rec.status))
			elapsed := time.Since(start).Seconds()
			// Attach the active trace's ID as a Prometheus exemplar so a latency
			// spike on the RED panel links straight to its Tempo trace. otelhttp
			// is the outer handler, so r.Context() already carries the server
			// span. Exemplars only surface when /metrics is scraped as
			// OpenMetrics (see the promhttp EnableOpenMetrics option in main).
			if sc := trace.SpanContextFromContext(r.Context()); sc.IsValid() {
				if eo, ok := obs.(prometheus.ExemplarObserver); ok {
					eo.ObserveWithExemplar(elapsed, prometheus.Labels{"trace_id": sc.TraceID().String()})
					return
				}
			}
			obs.Observe(elapsed)
		})
	}
}

// recorder captures the response status (defaults to 200 when a handler writes
// a body without an explicit WriteHeader). Unwrap + Flush keep streaming
// handlers (refdata-api streams row arrays) working through the wrapper.
type recorder struct {
	http.ResponseWriter
	status  int
	written bool
}

func (r *recorder) WriteHeader(code int) {
	r.status = code
	r.written = true
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	r.written = true
	return r.ResponseWriter.Write(b)
}

// Unwrap lets http.ResponseController reach the underlying writer (Flush/Hijack).
func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

// Flush forwards to the underlying writer if it supports streaming.
func (r *recorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
