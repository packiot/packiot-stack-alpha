// routes.go — the ONE place every mux route is mounted.
//
// Registration used to be spread across main() (endpoints loop, /metrics,
// /healthz) and the register* helpers, called at different points of boot. It is
// gathered here so a test can mount the WHOLE surface onto a recorder and compare
// it with the OpenAPI document (openapi_test.go): a route added without a spec
// entry, or a spec entry for a route that no longer exists, fails CI instead of
// drifting silently. The handlers only capture their deps; nothing here touches
// the DB at registration time, so the test can pass nil pools.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/packiot/packiot-stack-alpha/services/read-api/internal/cache"
)

// routeMux is the registration surface the register* helpers write to.
// *http.ServeMux satisfies it; patternRecorder wraps one to list what was mounted.
type routeMux interface {
	Handle(pattern string, handler http.Handler)
	HandleFunc(pattern string, handler func(http.ResponseWriter, *http.Request))
}

// patternRecorder forwards to a real ServeMux (so duplicate/invalid patterns still
// panic exactly as in production) and remembers every pattern, in order.
type patternRecorder struct {
	mux      *http.ServeMux
	patterns []string
}

func (p *patternRecorder) Handle(pattern string, handler http.Handler) {
	p.patterns = append(p.patterns, pattern)
	p.mux.Handle(pattern, handler)
}

func (p *patternRecorder) HandleFunc(pattern string, handler func(http.ResponseWriter, *http.Request)) {
	p.patterns = append(p.patterns, pattern)
	p.mux.HandleFunc(pattern, handler)
}

// routeDeps is what the handlers capture. All of it may be nil in tests: the
// handlers dereference their deps per request, never at registration.
type routeDeps struct {
	pool     *pgxpool.Pool
	qcache   *cache.Cache
	histPool *pgxpool.Pool
	keys     map[string]int
	logger   *slog.Logger
}

// registerRoutes mounts every route the service serves. The auth middleware
// (main.go) wraps the result; which routes it exempts is the manifest's call
// (auth.go), not this function's.
func registerRoutes(mux routeMux, d routeDeps) {
	for _, ep := range endpoints {
		mux.HandleFunc(ep.path, makeHandler(d.pool, ep, d.logger))
	}
	registerQueryAPI(mux, d.pool, d.qcache)    // ADR-0015 P1-P3 + ADR-0035 cache-aside
	registerInternalAPI(mux, d.pool, d.logger) // ADR-0046 #19a device_key → id_equipment resolver
	registerHistorianAPI(mux, d.histPool, d.logger)
	// ADR-0031 Workstream B: the external-contract anti-corruption shims. They
	// resolve the tenant through the SAME key map (single injection authority)
	// but self-authenticate, so they sit in the auth-exempt set.
	registerExternalShims(mux, d.pool, d.keys, d.logger)

	// Gap-closure 2026-07-07: the only service without /metrics.
	// promhttp default registry — request counts come from reqCount
	// (incremented in makeHandler's wrapper below); Go runtime metrics
	// ride along free.
	// EnableOpenMetrics lets the handler negotiate the OpenMetrics exposition
	// (Prometheus sends Accept: application/openmetrics-text) — the only format
	// that carries the trace_id exemplars httpmetrics attaches. Plain-text
	// scrapers simply get the histogram without exemplars.
	mux.Handle("/metrics", promhttp.HandlerFor(prometheus.DefaultGatherer, promhttp.HandlerOpts{EnableOpenMetrics: true}))
	pool := d.pool
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if err := pool.Ping(ctx); err != nil {
			http.Error(w, `{"healthy":false}`, http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintf(w, `{"healthy":true,"served":%d,"failed":%d}`, served.Load(), failed.Load())
	})
	// The OpenAPI 3.1 document, built ONCE from the same tables mounted above
	// (openapi.go). Unauthenticated inside the service (routeInfra); who can
	// reach it publicly is nginx's decision. Spec only — the UI is the central
	// portal's job.
	mux.HandleFunc("/openapi.json", openAPIHandler())
}
