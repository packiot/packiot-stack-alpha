// Package health exposes a tiny /healthz HTTP endpoint that returns the
// consumer's Snapshot as JSON. Same shape as oeecloud-worker and
// mirror-worker-go so Grafana panels + uptime probes can reuse panels.
//
// Endpoint path is `/healthz` (Kubernetes-idiomatic; matches mirror-worker
// and prepares the service for ADR-0005 self-hosted-runner / future K8s
// deploys). The Docker healthcheck binary calls the same path.
//
// Port: 9102 (config default). This deliberately differs from
// oeecloud-worker's 9101 so the two services can colocate on a single
// EC2 / single factory machine without port collision.
//
// TODO(ADR-0009 Phase 2): when Phase 3 ships outbox + reanimator, add
// dedicated /healthz/ready (broker connected AND outbox loop running)
// vs /healthz/live (process alive). Today the simple "consumer healthy"
// boolean is enough.
//
// ADR-0011 rule 4: health endpoints MUST expose degraded states — never
// silent-degrade. When a subscriber is enabled but hasn't received messages
// in >60s, or when the publisher has unconfirmed messages backlog >
// threshold, /healthz returns 503 with a structured `degraded_components`
// field naming what's wrong. Ops learns of trouble before customers do.
package health

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Snapshotter produces the body + healthy flag directly. Callers (e.g.
// amqp.Consumer) own the struct shape AND the marshal step; health.go
// just writes the bytes. Avoids the marshal→unmarshal→remarshal dance
// an `any`-returning interface forces.
type Snapshotter interface {
	Snapshot() (body []byte, healthy bool, err error)
}

// ComponentSnapshotter is a lighter interface for individual sub-components
// (MQTT subscriber, shadow publisher, alias-table). Returns a JSON-shaped
// struct + a per-component degraded reason (empty = healthy). MultiSnapshotter
// aggregates N of these into the top-level /healthz response.
//
// ADR-0011 rule 4: the reason string MUST be non-empty when returning
// degraded=true. Silent degradation is a bug.
type ComponentSnapshotter interface {
	// Component returns the display name used in the aggregated JSON body.
	Component() string

	// SnapshotDetail returns the JSON body for this component (unmarshaled
	// to `any` — the aggregator re-marshals in the outer envelope).
	SnapshotDetail() any

	// Degraded returns a non-empty human-readable reason if the component
	// is degraded, or empty string if healthy. Called every request.
	Degraded() string
}

// MultiSnapshotter aggregates N per-component snapshots into a single
// /healthz JSON body. Overall healthy = every component's Degraded() is
// empty. The response body always includes a `components` map keyed by
// each component's Component() name + a `degraded_components` array listing
// the names + reasons of any degraded components (empty when healthy).
//
// ADR-0011 rule 4: when any CRITICAL component is degraded, HTTP status is 503,
// AND the body identifies which one + why.
//
// LIVENESS vs READINESS (multi-tenant blast-radius control). Components register
// in one of two tiers:
//   - Add (CRITICAL / liveness): degradation flips the top-level `healthy`
//     boolean → 503 → the container HEALTHCHECK fails → the process is killed
//     and restarted. Use for anything whose loss means the WHOLE process is
//     unfit to run (the raw subscriber, the single-file uplink).
//   - AddReadiness (non-critical): degradation is surfaced in the response body
//     (`degraded_components`) so ops/readiness probes see it, but it does NOT
//     flip `healthy` — the container stays up. Use for per-tenant uplinks in a
//     multi-tenant agent, so ONE tenant's broker blip cannot bounce the whole
//     process and take every other tenant down with it.
//
// Single-file agents register their one uplink via Add (critical), so their
// /healthz semantics are exactly as before this split existed.
type MultiSnapshotter struct {
	components []ComponentSnapshotter // CRITICAL — degradation flips healthy (503 / container-kill)
	readiness  []ComponentSnapshotter // non-critical — surfaced in body, never flips healthy
	startedAt  time.Time
}

// NewMulti returns an empty MultiSnapshotter. Add components before passing
// to health.New.
func NewMulti() *MultiSnapshotter {
	return &MultiSnapshotter{startedAt: time.Now()}
}

// Add registers a CRITICAL (liveness) component: its degradation flips the
// aggregate `healthy` to false → 503 → container restart. Order preserved in
// the JSON response for deterministic dashboarding.
func (m *MultiSnapshotter) Add(c ComponentSnapshotter) {
	m.components = append(m.components, c)
}

// AddReadiness registers a non-critical (readiness) component: its degradation
// is reported in the response body's `degraded_components` but does NOT flip the
// aggregate `healthy` boolean, so it never triggers a container-kill. This is
// how a multi-tenant agent isolates the blast radius of one tenant's uplink
// degradation from every co-tenant sharing the same process.
func (m *MultiSnapshotter) AddReadiness(c ComponentSnapshotter) {
	m.readiness = append(m.readiness, c)
}

type degradedItem struct {
	Component string `json:"component"`
	Reason    string `json:"reason"`
}

// Snapshot implements Snapshotter — aggregates each ComponentSnapshotter. The
// returned `healthy` boolean (which drives the HTTP status + the container
// HEALTHCHECK) reflects ONLY the CRITICAL tier; readiness components that are
// degraded still appear in `degraded_components` but keep `healthy` true.
func (m *MultiSnapshotter) Snapshot() ([]byte, bool, error) {
	components := make(map[string]any, len(m.components)+len(m.readiness))
	var degraded []degradedItem

	// Critical tier — degradation here flips liveness (container-kill).
	healthy := true
	for _, c := range m.components {
		components[c.Component()] = c.SnapshotDetail()
		if reason := c.Degraded(); reason != "" {
			degraded = append(degraded, degradedItem{Component: c.Component(), Reason: reason})
			healthy = false
		}
	}
	// Readiness tier — surfaced in the body, but never flips liveness.
	for _, c := range m.readiness {
		components[c.Component()] = c.SnapshotDetail()
		if reason := c.Degraded(); reason != "" {
			degraded = append(degraded, degradedItem{Component: c.Component(), Reason: reason})
		}
	}

	body, err := json.MarshalIndent(map[string]any{
		"healthy":             healthy,
		"started_at":          m.startedAt.Format(time.RFC3339),
		"uptime_seconds":      int(time.Since(m.startedAt).Seconds()),
		"components":          components,
		"degraded_components": degraded,
	}, "", "  ")
	if err != nil {
		return nil, false, fmt.Errorf("health: marshal: %w", err)
	}
	return body, healthy, nil
}

// Server wraps an http.Server so main can shutdown gracefully.
type Server struct {
	srv    *http.Server
	logger *slog.Logger
}

// New returns a Server bound to addr (e.g. ":9102"). Healthy snapshots
// return 200; unhealthy or build-error return 503 — same convention as
// oeecloud-worker and mirror-worker.
//
// promReg may be nil — if non-nil, /metrics serves the Prometheus gather
// output from that registry on the same port.
func New(addr string, snap Snapshotter, promReg *prometheus.Registry, logger *slog.Logger) *Server {
	mux := http.NewServeMux()
	if promReg != nil {
		mux.Handle("/metrics", promhttp.HandlerFor(promReg, promhttp.HandlerOpts{Registry: promReg}))
	}
	handler := func(w http.ResponseWriter, r *http.Request) {
		body, healthy, err := snap.Snapshot()
		w.Header().Set("Content-Type", "application/json")
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprintf(w, `{"healthy":false,"error":%q}`, err.Error())
			return
		}
		if !healthy {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_, _ = w.Write(body)
	}
	mux.HandleFunc("/healthz", handler)
	// /health alias kept for parity with oeecloud-worker's pre-K8s
	// path. Drop in Phase 3 once dashboards have migrated to /healthz.
	mux.HandleFunc("/health", handler)

	return &Server{
		srv: &http.Server{
			Addr:              addr,
			Handler:           mux,
			ReadHeaderTimeout: 5 * time.Second,
		},
		logger: logger,
	}
}

func (s *Server) Start() {
	s.logger.Info("health server listening", slog.String("addr", s.srv.Addr))
	go func() {
		if err := s.srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			s.logger.Error("health server failed", slog.String("err", err.Error()))
		}
	}()
}

func (s *Server) Shutdown(ctx context.Context) error {
	return s.srv.Shutdown(ctx)
}
