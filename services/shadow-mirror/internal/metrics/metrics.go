// Package metrics wires shadow-mirror Prometheus counters.
package metrics

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Metrics struct {
	registry *prometheus.Registry

	Dispatched *prometheus.CounterVec // by category — successful handler ack
	Skipped    *prometheus.CounterVec // by category — unknown category or ErrSkip
	Failed     *prometheus.CounterVec // by category — handler returned error
	UpdateNoop *prometheus.CounterVec // by schema+table — UPDATEs that matched 0 rows
	Cursor     prometheus.Gauge       // current cursor id_user_logs
}

func New() *Metrics {
	reg := prometheus.NewRegistry()
	m := &Metrics{
		registry: reg,
		Dispatched: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "shadow_mirror_dispatched_total",
			Help: "user_logs rows successfully dispatched to a handler",
		}, []string{"category"}),
		Skipped: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "shadow_mirror_skipped_total",
			Help: "user_logs rows skipped (unknown category or handler ErrSkip)",
		}, []string{"category"}),
		Failed: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "shadow_mirror_failed_total",
			Help: "user_logs rows whose handler returned an error",
		}, []string{"category"}),
		UpdateNoop: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "shadow_mirror_update_noop_total",
			Help: "shadow-path UPDATEs that matched zero rows (replay gap — bugs 247/248 class)",
		}, []string{"schema", "table"}),
		Cursor: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "shadow_mirror_cursor",
			Help: "current mirror_replay_cursor value for source=shadow-mirror",
		}),
	}
	reg.MustRegister(m.Dispatched, m.Skipped, m.Failed, m.UpdateNoop, m.Cursor)
	return m
}

func (m *Metrics) IncDispatched(category string) { m.Dispatched.WithLabelValues(category).Inc() }
func (m *Metrics) IncSkipped(category string)    { m.Skipped.WithLabelValues(category).Inc() }
func (m *Metrics) IncFailed(category string)     { m.Failed.WithLabelValues(category).Inc() }
func (m *Metrics) IncUpdateNoop(schema, table string) {
	m.UpdateNoop.WithLabelValues(schema, table).Inc()
}
func (m *Metrics) SetCursor(id int64) { m.Cursor.Set(float64(id)) }

// Handler exposes /metrics.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{})
}
