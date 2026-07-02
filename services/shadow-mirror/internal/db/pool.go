// Package db provides two pool constructors: one for the main packiot
// DB (source of user_logs + target for shadow_go_port writes) and one
// for the packiot_shadow DB (target for the refactored POC writes).
package db

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// DBCreds is the minimal shape shadow-mirror needs; secrets fetching
// itself is deferred to a follow-up PR to keep this skeleton compact.
// Populate via env vars (DB_HOST, DB_PORT, etc.) in the Phase 1 build.
type DBCreds struct {
	Host     string
	Port     int
	User     string
	Password string
}

// URLForDatabase builds a pgx DSN pointing at the given database name.
func (c *DBCreds) URLForDatabase(dbName, appName string) string {
	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(c.User, c.Password),
		Host:   fmt.Sprintf("%s:%d", c.Host, c.Port),
		Path:   "/" + dbName,
	}
	q := u.Query()
	q.Set("sslmode", "disable")
	q.Set("application_name", appName)
	u.RawQuery = q.Encode()
	return u.String()
}

// NewPool connects a pgx pool against the given database name.
func NewPool(ctx context.Context, creds *DBCreds, dbName, appName string, logger *slog.Logger) (*pgxpool.Pool, error) {
	pc, err := pgxpool.ParseConfig(creds.URLForDatabase(dbName, appName))
	if err != nil {
		return nil, fmt.Errorf("parse pg url: %w", err)
	}
	// Small pool — one poller goroutine, occasional writes. 5 is enough.
	pc.MaxConns = 5
	pc.MinConns = 1
	// Same pgbouncer-safe posture as oeecloud-worker: simple protocol,
	// no prepared statements. See oeecloud-worker/internal/db/pool.go
	// for the rationale.
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
		slog.String("db", dbName),
		slog.String("application_name", appName),
	)
	return p, nil
}
