// Package db owns prod + staging pgx pools. Prod side is SELECT-only —
// every read goes through a BEGIN READ ONLY transaction as belt-and-
// suspenders on top of the IAM-scoped awslambda user.
package db

import (
	"context"
	"database/sql"
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

// UserLogIDsExist returns the subset of the given ids that exist in prod
// user_logs for the given enterprise. Used by the comparator's
// dlq_anomaly_total metric (ADR-0008 phase 2a.4) to detect staging DLQ
// rows whose source_log_id no longer exists upstream.
//
// Batched as a single ANY($1::bigint[]) query — staging DLQ is small
// (~100 rows typical), and prod's user_logs.id_user_logs is the PK so
// every probe is an O(log n) index hit. Returns a set (map[int64]struct{})
// so callers can iterate the original input doing membership checks
// without re-allocating.
func (p *Prod) UserLogIDsExist(ctx context.Context, ids []int64, enterpriseID int) (map[int64]struct{}, error) {
	if len(ids) == 0 {
		return map[int64]struct{}{}, nil
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
		`SELECT id_user_logs FROM user_logs
		  WHERE id_user_logs = ANY($1::bigint[])
		    AND id_enterprise = $2`,
		ids, enterpriseID,
	)
	if err != nil {
		return nil, fmt.Errorf("query user_logs exists: %w", err)
	}
	defer rows.Close()
	out := make(map[int64]struct{}, len(ids))
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out[id] = struct{}{}
	}
	return out, rows.Err()
}

// MaxUserLogID returns max(id_user_logs) on prod scoped to enterprise.
// Used by the comparator's user_logs_lag metric (ADR-0008 phase 2a.2) to
// answer "how far behind is the main poll loop's cursor?". Single
// round-trip; PK index makes it O(log n). BEGIN READ ONLY for defense in
// depth on top of the awslambda role.
//
// Returns 0 (and no error) when the enterprise has no user_logs rows —
// caller treats that as "lag = staging cursor's value" naturally.
func (p *Prod) MaxUserLogID(ctx context.Context, enterpriseID int) (int64, error) {
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

	var n int64
	err = tx.QueryRow(ctx,
		`SELECT COALESCE(max(id_user_logs), 0)
		   FROM user_logs
		  WHERE id_enterprise = $1`,
		enterpriseID,
	).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("max user_logs.id: %w", err)
	}
	return n, nil
}

