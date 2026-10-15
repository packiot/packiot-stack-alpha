package mirror

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics are prod-reflector's Prometheus series (job prod-reflector, monitoring/prometheus/rules.yml ProdMirror*).
type Metrics struct {
	reg *prometheus.Registry

	Passes        *prometheus.CounterVec // enterprise, kind (hot|full), result (converged|unconverged|error|skipped)
	Rows          *prometheus.CounterVec // enterprise, table, op (upsert|delete|divergent)
	Guarded       *prometheus.CounterVec // enterprise, table, reason (max_deletes|empty_source)
	TableErrors   *prometheus.CounterVec // enterprise, table
	StagingWrites *prometheus.CounterVec // enterprise, table — a mirrored row changed on staging (a missed write surface)
	LastConverged *prometheus.GaugeVec   // enterprise — unix seconds of the last fully converged pass
	PassSeconds   *prometheus.GaugeVec   // enterprise, kind
	Unclassified  prometheus.Gauge       // tenant-keyed tables neither Reflected nor Local
	Enabled       prometheus.Gauge       // 1 when PROD_MIRROR_ENTERPRISES is set
}

// NewMetrics registers the series.
func NewMetrics() *Metrics {
	reg := prometheus.NewRegistry()
	m := &Metrics{
		reg: reg,
		Passes: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "prod_reflector_passes_total",
			Help: "Reflect passes by enterprise, kind (hot|full) and result (converged|unconverged|error|skipped)"},
			[]string{"enterprise", "kind", "result"}),
		Rows: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "prod_reflector_rows_total",
			Help: "Rows converged on staging, by table and op (upsert|delete|divergent)"},
			[]string{"enterprise", "table", "op"}),
		Guarded: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "prod_reflector_guarded_total",
			Help: "Deletes refused by a guard (max_deletes|empty_source), by table"},
			[]string{"enterprise", "table", "reason"}),
		TableErrors: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "prod_reflector_table_errors_total",
			Help: "Tables whose convergence statement failed in a pass (rolled back to the savepoint)"},
			[]string{"enterprise", "table"}),
		StagingWrites: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "prod_reflector_staging_writes_total",
			Help: "Mirrored rows changed ON STAGING since the reflector last wrote them (a write surface the block missed)"},
			[]string{"enterprise", "table"}),
		LastConverged: prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "prod_reflector_last_converged_timestamp_seconds",
			Help: "Unix time of the last pass that left staging equal to production"}, []string{"enterprise"}),
		PassSeconds: prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: "prod_reflector_pass_seconds",
			Help: "Duration of the last pass"}, []string{"enterprise", "kind"}),
		Unclassified: prometheus.NewGauge(prometheus.GaugeOpts{Name: "prod_reflector_unclassified_tables",
			Help: "Tenant-keyed staging tables that are neither reflected nor local (decide them in internal/mirror/spec.go)"}),
		Enabled: prometheus.NewGauge(prometheus.GaugeOpts{Name: "prod_reflector_enabled",
			Help: "1 when PROD_MIRROR_ENTERPRISES is set (staging mirrors production)"}),
	}
	reg.MustRegister(m.Passes, m.Rows, m.Guarded, m.TableErrors, m.StagingWrites, m.LastConverged, m.PassSeconds,
		m.Unclassified, m.Enabled)
	return m
}

// Handler serves /metrics.
func (m *Metrics) Handler() http.Handler { return promhttp.HandlerFor(m.reg, promhttp.HandlerOpts{}) }
