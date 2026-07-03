// Package metrics owns the Prometheus registry + collectors for the
// worker. Exposed on the same HTTP server as /health, at /metrics.
//
// Label discipline (forward-compatible with multi-tenancy, see #42):
//   - routing_key — the AMQP routing key (today "sparkplug.data";
//     becomes the tenant-bearing key when per-tenant queues land)
//   - result      — acked | nacked_retry | exhausted_failed
//   - writer      — equipment_values | uns_metrics | po_parameter
//   - op          — handler-specific (wrote_*, skipped_*)
//
// All scrape-time reads of writer atomic counters happen via custom
// Collectors so writers stay decoupled from Prometheus.
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

type Metrics struct {
	Registry *prometheus.Registry

	// Per-delivery counters (incremented in amqp/consumer.go).
	Deliveries *prometheus.CounterVec   // labels: routing_key, result
	Duration   *prometheus.HistogramVec // labels: routing_key
}

func New() *Metrics {
	reg := prometheus.NewRegistry()
	// Standard runtime + process collectors so we get free Go memory,
	// goroutine count, GC pause times — useful for diagnosing the
	// single-consumer-loop bottleneck (#41) once load grows.
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	m := &Metrics{
		Registry: reg,
		Deliveries: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "oeecloud_worker_amqp_deliveries_total",
			Help: "AMQP deliveries by outcome. result=acked|nacked_retry|exhausted_failed.",
		}, []string{"routing_key", "result"}),
		Duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "oeecloud_worker_handler_duration_seconds",
			Help: "Time from delivery received to handler returned (ack/nack decision made).",
			// 1ms → ~10s buckets; tuned for our ~5–50ms p50 + occasional pgbouncer hiccup.
			Buckets: prometheus.ExponentialBuckets(0.001, 2, 14),
		}, []string{"routing_key"}),
	}
	reg.MustRegister(m.Deliveries, m.Duration)
	return m
}
