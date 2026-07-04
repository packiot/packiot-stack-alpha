// Package metrics owns the Prometheus registry + collectors for the
// mirror-worker. Exposed on the same HTTP server as /health, at /metrics.
//
// Naming convention mirrors oeecloud-worker — prefix `mirror_worker_`,
// no language suffix (Prometheus convention is "drop the implementation
// language from the metric name; tracking which binary produces it is a
// scrape-config concern, not a metric concern").
//
// Label discipline:
//   - event_type — prod user_logs.category (order-status-changed,
//     event-justified, etc.). Cardinality is bounded by the
//     10 ported handlers + "unknown" for unmapped categories.
//   - outcome    — ok | failed | skipped. ok = handler returned nil;
//     failed = handler returned non-nil → DLQ; skipped =
//     no handler registered OR row was already replayed
//     (idempotency hit on mirror_id_map).
package metrics

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Registry is the package-level Prometheus registry. Using a custom
// registry (not the global default) is deliberate — same convention as
// oeecloud-worker's `metrics.New()`. It keeps scrape output focused on
// our worker's metrics + the standard Go runtime/process collectors,
// without picking up anything random a transitive dep might register on
// the default registry.
var Registry = prometheus.NewRegistry()

// Handler returns the /metrics HTTP handler bound to Registry. Pattern
// match with oeecloud-worker so the health server wiring is identical.
func Handler() http.Handler {
	return promhttp.HandlerFor(Registry, promhttp.HandlerOpts{Registry: Registry})
}
