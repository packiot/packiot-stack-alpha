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

// LatestLogTimestamp returns the ts_event of the row at id=cursor.
// Used by the cursor_lag_seconds gauge — distance between now() and the
// last-replayed prod ts_event tells operators "is staging within N
// seconds of prod?".
//
// Returns zero time + nil error when cursor=0 (worker just started, no
// replay yet) or when the cursor row no longer exists — caller treats
// either as "skip the metric update this tick".
func (p *Prod) LatestLogTimestamp(ctx context.Context, cursor int64, enterpriseID int) (time.Time, error) {
	if cursor <= 0 {
		return time.Time{}, nil
	}
	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return time.Time{}, fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return time.Time{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	var ts time.Time
	err = tx.QueryRow(ctx,
		`SELECT ts_event FROM user_logs
		  WHERE id_user_logs = $1 AND id_enterprise = $2`,
		cursor, enterpriseID,
	).Scan(&ts)
	if err == pgx.ErrNoRows {
		return time.Time{}, nil
	}
	if err != nil {
		return time.Time{}, fmt.Errorf("ts_event lookup: %w", err)
	}
	return ts, nil
}

// ProdActivePO is the projection the reconciler needs: enough to do the
// /api/production-orders/create + /start round-trip against staging
// without a second prod hit.
type ProdActivePO struct {
	IDProductionOrder    int64
	IDOrder              int64
	IDEquipment          int
	IDSite               int
	IDArea               int
	ProductionProgrammed float64
}

// FetchActivePOs returns currently-active POs (status=2) for the given
// enterprise. Used by the reconciler to drive the diff against staging's
// active set. Always wrapped in BEGIN READ ONLY for defense-in-depth on
// top of the awslambda role.
//
// production_programmed is the SQL column for what the API surfaces as
// productionOrderQuantity (see CLAUDE.md: edge-api maps the camelCase
// DTO field → snake_case prod schema). Reading it directly avoids a
// second SELECT during reconciler.ensureOnePO.
func (p *Prod) FetchActivePOs(ctx context.Context, enterpriseID int) ([]ProdActivePO, error) {
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
	defer tx.Rollback(ctx) //nolint:errcheck

	rows, err := tx.Query(ctx,
		`SELECT id_production_order, id_order, id_equipment, id_site, id_area,
		        COALESCE(production_programmed, 0)
		   FROM production_orders
		  WHERE id_enterprise = $1 AND status = 2
		  ORDER BY id_production_order ASC`,
		enterpriseID,
	)
	if err != nil {
		return nil, fmt.Errorf("query active POs: %w", err)
	}
	defer rows.Close()

	var out []ProdActivePO
	for rows.Next() {
		var r ProdActivePO
		if err := rows.Scan(&r.IDProductionOrder, &r.IDOrder, &r.IDEquipment,
			&r.IDSite, &r.IDArea, &r.ProductionProgrammed); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
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
