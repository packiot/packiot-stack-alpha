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
	Deliveries  *prometheus.CounterVec   // labels: routing_key, result
	Duration    *prometheus.HistogramVec // labels: routing_key
	JobTicks    *prometheus.CounterVec   // labels: job, outcome (ok|error|panic)
	BatchWrites *prometheus.CounterVec   // labels: dest (flow), result (ok|error)

	// UnresolvedTopic counts equipment_values metrics dropped because their
	// packml_topic has no active packml_register row (resolver → (nil,nil)).
	// Incremented at the writer skip branch (writers/equipment_values.go).
	// Makes the "silent unroutable topic" drop legible: a topic that keeps
	// arriving but never routes = a missing/inactive register row → that
	// tenant's equipment_values stay silently empty with green pipelines.
	// Labelled by tenant only (the lowercased first topic segment, same
	// bounded-cardinality key as batch_writes.tenant) — NOT by the full
	// topic string, which is unbounded. The full topic still rides the
	// existing sampled INFO log for debugging.
	UnresolvedTopic *prometheus.CounterVec // labels: tenant
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
	m.JobTicks = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "oeecloud_worker_job_ticks_total",
		Help: "Scheduled-job ticks by job and outcome (ok|error|panic).",
	}, []string{"job", "outcome"})
	m.BatchWrites = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "oeecloud_worker_batch_writes_total",
		Help: "Batch statements executed by destination flow + tenant. dest=f1_public|f2_shadow_go_port|f3_packiot_analytics; tenant=group_id (one per onboarded client).",
	}, []string{"dest", "tenant", "result"})
	m.UnresolvedTopic = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "packml_unresolved_topic_total",
		Help: "equipment_values metrics skipped because their packml_topic has no active packml_register row (unroutable/inactive). tenant=lowercased first topic segment (group_id). Sustained rate>0 for a tenant ⇒ a missing/inactive register row → its equipment_values are silently empty.",
	}, []string{"tenant"})
	reg.MustRegister(m.Deliveries, m.Duration, m.JobTicks, m.BatchWrites, m.UnresolvedTopic)
	return m
}
