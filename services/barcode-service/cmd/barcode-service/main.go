// barcode-service — Phase-0 durable box-scan ingest with server-side gapless
// label-sequence authority (North-star pharma pillar, Bronze tier).
//
// WHAT THIS IS (and is NOT, yet)
// ──────────────────────────────
// This is the Phase-0 SKELETON of the barcode ingest service: a compiling,
// tested, wired durable-ingest core. It owns exactly one load-bearing
// invariant — the gapless per-production-order label sequence is decided
// SERVER-SIDE inside one Postgres transaction under a per-PO advisory lock, so
// the count can never gap or double under concurrent scanners or client
// replays. Everything pharma-specific (EPCIS serialization, GS1 element-string
// parsing, Part-11 e-sig, genealogy/aggregation) is explicitly OUT of Phase 0;
// look for `// PHASE-2:` markers where those hooks slot in.
//
// It is modelled on services/refdata-api: one lean binary, config from env,
// pgx over pgbouncer (simple-protocol for transaction pooling), structured
// slog, an issuer-agnostic dual Firebase/Cognito JWT verifier that derives the
// tenant (id_enterprise) SERVER-SIDE and fails closed. The client never names a
// tenant — same single-injection-authority discipline as refdata's ADR-0027.
//
// Endpoints:
//
//	POST /v1/scans               — the durable gapless write (scans.go)
//	GET  /v1/scans/stream?id_production_order=  — SSE fan-out of accepts (sse.go)
//	GET  /healthz                — 503 when the DB (or, PHASE-2, the outbox) is
//	                               unhealthy — ADR-0011 rule 4 (fail the probe,
//	                               don't serve writes you can't durably persist)
//	GET  /metrics                — reserved (PHASE-2: Prometheus RED metrics)
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// config is the full runtime configuration, all from env. No secret has a
// default; a missing DB password simply yields an unhealthy pool (fail-closed
// at /healthz) rather than a silent misconnect.
type config struct {
	httpPort string

	dbHost     string
	dbPort     string
	dbUser     string
	dbPassword string
	dbName     string

	firebaseProject string // Firebase project id (aud + iss suffix). "" ⇒ Firebase path off.
	cognitoIssuer   string // https://cognito-idp.<region>.amazonaws.com/<poolId>. "" ⇒ Cognito path off.
	cognitoAudience string // Cognito app-client id (aud). "" ⇒ audience check skipped (Phase-0 lenient).

	logLevel string
}

func loadConfig() config {
	return config{
		httpPort:        getenv("HTTP_PORT", "8446"),
		dbHost:          getenv("DB_HOST", "pgbouncer"),
		dbPort:          getenv("DB_PORT", "5432"),
		dbUser:          getenv("DB_USER", "postgres"),
		dbPassword:      os.Getenv("DB_PASSWORD"),
		dbName:          getenv("DB_NAME", "packiot_analytics"),
		firebaseProject: getenv("FIREBASE_PROJECT_ID", defaultFirebaseProject),
		cognitoIssuer:   os.Getenv("COGNITO_ISSUER"),
		cognitoAudience: os.Getenv("COGNITO_CLIENT_ID"), // aud on Cognito ID tokens; same var refdata-api uses
		logLevel:        getenv("LOG_LEVEL", "info"),
	}
}

