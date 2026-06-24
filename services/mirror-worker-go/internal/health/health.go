// Package health serves a small /health JSON endpoint. Same convention
// as the TS mirror-worker /health: healthy|degraded|unhealthy + counters.
//
// /metrics is mounted on the same mux — Prometheus scrape target. See
// internal/metrics for the registry + collectors.
package health

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
)

type State struct {
	mu             sync.RWMutex
	startedAt      time.Time
	lastTickAt     atomic.Int64 // unix nano
	lastError      string
	source         string
	pollIntervalMs int64
}

func NewState(source string, pollIntervalSec int) *State {
	return &State{
		startedAt:      time.Now(),
		source:         source,
		pollIntervalMs: int64(pollIntervalSec) * 1000,
	}
}

func (s *State) RecordTickSuccess() {
	s.lastTickAt.Store(time.Now().UnixNano())
	s.mu.Lock()
	s.lastError = ""
	s.mu.Unlock()
}

func (s *State) RecordTickError(err error) {
	s.lastTickAt.Store(time.Now().UnixNano())
	s.mu.Lock()
	s.lastError = err.Error()
	s.mu.Unlock()
}

type body struct {
	Status      string `json:"status"`
	Source      string `json:"source"`
	UptimeSec   int64  `json:"uptimeSec"`
	LastTickMs  int64  `json:"lastTickAgeMs,omitempty"`
	LastError   string `json:"lastError,omitempty"`
}

func (s *State) snapshot() body {
	s.mu.RLock()
	lastErr := s.lastError
	s.mu.RUnlock()
	now := time.Now()
	out := body{
		Source:    s.source,
		UptimeSec: int64(now.Sub(s.startedAt).Seconds()),
		LastError: lastErr,
	}
	if last := s.lastTickAt.Load(); last > 0 {
		ageMs := (now.UnixNano() - last) / int64(time.Millisecond)
		out.LastTickMs = ageMs
		switch {
		case ageMs > s.pollIntervalMs*10:
			out.Status = "unhealthy"
		case ageMs > s.pollIntervalMs*3 || lastErr != "":
			out.Status = "degraded"
		default:
			out.Status = "healthy"
		}
	} else if out.UptimeSec > 2*s.pollIntervalMs/1000 {
		out.Status = "unhealthy"
	} else {
		out.Status = "healthy" // warming up
	}
	return out
}

type Server struct {
	srv    *http.Server
	logger *slog.Logger
}

func New(addr string, state *State, logger *slog.Logger) *Server {
	mux := http.NewServeMux()
	// /metrics — Prometheus scrape endpoint. Same pattern as oeecloud-worker.
	mux.Handle("/metrics", metrics.Handler())
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		b := state.snapshot()
		raw, err := json.Marshal(b)
		w.Header().Set("Content-Type", "application/json")
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprintf(w, `{"status":"unhealthy","error":%q}`, err.Error())
			return
		}
		if b.Status == "unhealthy" {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_, _ = w.Write(raw)
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

func (s *Server) Shutdown(ctx context.Context) error { return s.srv.Shutdown(ctx) }
