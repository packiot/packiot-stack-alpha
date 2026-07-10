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
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/secrets"
)

// New returns a connected pgx pool sized to comfortably outnumber
// prefetch (so handlers never block on pool acquire). Caller closes via
// pool.Close() at shutdown.
func New(ctx context.Context, creds *secrets.DBCreds, maxConns int, logger *slog.Logger) (*pgxpool.Pool, error) {
	return newWithDBName(ctx, creds, creds.Database, "oeecloud-worker", maxConns, logger)
}

// NewForDatabase returns a pool against the same host/user/password as
// creds but overriding the target database name. Used for the ADR-0012
// shadow DB (packiot_shadow) sitting alongside the main packiot DB.
// appName is set on the connection so pg_stat_activity shows which
// consumer opened it (helpful during the refactor rollout).
func NewForDatabase(ctx context.Context, creds *secrets.DBCreds, dbName, appName string, maxConns int, logger *slog.Logger) (*pgxpool.Pool, error) {
	return newWithDBName(ctx, creds, dbName, appName, maxConns, logger)
}

func newWithDBName(ctx context.Context, creds *secrets.DBCreds, dbName, appName string, maxConns int, logger *slog.Logger) (*pgxpool.Pool, error) {
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
