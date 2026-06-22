// Package health exposes a tiny /health HTTP endpoint that returns
// the consumer's Snapshot as JSON. Same shape pattern as mirror-worker's
// /health so Grafana/uptime probes can reuse panels.
package health

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"
)

// Snapshotter is what /health needs from the consumer (interface to avoid
// pkg cycles between handlers→amqp).
type Snapshotter interface {
	Snapshot() any
}

// Server wraps an http.Server so main can shutdown gracefully.
type Server struct {
	srv    *http.Server
	logger *slog.Logger
}

// New returns a Server bound to addr (e.g. ":9101"). Healthy snapshots
// return 200, unhealthy (or build error) return 503 — same convention as
// mirror-worker. Degraded states still return 200 so a single missed
// delivery doesn't trip orchestration; Grafana alerts on the JSON fields.
func New(addr string, snap Snapshotter, logger *slog.Logger) *Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		s := snap.Snapshot()
		w.Header().Set("Content-Type", "application/json")
		body, err := json.Marshal(s)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprintf(w, `{"healthy":false,"error":%q}`, err.Error())
			return
		}
		// Inspect healthy field. If map has Healthy=false → 503.
		// snap.Snapshot() returns a struct value; we re-parse for the field.
		var meta struct {
			Healthy bool `json:"healthy"`
		}
		_ = json.Unmarshal(body, &meta)
		if !meta.Healthy {
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
