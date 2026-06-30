// Package metrics owns the Prometheus registry + collectors for the
// transformer. Exposed on the same HTTP server as /healthz, at /metrics.
//
// Label discipline (ADR-0009 reuse rule — lift from oeecloud-worker
// AFTER PR #56 silent-coverage-gap fix):
//   - routing_key — the AMQP routing key (today "plc.normalized.<tenant>")
//   - tenant      — the tenant id parsed from the routing key. MANDATORY:
//                   the PR #56 lesson is that NOT having this label is the
//                   single failure mode that hides per-tenant outages for
//                   hours. Every per-delivery metric carries this label.
//   - result      — acked | nacked_retry | exhausted_failed
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
	Deliveries *prometheus.CounterVec   // labels: routing_key, tenant, result
	Duration   *prometheus.HistogramVec // labels: routing_key, tenant
}

func New() *Metrics {
	reg := prometheus.NewRegistry()
	// Standard runtime + process collectors so we get Go memory,
	// goroutine count, GC pause times — useful for diagnosing the
	// per-tenant consume loops once load grows.
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	m := &Metrics{
		Registry: reg,
		Deliveries: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "edge_transformer_amqp_deliveries_total",
			Help: "AMQP deliveries by outcome. result=acked|nacked_retry|exhausted_failed.",
		}, []string{"routing_key", "tenant", "result"}),
		Duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "edge_transformer_handler_duration_seconds",
			Help: "Time from delivery received to handler returned (ack/nack decision made).",
			// 1ms → ~10s buckets; tuned for transform-then-publish latency.
			Buckets: prometheus.ExponentialBuckets(0.001, 2, 14),
		}, []string{"routing_key", "tenant"}),
	}
	reg.MustRegister(m.Deliveries, m.Duration)
	return m
}
