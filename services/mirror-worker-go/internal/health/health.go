// Package health serves a small /health JSON endpoint. Same convention
// as the TS mirror-worker /health: healthy|degraded|unhealthy + counters.
//
// /metrics is mounted on the same mux — Prometheus scrape target. See
// internal/metrics for the registry + collectors.
//
// ADR-0011 P0-4 alignment (mirror gap 5, 2026-07-01):
//   - Response body includes `cursor` (last-replayed prod user_logs id)
//     and `dlqDepth` (bad-row count for this source) — the two numbers
//     ops has been guessing via `docker exec ... psql` for months.
//   - Response body includes `reason` when degraded — never silent-degrade.
//   - Extends (not refactors) the existing shape so Grafana panels
//     + curl-based smoke checks keep working with zero flag changes.
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

// cursorFn returns the current mirror_replay_cursor.last_log_id for this
// source. dlqDepthFn returns the count of live DLQ rows for this source.
// Both are optional — nil-safe.
type cursorFn func(ctx context.Context) (int64, error)
type dlqDepthFn func(ctx context.Context) (int64, error)

type State struct {
	mu             sync.RWMutex
	startedAt      time.Time
	lastTickAt     atomic.Int64 // unix nano
	lastError      string
	source         string
	pollIntervalMs int64

	// ADR-0011 P0-4 extensions — optional lookups populated from main.go.
	cursor   cursorFn
	dlqDepth dlqDepthFn
}

func NewState(source string, pollIntervalSec int) *State {
	return &State{
		startedAt:      time.Now(),
		source:         source,
		pollIntervalMs: int64(pollIntervalSec) * 1000,
	}
}

// WithCursor wires the cursor-lookup callback. Safe to call before Start;
// nil is treated as "not available."
func (s *State) WithCursor(fn cursorFn) { s.cursor = fn }

// WithDLQDepth wires the DLQ-depth-lookup callback. Same nil semantics.
func (s *State) WithDLQDepth(fn dlqDepthFn) { s.dlqDepth = fn }

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
	Status     string `json:"status"`
	Source     string `json:"source"`
	UptimeSec  int64  `json:"uptimeSec"`
	LastTickMs int64  `json:"lastTickAgeMs,omitempty"`
	LastError  string `json:"lastError,omitempty"`

	// ADR-0011 P0-4 additions (mirror gap 5).
	Cursor   int64  `json:"cursor,omitempty"`
	DLQDepth int64  `json:"dlqDepth"`
	Reason   string `json:"reason,omitempty"`
}

func (s *State) snapshot(ctx context.Context) body {
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
			out.Reason = fmt.Sprintf("no tick in %dms (unhealthy threshold %dms)",
				ageMs, s.pollIntervalMs*10)
		case ageMs > s.pollIntervalMs*3:
			out.Status = "degraded"
			out.Reason = fmt.Sprintf("tick delayed %dms (degraded threshold %dms)",
				ageMs, s.pollIntervalMs*3)
		case lastErr != "":
			out.Status = "degraded"
			out.Reason = "last tick errored: " + lastErr
		default:
			out.Status = "healthy"
		}
	} else if out.UptimeSec > 2*s.pollIntervalMs/1000 {
		out.Status = "unhealthy"
		out.Reason = "no successful tick since start"
	} else {
		out.Status = "healthy" // warming up
	}

	// ADR-0011 P0-4 additions — best-effort. DB timeouts don't degrade
	// the overall status because they'd flap under transient load; they're
	// diagnostic-only. Zero-valued responses fall through as "not
	// available" (omitempty on Cursor; DLQDepth defaults to 0 which is
	// the correct healthy value).
	if s.cursor != nil {
		ctxDB, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		if c, err := s.cursor(ctxDB); err == nil {
			out.Cursor = c
		}
	}
	if s.dlqDepth != nil {
		ctxDB, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		if d, err := s.dlqDepth(ctxDB); err == nil {
			out.DLQDepth = d
		}
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
		b := state.snapshot(r.Context())
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
