package adapter

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Metrics holds the Prometheus collectors for the adapter. One counter,
// labelled by the operator action and the outcome, is enough to answer the
// only operational question this shim raises: "are operator actions reaching
// edge-api, and with what result?"
//
// Label cardinality is deliberately bounded:
//   - action:  "downtime" | "po"
//   - outcome: "accepted" | "unauthorized" | "forbidden" | "unmapped" |
//     "bad_request" | "edge_4xx" | "edge_5xx" | "edge_unreachable"
//
// PII (operator name, notes, PO numbers) NEVER becomes a label — that would
// both leak data into the metrics store and blow up cardinality.
type Metrics struct {
	Requests *prometheus.CounterVec
}

// NewMetrics registers the collectors on the given registry. Taking the
// registry as an argument (instead of using the global default) keeps tests
// isolated — each test builds a fresh registry and asserts on it.
func NewMetrics(reg prometheus.Registerer) *Metrics {
	factory := promauto.With(reg)
	return &Metrics{
		Requests: factory.NewCounterVec(
			prometheus.CounterOpts{
				Name: "operator_adapter_requests_total",
				Help: "Operator actions received by the adapter, by action and outcome.",
			},
			[]string{"action", "outcome"},
		),
	}
}

// observe records a single request outcome.
func (m *Metrics) observe(action, outcome string) {
	if m == nil || m.Requests == nil {
		return
	}
	m.Requests.WithLabelValues(action, outcome).Inc()
}
