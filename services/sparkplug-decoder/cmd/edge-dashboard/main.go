// Command edge-dashboard is the on-prem live-state board for the fat-edge
// deployment (ADR-0053 B-minimal). It runs on the client's factory box next to
// the local edge-transformer, opens the SAME SQLite current-state DB the
// transformer tees into (internal/localstate), and serves a plain HTTP board on
// :8080 so the shop floor keeps LIVE production visibility while the internet
// uplink is down.
//
// Why this exists: the operator SPA is cloud-hosted, so during an outage it can
// only show last-synced (stale) numbers behind its offline banner. The reader's
// local tee → local agent → local transformer keeps decoding on-box the whole
// time, writing current-state here — so this board shows numbers that are LIVE
// even with zero internet. The cloud remains the system of record; this is a
// read-only cache view, never a second source of truth.
//
// Deliberately dependency-light: net/http + the localstate reader, no template
// engine, no JS framework. The page fetches /api/state on a timer and re-renders
// a table; everything is inlined so it works with no external network at all
// (the whole point — there is no internet when this matters).
package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/localstate"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	dbPath := os.Getenv("LOCAL_STATE_DB")
	if dbPath == "" {
		logger.Error("LOCAL_STATE_DB is required (path to the current-state SQLite the transformer writes)")
		os.Exit(1)
	}
	// TENANT is the SparkPlug group_id (lowercased) the transformer records
	// under — the same tenant scoping the whole box serves. Required so the
	// board never mixes tenants (a box is single-tenant, but be explicit).
	tenant := os.Getenv("TENANT")
	if tenant == "" {
		logger.Error("TENANT is required (the lowercased group_id this box serves)")
		os.Exit(1)
	}
	port := os.Getenv("DASHBOARD_PORT")
	if port == "" {
		port = "8080"
	}
	// A reading older than this (by local write time) is shown as STALE — the
	// PLC stopped reporting or the local pipeline stalled. Tunable; the default
	// is generous relative to a typical multi-second scan.
	staleSeconds := int64(30)
	if v := os.Getenv("DASHBOARD_STALE_SECONDS"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			staleSeconds = n
		}
	}

	store, err := localstate.Open(dbPath)
	if err != nil {
		logger.Error("open current-state DB failed", slog.String("path", dbPath), slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer func() { _ = store.Close() }()

	srv := &server{store: store, tenant: tenant, staleSeconds: staleSeconds, logger: logger}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.handleHealth)
	mux.HandleFunc("/api/state", srv.handleState)
	mux.HandleFunc("/", srv.handleIndex)

	addr := ":" + port
	logger.Info("edge-dashboard listening",
		slog.String("addr", addr),
		slog.String("tenant", tenant),
		slog.String("db", dbPath),
		slog.String("adr", "ADR-0053 B-minimal"))

	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	if err := httpSrv.ListenAndServe(); err != nil {
		logger.Error("server exited", slog.String("err", err.Error()))
		os.Exit(1)
	}
}

type server struct {
	store        *localstate.Store
	tenant       string
	staleSeconds int64
	logger       *slog.Logger
}

// stateResponse is the JSON the board polls. nowMillis is echoed so the client
// computes age against the SERVER clock, not the browser's (a factory panel's
// clock is often wrong), keeping the STALE decision consistent.
type stateResponse struct {
	Tenant       string     `json:"tenant"`
	NowMillis    int64      `json:"now_millis"`
	StaleSeconds int64      `json:"stale_seconds"`
	Rows         []stateRow `json:"rows"`
}

type stateRow struct {
	Source    string   `json:"source"`
	Metric    string   `json:"metric"`
	Value     string   `json:"value"`
	Counter   *float64 `json:"counter,omitempty"`
	CurSpeed  *float64 `json:"curspeed,omitempty"`
	TsMillis  int64    `json:"ts_millis"`
	UpdatedAt int64    `json:"updated_at"`
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	// Liveness = can we read the store? A board that can't read its DB is
	// useless, so surface that as unhealthy for the compose healthcheck.
	if _, err := s.store.Snapshot(context.Background(), s.tenant); err != nil {
		http.Error(w, "db read failed", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *server) handleState(w http.ResponseWriter, r *http.Request) {
	rows, err := s.store.Snapshot(r.Context(), s.tenant)
	if err != nil {
		s.logger.Error("snapshot failed", slog.String("err", err.Error()))
		http.Error(w, "snapshot failed", http.StatusServiceUnavailable)
		return
	}
	resp := stateResponse{
		Tenant:       s.tenant,
		NowMillis:    time.Now().UTC().UnixMilli(),
		StaleSeconds: s.staleSeconds,
		Rows:         make([]stateRow, 0, len(rows)),
	}
	for _, row := range rows {
		resp.Rows = append(resp.Rows, stateRow{
			Source:    row.Source,
			Metric:    row.Metric,
			Value:     row.Value,
			Counter:   row.Counter,
			CurSpeed:  row.CurSpeed,
			TsMillis:  row.TsMillis,
			UpdatedAt: row.UpdatedAt,
		})
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		s.logger.Warn("encode state failed", slog.String("err", err.Error()))
	}
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(indexHTML))
}
