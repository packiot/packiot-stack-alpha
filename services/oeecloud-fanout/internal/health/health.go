// Package health exposes a tiny /health HTTP endpoint returning a JSON
// snapshot, matching the oeecloud-worker convention so the distroless image can
// self-probe via a `--healthcheck` subcommand.
package health

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"
)

// Snapshotter produces the JSON body + healthy flag for /health.
type Snapshotter interface {
	Snapshot() (body []byte, healthy bool, err error)
}

type Server struct {
	srv    *http.Server
	logger *slog.Logger
}

// New returns a Server bound to addr (e.g. ":9102"). Healthy → 200,
// unhealthy/build-error → 503/500.
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
