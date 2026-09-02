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

// ── ADR-0011 P1: MQTT subscriber + shadow publisher + sparkplug state ───────
//
// These collectors follow the same "snapshot function passed as closure"
// pattern above so the metrics package stays decoupled from the
// mqtt/analyticspub/sparkplug packages (no cycles).

// MQTTSubscriberSnapshot is what the subscriber must produce for scrape.
// Fields map 1:1 to the atomic counters + connected flag on mqtt.Subscriber.
type MQTTSubscriberSnapshot struct {
	Received     uint64
	Handled      uint64
	HandleErrors uint64
	Reconnects   uint64
	Dropped      uint64 // ADR-0011 P1 — queue-full drops
	Connected    bool
}

// RegisterMQTTSubscriberCollector emits the MQTT-layer counters + connection
// gauge. Kept parallel to the amqp consumer collector so operator dashboards
// can flip between them without re-learning label conventions.
func (m *Metrics) RegisterMQTTSubscriberCollector(snap func() MQTTSubscriberSnapshot) {
	m.Registry.MustRegister(&mqttSubscriberCollector{
		snap:         snap,
		received:     prometheus.NewDesc("edge_transformer_mqtt_received_total", "Messages received from the MQTT broker (before Handler).", nil, nil),
		handled:      prometheus.NewDesc("edge_transformer_mqtt_handled_total", "Messages that the Handler processed successfully.", nil, nil),
		handleErrors: prometheus.NewDesc("edge_transformer_mqtt_handle_errors_total", "Messages the Handler returned an error for OR unparseable topics.", nil, nil),
		reconnects:   prometheus.NewDesc("edge_transformer_mqtt_reconnects_total", "Broker reconnect events (paho AutoReconnect + our OnConnectionLost handler).", nil, nil),
		dropped:      prometheus.NewDesc("edge_transformer_mqtt_dropped_total", "Messages dropped because the bounded ingestion queue was full (ADR-0011 rule 5).", []string{"reason"}, nil),
		connected:    prometheus.NewDesc("edge_transformer_mqtt_connected", "1 if the subscriber is currently connected to the broker, 0 otherwise.", nil, nil),
	})
}

type mqttSubscriberCollector struct {
	snap                                                            func() MQTTSubscriberSnapshot
	received, handled, handleErrors, reconnects, dropped, connected *prometheus.Desc
}

func (c *mqttSubscriberCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.received
	ch <- c.handled
	ch <- c.handleErrors
	ch <- c.reconnects
	ch <- c.dropped
	ch <- c.connected
}

func (c *mqttSubscriberCollector) Collect(ch chan<- prometheus.Metric) {
	s := c.snap()
	ch <- prometheus.MustNewConstMetric(c.received, prometheus.CounterValue, float64(s.Received))
	ch <- prometheus.MustNewConstMetric(c.handled, prometheus.CounterValue, float64(s.Handled))
	ch <- prometheus.MustNewConstMetric(c.handleErrors, prometheus.CounterValue, float64(s.HandleErrors))
	ch <- prometheus.MustNewConstMetric(c.reconnects, prometheus.CounterValue, float64(s.Reconnects))
	ch <- prometheus.MustNewConstMetric(c.dropped, prometheus.CounterValue, float64(s.Dropped), "queue_full")
	var connected float64
	if s.Connected {
		connected = 1
	}
	ch <- prometheus.MustNewConstMetric(c.connected, prometheus.GaugeValue, connected)
}

// ShadowPublisherSnapshot is the ADR-0011 P0-1 analyticspub view for scrape.
type ShadowPublisherSnapshot struct {
	Published       uint64
	Confirmed       uint64
	Nacked          uint64
	ConfirmTimeouts uint64
	Failed          uint64
	InFlight        uint64
}

// RegisterShadowPublisherCollector exposes the publisher-confirms counters
// (ADR-0011 P0-1). The nacked / confirmTimeout counters are the alerting
// primary — nack in particular indicates broker resource alarm.
func (m *Metrics) RegisterShadowPublisherCollector(snap func() ShadowPublisherSnapshot) {
	m.Registry.MustRegister(&shadowPublisherCollector{
		snap:            snap,
		published:       prometheus.NewDesc("edge_transformer_shadowpub_published_total", "Messages published to RabbitMQ (may or may not be broker-confirmed).", nil, nil),
		confirmed:       prometheus.NewDesc("edge_transformer_shadowpub_confirmed_total", "Messages the broker basic.acked (ADR-0011 P0-1).", nil, nil),
		nacked:          prometheus.NewDesc("edge_transformer_shadowpub_nacked_total", "Messages the broker basic.nacked — check RabbitMQ resource alarms.", nil, nil),
		confirmTimeouts: prometheus.NewDesc("edge_transformer_shadowpub_confirm_timeouts_total", "Messages the broker didn't confirm within ConfirmTimeout.", nil, nil),
		failed:          prometheus.NewDesc("edge_transformer_shadowpub_failed_total", "PublishWithContext-level failures (network, channel closed).", nil, nil),
		inFlight:        prometheus.NewDesc("edge_transformer_shadowpub_in_flight", "In-flight messages: published minus confirmed. Growing = broker slow.", nil, nil),
	})
}

type shadowPublisherCollector struct {
	snap                                                            func() ShadowPublisherSnapshot
	published, confirmed, nacked, confirmTimeouts, failed, inFlight *prometheus.Desc
}

func (c *shadowPublisherCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.published
	ch <- c.confirmed
	ch <- c.nacked
	ch <- c.confirmTimeouts
	ch <- c.failed
	ch <- c.inFlight
}

func (c *shadowPublisherCollector) Collect(ch chan<- prometheus.Metric) {
	s := c.snap()
	ch <- prometheus.MustNewConstMetric(c.published, prometheus.CounterValue, float64(s.Published))
	ch <- prometheus.MustNewConstMetric(c.confirmed, prometheus.CounterValue, float64(s.Confirmed))
	ch <- prometheus.MustNewConstMetric(c.nacked, prometheus.CounterValue, float64(s.Nacked))
	ch <- prometheus.MustNewConstMetric(c.confirmTimeouts, prometheus.CounterValue, float64(s.ConfirmTimeouts))
	ch <- prometheus.MustNewConstMetric(c.failed, prometheus.CounterValue, float64(s.Failed))
	ch <- prometheus.MustNewConstMetric(c.inFlight, prometheus.GaugeValue, float64(s.InFlight))
}

// SparkplugSeqGap is a single observed sequence-number gap from a Sparkplug
// publisher. Emitted by StateStore.OnSeqGap; kept as a per-observation
// event rather than a running counter so we don't lose per-publisher
// visibility to label cardinality.
//
// The subscriber wires OnSeqGap → SparkplugGaps counter increment. This
// struct isn't exposed as a metric directly.
type SparkplugSeqGap struct {
	GroupID    string
	EdgeNodeID string
	DeviceID   string
	Expected   uint64
	Got        uint64
}

// NewSparkplugGapsCounter returns the labeled counter for sequence gaps.
// Main.go wires the seq-gap callback → this counter's Inc(). Labels are
// bounded per factory (dozens of edges × dozens of devices) so cardinality
// stays sane.
func (m *Metrics) NewSparkplugGapsCounter() *prometheus.CounterVec {
	c := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "edge_transformer_sparkplug_seq_gaps_total",
		Help: "Sparkplug sequence-number gaps observed per publisher — indicates messages were lost at the broker or between broker and subscriber.",
	}, []string{"group_id", "edge_node_id", "device_id"})
	m.Registry.MustRegister(c)
	return c
}
