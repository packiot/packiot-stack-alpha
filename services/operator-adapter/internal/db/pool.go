// Package db owns the small read-only pgx pool the topic resolver uses to
// translate a packml_topic → staging numeric ids. The adapter connects to F1
// `packiot` (where edge-api writes) so the ids it resolves are the same ones
// edge-api would accept.
package db

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/operator-adapter/internal/secrets"
)

// New returns a connected pgx pool sized for the adapter's occasional resolver
// lookups. The HTTP handlers run concurrently, but each request issues at most
// one resolver query and results are memoised, so a tiny pool is plenty.
// Caller closes via pool.Close() at shutdown.
func New(ctx context.Context, creds *secrets.DBCreds, appName string, logger *slog.Logger) (*pgxpool.Pool, error) {
	pc, err := pgxpool.ParseConfig(creds.URL(appName))
	if err != nil {
		return nil, fmt.Errorf("parse pg url: %w", err)
	}
	// Small pool: topic resolution is light + cached. 3 conns covers a burst
	// of concurrent operator actions without hogging pgbouncer client slots.
	pc.MaxConns = 3
	pc.MinConns = 1

	// pgbouncer in the stack runs TRANSACTION pooling; pgx's default prepared-
	// statement cache breaks there (SQLSTATE 42P05). Simple protocol sends
	// queries as text with client-side param interpolation — correct under
	// transaction pooling, negligible cost at our query volume.
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol

	// otelpgx emits a span per query, so a resolver lookup shows up as a DB
	// child span under the operator-action trace. No-op when tracing is off.
	pc.ConnConfig.Tracer = otelpgx.NewTracer()

	p, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	logger.Info("postgres pool ready (read-only resolver)",
		slog.String("host", creds.Host),
		slog.Int("port", creds.Port),
		slog.String("db", creds.Database),
		slog.String("application_name", appName),
		slog.Int("max_conns", int(pc.MaxConns)),
	)
	return p, nil
}