// served/failed are lightweight process counters surfaced by /healthz (same
// shape as refdata-api). PHASE-2: replace with Prometheus RED metrics.
var (
	served atomic.Uint64
	failed atomic.Uint64
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})).
		With(slog.String("service", "barcode-service"))

	cfg := loadConfig()

	// --healthcheck: the Docker HEALTHCHECK entrypoint. Hits our own /healthz
	// and maps 200 → exit 0, anything else → exit 1. Same pattern as every
	// other Go service in the stack.
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck(cfg.httpPort))
	}

	dsn := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s",
		cfg.dbHost, cfg.dbPort, cfg.dbUser, cfg.dbPassword, cfg.dbName)
	pc, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		logger.Error("parse dsn", slog.String("err", err.Error()))
		os.Exit(1)
	}
	pc.MaxConns = 5
	// pgbouncer transaction pooling breaks pgx's implicit prepared statements —
	// simple protocol is the stack-wide fix (see refdata-api/main.go). It is
	// ALSO what makes pg_advisory_xact_lock safe here: transaction pooling pins
	// one server backend for the life of a tx, so an xact-scoped advisory lock
	// is held for exactly our BEGIN…COMMIT and released on return.
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	pool, err := pgxpool.NewWithConfig(context.Background(), pc)
	if err != nil {
		logger.Error("pool", slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer pool.Close()

	// Dual JWT authenticator: issuer-agnostic. It peeks the token's `iss`,
	// routes to the Firebase or Cognito verifier, verifies fully, and derives
	// id_enterprise SERVER-SIDE (Firebase → users-table lookup; Cognito →
	// custom:id_enterprise claim). Fail-closed: any unknown issuer / bad token
	// / unresolved tenant → 401, no DB tenant leak (auth.go).
	auth := newAuthenticator(cfg, pool, logger)

	store := newPgScanStore(pool)
	broker := newSSEBroker()

	srv := &scanServer{store: store, broker: broker, logger: logger}

	mux := http.NewServeMux()
	// Write + stream sit behind the auth middleware (tenant from JWT only).
	mux.Handle("POST /v1/scans", auth.middleware(http.HandlerFunc(srv.handlePostScan)))
	mux.Handle("GET /v1/scans/stream", auth.middleware(http.HandlerFunc(srv.handleStream)))
	// Ops probes — NO auth (they expose no tenant data). /healthz fails closed.
	mux.HandleFunc("GET /healthz", healthzHandler(pool))
	mux.HandleFunc("GET /metrics", metricsHandler) // PHASE-2: real Prometheus registry

	httpSrv := &http.Server{
		Addr:              ":" + cfg.httpPort,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Graceful shutdown: on SIGINT/SIGTERM, stop accepting, drain in-flight
	// with a bounded deadline, then close the SSE broker so subscriber
	// goroutines unblock.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		logger.Info("barcode-service listening",
			slog.String("port", cfg.httpPort),
			slog.String("db_name", cfg.dbName),
			slog.Bool("firebase", cfg.firebaseProject != ""),
			slog.Bool("cognito", cfg.cognitoIssuer != ""))
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("http", slog.String("err", err.Error()))
			stop() // trip the shutdown path so the process exits non-hanging
		}
	}()

	<-ctx.Done()
	logger.Info("shutdown signal received; draining")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		logger.Warn("graceful shutdown timed out", slog.String("err", err.Error()))
	}
	broker.Close()
	logger.Info("stopped")
}

// healthzHandler returns 503 when the DB is unreachable — ADR-0011 rule 4: a
// write service that cannot durably persist must FAIL its readiness probe so
// the orchestrator stops routing writes to it. PHASE-2: also gate on the
// transactional-outbox drain health once the outbox lands.
func healthzHandler(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if err := pool.Ping(ctx); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprintf(w, `{"healthy":false,"reason":"db_unreachable"}`)
			return
		}
		// PHASE-2: outboxHealthy(ctx) — 503 if the outbox backlog is stalled.
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"healthy":true,"served":%d,"failed":%d}`, served.Load(), failed.Load())
	}
}

// metricsHandler is a Phase-0 placeholder. PHASE-2: mount promhttp.Handler over
// a real registry with the RED (rate/errors/duration) counters the rest of the
// stack scrapes.
func metricsHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# PHASE-2: prometheus metrics\nbarcode_scans_served_total %d\nbarcode_scans_failed_total %d\n",
		served.Load(), failed.Load())
}

func runHealthcheck(port string) int {
	c := http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil || resp.StatusCode != http.StatusOK {
		return 1
	}
	resp.Body.Close()
	return 0
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
