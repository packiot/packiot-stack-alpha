// Package db owns the pgx pool used by handlers when they land.
// This session: declared but unused (no handlers write yet). Keeping the
// import in go.mod so the pool wiring is ready to go next session.
package db

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/secrets"
)

// New returns a connected pgx pool sized to comfortably outnumber
// prefetch (so handlers never block on pool acquire). Caller closes via
// pool.Close() at shutdown.
func New(ctx context.Context, creds *secrets.DBCreds, logger *slog.Logger) (*pgxpool.Pool, error) {
	pc, err := pgxpool.ParseConfig(creds.URL("oeecloud-worker"))
	if err != nil {
		return nil, fmt.Errorf("parse pg url: %w", err)
	}
	// Pool size: handleDelivery runs sequentially in a single goroutine
	// (the AMQP consume loop is one channel-reader), so at most ONE query
	// is in flight at any moment. 5 keeps a warm pool with headroom for
	// the resolver's occasional second query without competing with the
	// active write. Larger pools waste pgbouncer client slots.
	pc.MaxConns = 5
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
		slog.String("db", creds.Database),
		slog.Int("max_conns", int(pc.MaxConns)),
	)
	return p, nil
}
