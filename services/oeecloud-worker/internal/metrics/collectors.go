package metrics

import "github.com/prometheus/client_golang/prometheus"

// ConsumerSnapshot mirrors the fields amqp.Consumer's Snapshot already
// surfaces. Passed as a closure (not an interface) so the metrics
// package stays free of imports from amqp/writers — no cycles, no
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
func (m *Metrics) RegisterConsumerCollector(snap func() ConsumerSnapshot) {
	m.Registry.MustRegister(&consumerCollector{
		snap:      snap,
		delivered: prometheus.NewDesc("oeecloud_worker_amqp_delivered_total", "Messages received from source queue (cumulative).", nil, nil),
		acked:     prometheus.NewDesc("oeecloud_worker_amqp_acked_total", "Messages acked after successful handler.", nil, nil),
		nacked:    prometheus.NewDesc("oeecloud_worker_amqp_nacked_retry_total", "Messages nacked with requeue=false → DLX → retry cycle.", nil, nil),
		failed:    prometheus.NewDesc("oeecloud_worker_amqp_published_to_failed_total", "Messages published to oee-failed after retry limit.", nil, nil),
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

// POParameterSnapshot mirrors writers.POParameterStats fields.
type POParameterSnapshot struct {
	WroteIdealSpeed  uint64
	SkippedLineOrder uint64
	SkippedPOCtl     uint64
	SkippedOther     uint64
}

// RegisterPOParameterCollector emits 4 metrics under the same name with
// distinct `op` label values — Prometheus-idiomatic grouping. At scale,
// `op="skipped_30700"` and `op="skipped_30800_30899"` reveal real
// frequency under live CPACK traffic and size the #32 port-or-defer call.
func (m *Metrics) RegisterPOParameterCollector(snap func() POParameterSnapshot) {
	m.Registry.MustRegister(&poParameterCollector{
		snap: snap,
		desc: prometheus.NewDesc(
			"oeecloud_worker_writer_po_parameter_ops_total",
			"PO Parameter writer operations by op (wrote_ideal_speed | skipped_30700 | skipped_30800_30899 | skipped_other).",
			[]string{"op"}, nil,
		),
	})
}

type poParameterCollector struct {
	snap func() POParameterSnapshot
	desc *prometheus.Desc
}

func (c *poParameterCollector) Describe(ch chan<- *prometheus.Desc) { ch <- c.desc }

func (c *poParameterCollector) Collect(ch chan<- prometheus.Metric) {
	s := c.snap()
	emit := func(op string, v uint64) {
		ch <- prometheus.MustNewConstMetric(c.desc, prometheus.CounterValue, float64(v), op)
	}
	emit("wrote_ideal_speed", s.WroteIdealSpeed)
	emit("skipped_30700", s.SkippedLineOrder)
	emit("skipped_30800_30899", s.SkippedPOCtl)
	emit("skipped_other", s.SkippedOther)
}
