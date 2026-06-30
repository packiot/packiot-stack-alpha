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

// CountActivePOs returns the number of prod production_orders currently
// in status=2 (running) for the given enterprise. Used by the comparator
// for the active_pos_diff fidelity metric (ADR-0008 phase 2a). Lighter
// than FetchActivePOs — no rows pulled, just COUNT(*). Same BEGIN READ
// ONLY defense-in-depth on top of the awslambda role.
func (p *Prod) CountActivePOs(ctx context.Context, enterpriseID int) (int, error) {
	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return 0, fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{
		AccessMode: pgx.ReadOnly,
		IsoLevel:   pgx.ReadCommitted,
	})
	if err != nil {
		return 0, fmt.Errorf("begin read only: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var n int
	err = tx.QueryRow(ctx,
		`SELECT count(*) FROM production_orders
		  WHERE id_enterprise = $1 AND status = 2`,
		enterpriseID,
	).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("count active prod POs: %w", err)
	}
	return n, nil
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

// ProdRuntimeValues is the slim projection the value-sync needs: the
// canonical "current production" counters from production_orders_runtime
// (the per-minute cron-recomputed table, which is what operator UI and
// dashboards read). One row per active PO.
//
// We deliberately do NOT pull production_orders.* counters — those are
// less consistently maintained and the cron source of truth lives in
// production_orders_runtime.
type ProdRuntimeValues struct {
	IDProductionOrder int64
	NetProduction     *float64
	GrossProduction   *float64
}

// FetchRuntimeValues batches the value-sync prod read. ANY-array binding
// (pg-native, the awslambda role allows it) lets one SELECT cover all
// mapped active POs in a single round-trip.
func (p *Prod) FetchRuntimeValues(ctx context.Context, prodPOIDs []int64) (map[int64]ProdRuntimeValues, error) {
	if len(prodPOIDs) == 0 {
		return map[int64]ProdRuntimeValues{}, nil
	}
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
		`SELECT id_production_order, net_production, gross_production
		   FROM production_orders_runtime
		  WHERE id_production_order = ANY($1::bigint[])`,
		prodPOIDs,
	)
	if err != nil {
		return nil, fmt.Errorf("query prod runtime values: %w", err)
	}
	defer rows.Close()

	out := make(map[int64]ProdRuntimeValues, len(prodPOIDs))
	for rows.Next() {
		var r ProdRuntimeValues
		if err := rows.Scan(&r.IDProductionOrder, &r.NetProduction, &r.GrossProduction); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out[r.IDProductionOrder] = r
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("rows.Err: %w", err)
	}
	return out, nil
}

// ProdEquipmentEvent is the wire shape between prod and the events
// reconciler. Includes every non-defaulted, replay-meaningful column on
// the equipment_events table. We pull cd_machine / cd_category / etc.
// because prod's operator UI writes those back into the row after
// justify/edit and they're the whole reason for mirroring — if we only
// copied (ts_event, ts_end, status, id_equipment) the matcher would
// succeed but staging would still display empty downtime metadata.
//
// Nullable columns use *T so we can distinguish "not set" from "set to
// zero value" when re-inserting on staging.
type ProdEquipmentEvent struct {
	IDEquipmentEvent    int64
	IDEquipment         int
	TsEvent             time.Time
	TsEnd               *time.Time
	Status              *int
	TxtDowntimeNotes    *string
	Idle                *string
	Fault               *int
	CdMachine           *string
	CdCategory          *string
	CdSubcategory       *string
	ChangeOver          *bool
	PlannedDowntime     *bool
	Duration            *int
	DescCategory        *string
	DescSubcategory     *string
	CdCategoryClient    *int
	CdSubcategoryClient *int
	IgnoreCost          *bool
}

// FetchNewEquipmentEvents pulls prod equipment_events for the given
// enterprise whose id_equipment_event > cursor, in ascending order.
// Bounded by limit so a backlog can't OOM us — the reconciler advances
// per pass and catches up incrementally.
//
// Wrapped in BEGIN READ ONLY as defense-in-depth on the awslambda role.
func (p *Prod) FetchNewEquipmentEvents(ctx context.Context, cursor int64, enterpriseID, limit int) ([]ProdEquipmentEvent, error) {
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
		`SELECT id_equipment_event, id_equipment, ts_event, ts_end, status,
		        txt_downtime_notes, idle, fault, cd_machine, cd_category,
		        cd_subcategory, change_over, planned_downtime, duration,
		        desc_category, desc_subcategory, cd_category_client,
		        cd_subcategory_client, ignore_cost
		   FROM equipment_events
		  WHERE id_enterprise = $1
		    AND id_equipment_event > $2
		  ORDER BY id_equipment_event ASC
		  LIMIT $3`,
		enterpriseID, cursor, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("query equipment_events: %w", err)
	}
	defer rows.Close()

	var out []ProdEquipmentEvent
	for rows.Next() {
		var r ProdEquipmentEvent
		if err := rows.Scan(&r.IDEquipmentEvent, &r.IDEquipment, &r.TsEvent, &r.TsEnd, &r.Status,
			&r.TxtDowntimeNotes, &r.Idle, &r.Fault, &r.CdMachine, &r.CdCategory,
			&r.CdSubcategory, &r.ChangeOver, &r.PlannedDowntime, &r.Duration,
			&r.DescCategory, &r.DescSubcategory, &r.CdCategoryClient,
			&r.CdSubcategoryClient, &r.IgnoreCost); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("rows.Err: %w", err)
	}
	return out, nil
}

// FetchUserLogByID reads ONE prod user_logs row by id, for DLQ retry.
// Returns (zero, false, nil) when the row no longer exists — DLQ retry
// then treats it as "permanent miss" and gives up. Wrapped in BEGIN
// READ ONLY for the same defense-in-depth reason as FetchNewLogs.
func (p *Prod) FetchUserLogByID(ctx context.Context, idUserLogs int64, enterpriseID int) (ProdUserLog, bool, error) {
	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return ProdUserLog{}, false, fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return ProdUserLog{}, false, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var r ProdUserLog
	var payloadStr string
	err = tx.QueryRow(ctx,
		`SELECT id_user_logs, ts_event, category, subcategory,
		        id_enterprise, id_site, id_area, id_equipment,
		        nm_user, payload::text
		   FROM user_logs
		  WHERE id_user_logs = $1 AND id_enterprise = $2`,
		idUserLogs, enterpriseID,
	).Scan(&r.IDUserLogs, &r.TsEvent, &r.Category, &r.Subcategory,
		&r.IDEnterprise, &r.IDSite, &r.IDArea, &r.IDEquipment, &r.NmUser, &payloadStr)
	if err == pgx.ErrNoRows {
		return ProdUserLog{}, false, nil
	}
	if err != nil {
		return ProdUserLog{}, false, fmt.Errorf("scan: %w", err)
	}
	r.Payload = []byte(payloadStr)
	return r, true, nil
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
