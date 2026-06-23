// Package db owns prod + staging pgx pools. Prod side is SELECT-only —
// every read goes through a BEGIN READ ONLY transaction as belt-and-
// suspenders on top of the IAM-scoped awslambda user.
package db

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/secrets"
)

type Prod struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

// NewProd connects to prod via the awslambda SELECT-only role. Pool sized
// small (single-goroutine consumer) + direct postgres connection (no
// pgbouncer in front, so prepared statements are safe — keep default
// QueryExecMode).
func NewProd(ctx context.Context, creds *secrets.DBCreds, logger *slog.Logger) (*Prod, error) {
	pc, err := pgxpool.ParseConfig(creds.URL("mirror-worker-go"))
	if err != nil {
		return nil, fmt.Errorf("parse prod url: %w", err)
	}
	pc.MaxConns = 3
	pc.MinConns = 1
	pc.MaxConnIdleTime = 5 * time.Minute

	p, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("create prod pool: %w", err)
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		return nil, fmt.Errorf("prod ping: %w", err)
	}
	logger.Info("prod pool ready", slog.String("url", creds.Redacted("mirror-worker-go")))
	return &Prod{pool: p, logger: logger}, nil
}

func (p *Prod) Close() { p.pool.Close() }

// ProdUserLog mirrors the TS shape — fields we read off user_logs.
type ProdUserLog struct {
	IDUserLogs   int64
	TsEvent      time.Time
	Category     string
	Subcategory  *string
	IDEnterprise int
	IDSite       *int
	IDArea       *int
	IDEquipment  *int
	NmUser       *string
	Payload      []byte // raw jsonb — handler parses by category
}

// FetchNewLogs pulls user_logs rows newer than cursor, for the given
// enterprise. Wrapped in BEGIN READ ONLY — defense in depth on top of
// the awslambda role being SELECT-only.
func (p *Prod) FetchNewLogs(ctx context.Context, cursor int64, enterpriseID, limit int) ([]ProdUserLog, error) {
	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()

	tx, err := conn.BeginTx(ctx, pgx.TxOptions{
		AccessMode: pgx.ReadOnly,
		IsoLevel:   pgx.ReadCommitted,
	})
	if err != nil {
		return nil, fmt.Errorf("begin read only: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // ReadOnly tx, nothing to commit

	rows, err := tx.Query(ctx,
		`SELECT id_user_logs, ts_event, category, subcategory,
		        id_enterprise, id_site, id_area, id_equipment,
		        nm_user, payload::text
		   FROM user_logs
		  WHERE id_user_logs > $1
		    AND id_enterprise = $2
		  ORDER BY id_user_logs ASC
		  LIMIT $3`,
		cursor, enterpriseID, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("query user_logs: %w", err)
	}
	defer rows.Close()

	var out []ProdUserLog
	for rows.Next() {
		var r ProdUserLog
		var payloadStr string
		if err := rows.Scan(&r.IDUserLogs, &r.TsEvent, &r.Category, &r.Subcategory,
			&r.IDEnterprise, &r.IDSite, &r.IDArea, &r.IDEquipment, &r.NmUser, &payloadStr); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		r.Payload = []byte(payloadStr)
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("rows.Err: %w", err)
	}
	return out, nil
}

// SelectOne runs a single SELECT under a READ ONLY tx + scans into dst.
// dst is treated as a struct whose fields receive the columns in order
// (caller passes &field args via dest slice).
func (p *Prod) SelectOne(ctx context.Context, sql string, args []any, dest ...any) (bool, error) {
	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return false, fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	err = tx.QueryRow(ctx, sql, args...).Scan(dest...)
	if err == pgx.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}
