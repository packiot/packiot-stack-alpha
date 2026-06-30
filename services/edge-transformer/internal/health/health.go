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
package health

import (
	"context"
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
