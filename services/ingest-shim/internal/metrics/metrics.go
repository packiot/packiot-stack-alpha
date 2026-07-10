// Package metrics owns the Prometheus registry + the single request
// counter the shim exposes. Served on the internal :9105 /metrics endpoint.
package metrics

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Outcome label values for ingest_shim_requests_total.
const (
	OutcomeReceived      = "received"       // every request that reaches the handler
	OutcomePublished     = "published"      // confirmed onto the oee exchange → 202
	OutcomeRejectedAuth  = "rejected_auth"  // missing/wrong X-Ingest-Key → 401
	OutcomeRejectedScope = "rejected_scope" // non-INCOPLAST topic → 403
	OutcomeRejectedBad   = "rejected_bad"   // empty/oversized/unparseable → 400
	OutcomePublishFailed = "publish_failed" // nack/timeout/broker error → 503
)

type Metrics struct {
	registry *prometheus.Registry
	requests *prometheus.CounterVec // labels: outcome
}

func New() *Metrics {
	reg := prometheus.NewRegistry()
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	requests := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "ingest_shim_requests_total",
		Help: "Ingest requests by outcome (received|published|rejected_auth|rejected_scope|rejected_bad|publish_failed).",
	}, []string{"outcome"})
	reg.MustRegister(requests)

	// Touch every label up-front so the series exist at 0 before the first
	// request — dashboards + alerts see the full set immediately.
	for _, o := range []string{
		OutcomeReceived, OutcomePublished, OutcomeRejectedAuth,
		OutcomeRejectedScope, OutcomeRejectedBad, OutcomePublishFailed,
	} {
		requests.WithLabelValues(o)
	}

	return &Metrics{registry: reg, requests: requests}
}

// Inc bumps the counter for one outcome.
func (m *Metrics) Inc(outcome string) {
	m.requests.WithLabelValues(outcome).Inc()
}

// Registerer exposes this service's metrics registry so middleware (e.g.
// internal/httpmetrics) can register collectors that /metrics then serves.
func (m *Metrics) Registerer() prometheus.Registerer { return m.registry }

// Handler returns an http.Handler serving /metrics from this registry.
func (m *Metrics) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{Registry: m.registry}))
	return mux
}
