// Package health exposes a tiny /health HTTP endpoint that returns
// the consumer's Snapshot as JSON. Same shape pattern as mirror-worker's
// /health so Grafana/uptime probes can reuse panels.
package health

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"
)

// Snapshotter produces the body + healthy flag directly. Callers (e.g.
// amqp.Consumer) own the struct shape AND the marshal step; health.go
// just writes the bytes. This avoids the marshal→unmarshal→remarshal
// dance an `any`-returning interface forces.
type Snapshotter interface {
	Snapshot() (body []byte, healthy bool, err error)
}

// Server wraps an http.Server so main can shutdown gracefully.
type Server struct {
	srv    *http.Server
	logger *slog.Logger
}

// New returns a Server bound to addr (e.g. ":9101"). Healthy snapshots
// return 200, unhealthy or build-error return 503 — same convention as
// mirror-worker. Degraded states still return 200 so a single missed
// delivery doesn't trip orchestration; Grafana alerts on the JSON fields.
func New(addr string, snap Snapshotter, logger *slog.Logger) *Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
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
	})

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
