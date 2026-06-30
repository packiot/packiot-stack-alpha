package metrics

import "github.com/prometheus/client_golang/prometheus"

// ConsumerSnapshot mirrors the fields amqp.Consumer's Snapshot already
// surfaces. Passed as a closure (not an interface) so the metrics
// package stays free of imports from amqp/handlers — no cycles, no
// pressure to add accessor methods to existing types.
type ConsumerSnapshot struct {
	Delivered         uint64
	Acked             uint64
	NackedToRetry     uint64
	PublishedToFailed uint64
}

// RegisterConsumerCollector wires the Consumer's atomic counters into
// Prometheus via a custom Collector — read on scrape, no goroutine, no
// double counting. Same shape as the Go runtime collectors.
//
// These are GLOBAL counters (no labels). The per-delivery counter
// `edge_transformer_amqp_deliveries_total` (in metrics.go) carries the
// tenant + routing_key + result labels — that's where you graph per-tenant
// rates. Keeping the global counters here lets dashboards show "total
// inbound across all tenants" with one query.
func (m *Metrics) RegisterConsumerCollector(snap func() ConsumerSnapshot) {
	m.Registry.MustRegister(&consumerCollector{
		snap:      snap,
		delivered: prometheus.NewDesc("edge_transformer_amqp_delivered_total", "Messages received from per-tenant queues (cumulative, all tenants).", nil, nil),
		acked:     prometheus.NewDesc("edge_transformer_amqp_acked_total", "Messages acked after successful handler.", nil, nil),
		nacked:    prometheus.NewDesc("edge_transformer_amqp_nacked_retry_total", "Messages nacked with requeue=false → DLX → retry cycle.", nil, nil),
		failed:    prometheus.NewDesc("edge_transformer_amqp_published_to_failed_total", "Messages published to failed exchange after retry limit.", nil, nil),
	})
}

type consumerCollector struct {
	snap                             func() ConsumerSnapshot
	delivered, acked, nacked, failed *prometheus.Desc
}

func (c *consumerCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.delivered
	ch <- c.acked
	ch <- c.nacked
	ch <- c.failed
}

func (c *consumerCollector) Collect(ch chan<- prometheus.Metric) {
	s := c.snap()
	ch <- prometheus.MustNewConstMetric(c.delivered, prometheus.CounterValue, float64(s.Delivered))
	ch <- prometheus.MustNewConstMetric(c.acked, prometheus.CounterValue, float64(s.Acked))
	ch <- prometheus.MustNewConstMetric(c.nacked, prometheus.CounterValue, float64(s.NackedToRetry))
	ch <- prometheus.MustNewConstMetric(c.failed, prometheus.CounterValue, float64(s.PublishedToFailed))
}

// ShadowSnapshot mirrors handlers.ShadowStats. The shadow handler reports
// total observed messages, broken down per-tenant via the `tenant` label.
// Same exact label-discipline pattern as oeecloud-worker's POParameter
// collector — letting Phase 2 swap Shadow for real handlers without
// changing the dashboard PromQL.
type ShadowSnapshot struct {
	// Observed[tenant] = cumulative count of messages the shadow handler
	// has seen for that tenant. Skeleton uses one tenant per process,
	// but the map shape generalizes to Phase 2 multi-tenant deployments.
	Observed map[string]uint64
}

// RegisterShadowCollector emits one counter per tenant under the same
// metric name, with distinct `tenant` label values. Prometheus-idiomatic.
//
// TODO(ADR-0009 Phase 2): when Shadow is replaced by real per-routing-key
// handlers, retire this collector and register a per-writer collector
// (e.g. RegisterCalcCountersCollector) following the exact shape of
// oeecloud-worker's RegisterPOParameterCollector.
func (m *Metrics) RegisterShadowCollector(snap func() ShadowSnapshot) {
	m.Registry.MustRegister(&shadowCollector{
		snap: snap,
		desc: prometheus.NewDesc(
			"edge_transformer_handler_shadow_observed_total",
			"Messages observed by the shadow (no-op) handler, broken down by tenant.",
			[]string{"tenant"}, nil,
		),
	})
}

type shadowCollector struct {
	snap func() ShadowSnapshot
	desc *prometheus.Desc
}

func (c *shadowCollector) Describe(ch chan<- *prometheus.Desc) { ch <- c.desc }

func (c *shadowCollector) Collect(ch chan<- prometheus.Metric) {
	s := c.snap()
	for tenant, v := range s.Observed {
		ch <- prometheus.MustNewConstMetric(c.desc, prometheus.CounterValue, float64(v), tenant)
	}
}