// MaxRecentEventTs returns max(ts_event) on prod equipment_events scoped
// to enterprise + the last hour. The time window is essential — without
// it the query would scan a billion-row hypertable. With it, the planner
// hits the most-recent TimescaleDB chunk(s) only — sub-second on prod.
// Used by the comparator's events_lag_seconds metric (ADR-0008 phase 2a.2).
//
// Returns zero time when no events exist in the window (e.g. line stopped
// for >1h) — caller should treat that as "no signal" not "lag = forever";
// the comparator's measureEventsLag skips emission when prod side is zero.
func (p *Prod) MaxRecentEventTs(ctx context.Context, enterpriseID int) (time.Time, error) {
	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return time.Time{}, fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{
		AccessMode: pgx.ReadOnly,
		IsoLevel:   pgx.ReadCommitted,
	})
	if err != nil {
		return time.Time{}, fmt.Errorf("begin read only: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var ts sql.NullTime
	err = tx.QueryRow(ctx,
		`SELECT max(ts_event)
		   FROM equipment_events
		  WHERE id_enterprise = $1
		    AND ts_event > now() - interval '1 hour'`,
		enterpriseID,
	).Scan(&ts)
	if err != nil {
		return time.Time{}, fmt.Errorf("max recent ts_event: %w", err)
	}
	if !ts.Valid {
		return time.Time{}, nil
	}
	return ts.Time, nil
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

// ProdPOFinishInfo is the prod-authoritative view the reconciler's finisher
// (task #48) needs per orphan candidate: does prod STILL have this PO active
// (safety re-check against the diff snapshot), and — if not — when did it
// really stop, so we close the staging mirror at that ts instead of now().
//
// LastActivity = GREATEST(production_orders.ts_end, max(upper(runtime_timerange))),
// i.e. the later of the header's stop time and the last CLOSED runtime
// segment's upper bound ("segment last real compute moment"). HasActivity is
// false when both are NULL — the finisher then can't pick a real close ts and
// conservatively skips (never fabricates one).
type ProdPOFinishInfo struct {
	IDOrder      int64
	Status       int
	LastActivity time.Time
	HasActivity  bool
}

// FetchPOFinishInfo batches the finisher's prod cross-check: for each given
// id_order (scoped to enterprise, the diff's business key), return prod's
// CURRENT status + last-activity ts. This is the SAME prod source as
// FetchActivePOs, so the finisher is prod-driven end-to-end — the diff says
// "gone from status=2", this confirms it authoritatively on a fresh read and
// hands back the real stop moment. One round-trip via ANY($::bigint[]),
// wrapped in BEGIN READ ONLY like every prod read.
//
// An id_order absent from the result means prod has NO row for it under this
// enterprise — the caller treats that as "unverifiable" and skips (fail-safe:
// never close what prod can't confirm).
func (p *Prod) FetchPOFinishInfo(ctx context.Context, enterpriseID int, idOrders []int64) (map[int64]ProdPOFinishInfo, error) {
	if len(idOrders) == 0 {
		return map[int64]ProdPOFinishInfo{}, nil
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

	// GREATEST ignores NULL inputs (returns NULL only when all are NULL), so
	// ts_end-less POs still resolve to their last closed segment's upper
	// bound and vice-versa. max(upper(runtime_timerange)) is NULL while a
	// segment is still open (upper unbounded) — but such a PO is status=2 and
	// gets filtered by the status guard upstream anyway.
	rows, err := tx.Query(ctx,
		`SELECT po.id_order, po.status,
		        GREATEST(po.ts_end, max(upper(por.runtime_timerange))) AS last_activity
		   FROM production_orders po
		   LEFT JOIN production_orders_runtime por
		     ON por.id_production_order = po.id_production_order
		  WHERE po.id_enterprise = $1
		    AND po.id_order = ANY($2::bigint[])
		  GROUP BY po.id_order, po.status, po.ts_end`,
		enterpriseID, idOrders,
	)
	if err != nil {
		return nil, fmt.Errorf("query PO finish info: %w", err)
	}
	defer rows.Close()

	out := make(map[int64]ProdPOFinishInfo, len(idOrders))
	for rows.Next() {
		var r ProdPOFinishInfo
		var lastActivity sql.NullTime
		if err := rows.Scan(&r.IDOrder, &r.Status, &lastActivity); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		if lastActivity.Valid {
			r.LastActivity = lastActivity.Time
			r.HasActivity = true
		}
		out[r.IDOrder] = r
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

// ProdEventKey identifies one prod equipment_event by its natural key —
// (id_equipment, ts_event) is UNIQUE on equipment_events, the same key the
// shadow fan-out upserts on. Used to point-look-up prod's authoritative
// close state for a shadow candidate row (task #63 close-sweep).
type ProdEventKey struct {
	IDEquipment int
	TsEvent     time.Time
}

// ProdEventClose is prod's authoritative close state for an event: the
// fields the sweep re-points a divergent shadow row at.
type ProdEventClose struct {
	Status   *int
	TsEnd    *time.Time
	Duration *int
}

// packml_register.id_equipment is a NULLABLE FK: rows that route a topic by
// id_unit (or an unbound topic registration awaiting equipment assignment)
// carry a NULL id_equipment — they are not concrete equipment. The IS NOT NULL
// filter keeps those out of the enumeration entirely: DISTINCT would otherwise
// collapse every NULL to a single (ORDER BY … NULLS LAST) trailing row that
// scan-crashes the caller. This is the real fix; the NULL-tolerant scan below
// is belt-and-suspenders in the same spirit as the BEGIN READ ONLY wrapper.
const sqlEnterpriseEquipmentIDs = `SELECT DISTINCT id_equipment FROM packml_register
		  WHERE id_enterprise = $1 AND id_equipment IS NOT NULL
		  ORDER BY id_equipment`

// FetchEnterpriseEquipmentIDs returns the DISTINCT prod id_equipment values
// that have a packml_register row for the enterprise. This is the domain
// translate.Equipment operates on; the close-sweep enumerates it once per
// sweep and forward-translates each to invert prod↔staging (the shadow
// candidate rows carry STAGING ids, but prod must be looked up by PROD id).
// O(machines) — ~62 rows for CPACK — not O(event volume). READ ONLY.
func (p *Prod) FetchEnterpriseEquipmentIDs(ctx context.Context, enterpriseID int) ([]int, error) {
	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, fmt.Errorf("begin read only: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	rows, err := tx.Query(ctx, sqlEnterpriseEquipmentIDs, enterpriseID)
	if err != nil {
		return nil, fmt.Errorf("distinct equipment ids: %w", err)
	}
	defer rows.Close()
	ids, skippedNull, err := scanEnterpriseEquipmentIDs(rows)
	if err != nil {
		return nil, err
	}
	if skippedNull > 0 {
		// Should be 0 given the SQL filter; a non-zero count means a NULL
		// slipped past the WHERE clause — worth a breadcrumb, never fatal.
		p.logger.Debug("close-sweep: skipped NULL id_equipment rows from packml_register",
			slog.Int("skipped", skippedNull),
			slog.Int("enterprise", enterpriseID))
	}
	return ids, nil
}

// equipmentIDRows is the minimal slice of pgx.Rows that scanEnterpriseEquipmentIDs
// needs. Narrowing to an interface here is the seam that lets the NULL-skip
// logic be unit-tested without a live pool (this package has no pgxmock).
type equipmentIDRows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
}

// scanEnterpriseEquipmentIDs collects non-NULL id_equipment values and reports
// how many NULL rows it skipped. Scanning into sql.NullInt64 (not *int) is what
// keeps a single stray NULL id_equipment from returning an error and aborting
// the whole close-sweep — the exact crash this guards against.
func scanEnterpriseEquipmentIDs(rows equipmentIDRows) (ids []int, skippedNull int, err error) {
	for rows.Next() {
		var id sql.NullInt64
		if err = rows.Scan(&id); err != nil {
			return nil, skippedNull, err
		}
		if !id.Valid {
			skippedNull++
			continue
		}
		ids = append(ids, int(id.Int64))
	}
	return ids, skippedNull, rows.Err()
}

// FetchEventCloseInfo point-looks-up prod's authoritative (status, ts_end,
// duration) for each requested (id_equipment, ts_event) key, under ONE
// READ ONLY tx. Keys absent from prod are simply absent from the returned
// map — the sweep treats "no prod row" as "cannot close, do not fabricate"
// (that's how it avoids masking a real stranding). Cost is O(len(keys)) =
// O(divergent shadow rows), each an index probe on the unique
// (id_equipment, ts_event). The caller sets the ctx watchdog.
func (p *Prod) FetchEventCloseInfo(ctx context.Context, enterpriseID int, keys []ProdEventKey) (map[ProdEventKey]ProdEventClose, error) {
	out := make(map[ProdEventKey]ProdEventClose, len(keys))
	if len(keys) == 0 {
		return out, nil
	}
	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, fmt.Errorf("begin read only: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	for _, k := range keys {
		var c ProdEventClose
		err := tx.QueryRow(ctx,
			`SELECT status, ts_end, duration
			   FROM equipment_events
			  WHERE id_enterprise = $1 AND id_equipment = $2 AND ts_event = $3`,
			enterpriseID, k.IDEquipment, k.TsEvent,
		).Scan(&c.Status, &c.TsEnd, &c.Duration)
		if err == pgx.ErrNoRows {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("event close lookup (eq=%d): %w", k.IDEquipment, err)
		}
		out[k] = c
	}
	return out, nil
}
