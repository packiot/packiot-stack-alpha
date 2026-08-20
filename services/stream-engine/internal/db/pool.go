// Package db owns the pgx pool used by handlers when they land.
// This session: declared but unused (no handlers write yet). Keeping the
// import in go.mod so the pool wiring is ready to go next session.
package db

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/secrets"
)

// New returns a connected pgx pool sized to comfortably outnumber
// prefetch (so handlers never block on pool acquire). Caller closes via
// pool.Close() at shutdown.
func New(ctx context.Context, creds *secrets.DBCreds, maxConns int, logger *slog.Logger) (*pgxpool.Pool, error) {
	// Main pool goes through pgbouncer (transaction pooling): a per-connection
	// SET would leak across pooled clients, so we do NOT override
	// statement_timeout here.
	return newWithDBName(ctx, creds, creds.Database, "oeecloud-worker", maxConns, false, logger)
}

// NewForDatabase returns a pool against the same host/user/password as
// creds but overriding the target database name. Used for the ADR-0012
// shadow DB (packiot_shadow) sitting alongside the main packiot DB.
// appName is set on the connection so pg_stat_activity shows which
// consumer opened it (helpful during the refactor rollout).
func NewForDatabase(ctx context.Context, creds *secrets.DBCreds, dbName, appName string, maxConns int, logger *slog.Logger) (*pgxpool.Pool, error) {
	// Shadow pool connects DIRECT (no pgbouncer), so a per-connection SET is
	// safe and persists — clear statement_timeout here (see newWithDBName).
	return newWithDBName(ctx, creds, dbName, appName, maxConns, true, logger)
}

func newWithDBName(ctx context.Context, creds *secrets.DBCreds, dbName, appName string, maxConns int, directConn bool, logger *slog.Logger) (*pgxpool.Pool, error) {
	pc, err := pgxpool.ParseConfig(creds.URLForDatabase(appName, dbName))
	if err != nil {
		return nil, fmt.Errorf("parse pg url: %w", err)
	}
	// Pool size: the AMQP consumer runs one write at a time, BUT the periodic
	// rollup/refresh jobs (LoopRefresh, bake, grains, uns) share this pool and
	// run concurrently. A heavy shadow rollup can hold a connection 40s+ (plus
	// an advisory-lock waiter), so an under-sized pool starves the ingest write
	// → it times out and fails-open → F3 trickles. Sized via config now; the
	// shadow pool (direct to the DB EC2) gets more headroom than the main pool
	// (multiplexed through pgbouncer). Floor at 2 so we never wedge.
	if maxConns < 2 {
		maxConns = 2
	}
	pc.MaxConns = int32(maxConns)
	pc.MinConns = 1

	// pgbouncer in the stack runs in TRANSACTION pooling mode (each tx
	// gets a different backend connection). pgx's default
	// QueryExecModeCacheStatement uses server-side prepared statements
	// cached by name — which breaks with transaction pooling because
	// the next tx may land on a backend that's never seen the stmt cache
	// entry, producing SQLSTATE 42P05 ("prepared statement already
	// exists"). Using simple protocol bypasses prepared statements
	// entirely; queries are sent as text with parameters interpolated
	// client-side. Slightly more wire bytes per query, no measurable
	// throughput cost at our scale, AND it works correctly under
	// pgbouncer transaction pooling.
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	// otelpgx emits a span per query, so the DB writes for a delivery hang off
	// the consumer span as children (the traceparent extracted from the AMQP
	// message). No-op unless tracing is enabled.
	pc.ConnConfig.Tracer = otelpgx.NewTracer()

	// Shadow (direct) pool: clear the server's default statement_timeout on every
	// connection so the rollup/refresh/uns jobs run under their Go tick timeout
	// (5 min) instead of being killed mid-backfill by packiot_shadow's 120s
	// global default — the same reason provision.go SETs it to 0 (a slow but
	// legitimate rollup/backfill must be allowed to finish; the tick context is
	// the real guard). A killed query never clears recalc_needed, so it retries
	// forever and a recompute backlog (e.g. after the 2026-07-10 poison purge)
	// drains at a crawl. Safe here — direct connection, not shared via pgbouncer,
	// so the SET can't leak to other clients; every job/write path has a context
	// deadline as the backstop.
	if directConn {
		prev := pc.AfterConnect
		pc.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
			if prev != nil {
				if err := prev(ctx, conn); err != nil {
					return err
				}
			}
			_, err := conn.Exec(ctx, "SET statement_timeout = 0")
			return err
		}
	}

	p, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	logger.Info("postgres pool ready",
		slog.String("host", creds.Host),
		slog.Int("port", creds.Port),
		slog.String("db", dbName),
		slog.String("application_name", appName),
		slog.Int("max_conns", int(pc.MaxConns)),
	)
	return p, nil
}
