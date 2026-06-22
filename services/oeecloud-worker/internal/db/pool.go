// Package db owns the pgx pool used by handlers when they land.
// This session: declared but unused (no handlers write yet). Keeping the
// import in go.mod so the pool wiring is ready to go next session.
package db

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/config"
)

// New returns a connected pgx pool sized to comfortably outnumber
// prefetch (so handlers never block on pool acquire). Caller closes via
// pool.Close() at shutdown.
func New(ctx context.Context, cfg *config.Config, logger *slog.Logger) (*pgxpool.Pool, error) {
	url := fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable&application_name=oeecloud-worker",
		cfg.PGUser, cfg.PGPassword, cfg.PGHost, cfg.PGPort, cfg.PGDatabase)
	pc, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("parse pg url: %w", err)
	}
	// Pool size: prefetch + some headroom for parallel handler work.
	// pgbouncer in front of postgres makes this almost free.
	pc.MaxConns = int32(cfg.Prefetch) + 5
	pc.MinConns = 1
	p, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	logger.Info("postgres pool ready",
		slog.String("host", cfg.PGHost),
		slog.Int("port", cfg.PGPort),
		slog.String("db", cfg.PGDatabase),
		slog.Int("max_conns", int(pc.MaxConns)),
	)
	return p, nil
}
