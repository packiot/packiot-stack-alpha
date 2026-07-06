package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/shadow-mirror/internal/replay"
)

// OrderCreatedStartedPayload is the JSON emitted by staging edge-api
// for user_logs.category = 'order-created-started'. Combined
// create+start action — inserts a production_orders row with status=2
// (running) in one shot.
type OrderCreatedStartedPayload struct {
	IDOrder                 int64  `json:"idOrder"`
	IDEnterprise            int    `json:"idEnterprise"`
	IDSite                  int    `json:"idSite"`
	IDArea                  int    `json:"idArea"`
	IDEquipment             int    `json:"idEquipment"`
	Timestamp               string `json:"timestamp"` // ISO-8601, becomes ts_start
	NmProductionOrder       string `json:"nmProductionOrder"`
	ProductionOrderQuantity int64  `json:"productionOrderQuantity"`
	TxtProductionOrderNotes string `json:"txtProductionOrderNotes"`
}

// OrderCreatedStarted inserts a production_orders row (status=2 running)
// in both shadow paths. Idempotent via ON CONFLICT (id_enterprise,
// id_order) DO NOTHING — replaying the same log entry is a no-op. The
// conflict target is qualified deliberately (bug 247): an unqualified
// ON CONFLICT also swallowed the one-running-PO-per-equipment partial
// unique index, silently dropping every insert behind a stuck running
// PO. Any other constraint violation must surface as a dispatch failure.
func OrderCreatedStarted(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, shadowPool *pgxpool.Pool, u *replay.UserLog) error {
		var p OrderCreatedStartedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			logger.Warn("order-created-started: unmarshal failed", slog.Int64("id_user_log", u.ID), slog.String("err", err.Error()))
			return replay.ErrSkip
		}
		if p.IDOrder == 0 || p.IDEquipment == 0 {
			return replay.ErrSkip
		}
		tsStart, err := time.Parse(time.RFC3339Nano, p.Timestamp)
		if err != nil {
			return replay.ErrSkip
		}
		if err := openRuntimeWindow(ctx, mainPool, "shadow_go_port", p.IDEnterprise, p.IDOrder, p.IDEquipment, tsStart, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port supersede: %w", err)
		}
		if err := insertProdOrder(ctx, mainPool, "shadow_go_port", &p, tsStart, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port write: %w", err)
		}
		if err := openRuntimeWindow(ctx, mainPool, "shadow_go_port", p.IDEnterprise, p.IDOrder, p.IDEquipment, tsStart, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port window: %w", err)
		}
		if shadowPool != nil {
			if err := openRuntimeWindow(ctx, shadowPool, "public", p.IDEnterprise, p.IDOrder, p.IDEquipment, tsStart, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_shadow supersede: %w", err)
			}
			if err := insertProdOrder(ctx, shadowPool, "public", &p, tsStart, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_shadow write: %w", err)
			}
			if err := openRuntimeWindow(ctx, shadowPool, "public", p.IDEnterprise, p.IDOrder, p.IDEquipment, tsStart, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_shadow window: %w", err)
			}
		}
		return nil
	}
}

const sqlInsertPORunning = `INSERT INTO %s.production_orders (
		id_enterprise, id_site, id_area, id_equipment, id_order,
		nm_production_order, production_programmed, production_ordered,
		txt_production_order_notes, status, ts_start
	) VALUES ($1,$2,$3,$4,$5,$6,$7,$7,$8,2,$9)
	ON CONFLICT (id_enterprise, id_order) DO NOTHING`

func insertProdOrder(ctx context.Context, pool *pgxpool.Pool, schema string, p *OrderCreatedStartedPayload, tsStart time.Time, userLogID int64, logger *slog.Logger) error {
	// production_programmed + production_ordered both NOT NULL on prod;
	// use ProductionOrderQuantity for both (payload doesn't distinguish).
	sql := fmt.Sprintf(sqlInsertPORunning, schema)
	_, err := pool.Exec(ctx, sql,
		p.IDEnterprise, p.IDSite, p.IDArea, p.IDEquipment, p.IDOrder,
		p.NmProductionOrder, p.ProductionOrderQuantity, p.TxtProductionOrderNotes,
		tsStart,
	)
	return failOpenIfMissing(err, "production_orders", schema, userLogID, logger)
}

// OrderStoppedPayload — user_logs.category='order-stopped'. Moves an
// existing production_orders row to status=3 (finished) or 4 (paused)
// based on stopType.
type OrderStoppedPayload struct {
	StopType                string `json:"stopType"` // "pause" | "finish"
	Timestamp               string `json:"timestamp"`
	IDEquipment             int    `json:"idEquipment"`
	IDEnterprise            int    `json:"idEnterprise"`
	IDProductionOrder       int64  `json:"idProductionOrder"`
	ProductionOrderQuantity int64  `json:"productionOrderQuantity"`
}

// OrderStopped updates status + ts_end on the identified production_orders row.
// Idempotent — same UPDATE applied twice yields the same terminal state.
// Targets the natural key (id_enterprise, id_order) resolved from Flow 1
// — the payload's id_production_order lives in Flow 1's id space only
// (bug 248).
func OrderStopped(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, shadowPool *pgxpool.Pool, u *replay.UserLog) error {
		var p OrderStoppedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return replay.ErrSkip
		}
		if p.IDProductionOrder == 0 {
			return replay.ErrSkip
		}
		tsEnd, err := time.Parse(time.RFC3339Nano, p.Timestamp)
		if err != nil {
			return replay.ErrSkip
		}
		status := 3 // finish
		if p.StopType == "pause" {
			status = 4
		}
		k, found, err := resolvePOKey(ctx, mainPool, p.IDProductionOrder)
		if err != nil {
			return fmt.Errorf("resolve PO natural key: %w", err)
		}
		if !found {
			logger.Warn("order-stopped: Flow 1 PO not found",
				slog.Int64("id_user_log", u.ID),
				slog.Int64("id_production_order", p.IDProductionOrder))
			return replay.ErrSkip
		}
		if err := closeRuntimeWindow(ctx, mainPool, "shadow_go_port", k.IDEnterprise, k.IDOrder, tsEnd, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port window close: %w", err)
		}
		if err := updateProdOrderStop(ctx, mainPool, "shadow_go_port", k, &p, tsEnd, status, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port write: %w", err)
		}
		if shadowPool != nil {
			if err := closeRuntimeWindow(ctx, shadowPool, "public", k.IDEnterprise, k.IDOrder, tsEnd, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_shadow window close: %w", err)
			}
			if err := updateProdOrderStop(ctx, shadowPool, "public", k, &p, tsEnd, status, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_shadow write: %w", err)
			}
		}
		return nil
	}
}

const sqlUpdatePOStop = `UPDATE %s.production_orders
	   SET status = $1, ts_end = $2, production_real = $3, last_update = now()
	 WHERE id_enterprise = $4 AND id_order = $5`

func updateProdOrderStop(ctx context.Context, pool *pgxpool.Pool, schema string, k poKey, p *OrderStoppedPayload, tsEnd time.Time, status int, userLogID int64, logger *slog.Logger) error {
	sql := fmt.Sprintf(sqlUpdatePOStop, schema)
	return execExpectingRows(ctx, pool, schema, "production_orders", userLogID, logger,
		sql, status, tsEnd, p.ProductionOrderQuantity, k.IDEnterprise, k.IDOrder)
}

// failOpenIfMissing is the shared 42P01 handler used across handlers.
// Missing target table = log warn, cursor advances. Anything else = real error.
func failOpenIfMissing(err error, table, schema string, userLogID int64, logger *slog.Logger) error {
	if err == nil {
		return nil
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "42P01" {
		logger.Warn("target table missing — fail-open",
			slog.Int64("id_user_log", userLogID),
			slog.String("schema", schema),
			slog.String("table", table))
		return nil
	}
	return err
}

// ── RUNTIME WINDOWS (the missing leg) ─────────────────────────────
// Prod's PO machinery opens a production_orders_runtime window on
// start and closes it on stop/pause; the shadow flows' entire runtime
// engine (compute/recalc/day2/UNS jobs) reads those windows. The
// replay handlers created POs but never windows — the shadow runtime
// chain starved in live operation (only inject tests ever had rows).
//
// Prod-truth conflict rule: the user_log stream is authoritative —
// a start at T means anything still running on that equipment had
// ended by T. supersedeRunning closes it (status=3 + window upper=T)
// BEFORE the new start, which also dissolves the accumulated 23505s
// against the one-running-PO-per-equipment partial unique index.

const sqlSupersedeRunningPO = `UPDATE %s.production_orders
	   SET status = 3, last_update = now()
	 WHERE id_equipment = $1 AND status = 2
	   AND NOT (id_enterprise = $2 AND id_order = $3)`

const sqlCloseWindowsForEquipment = `UPDATE %s.production_orders_runtime r
	   SET runtime_timerange = tstzrange(lower(runtime_timerange), $2),
	       recalc_needed = true
	 WHERE r.id_equipment = $1 AND upper(runtime_timerange) IS NULL
	   AND lower(runtime_timerange) < $2`

const sqlOpenWindow = `INSERT INTO %s.production_orders_runtime
	       (id_production_order, id_equipment, runtime_timerange, recalc_needed)
	SELECT po.id_production_order, po.id_equipment, tstzrange($3, NULL), true
	  FROM %s.production_orders po
	 WHERE po.id_enterprise = $1 AND po.id_order = $2
	   AND NOT EXISTS (SELECT 1 FROM %s.production_orders_runtime x
	        WHERE x.id_production_order = po.id_production_order
	          AND upper(x.runtime_timerange) IS NULL)`

const sqlCloseWindowsForPO = `UPDATE %s.production_orders_runtime r
	   SET runtime_timerange = tstzrange(lower(runtime_timerange), $3),
	       recalc_needed = true
	  FROM %s.production_orders po
	 WHERE po.id_enterprise = $1 AND po.id_order = $2
	   AND r.id_production_order = po.id_production_order
	   AND upper(r.runtime_timerange) IS NULL
	   AND lower(r.runtime_timerange) < $3`

// openRuntimeWindow supersedes any conflicting running PO on the
// equipment, then opens [ts, ∞) for the (ent, order) PO. Idempotent
// (NOT EXISTS guard on an already-open window).
func openRuntimeWindow(ctx context.Context, pool *pgxpool.Pool, schema string, idEnterprise int, idOrder int64, idEquipment int, ts time.Time, userLogID int64, logger *slog.Logger) error {
	if _, err := pool.Exec(ctx, fmt.Sprintf(sqlCloseWindowsForEquipment, schema), idEquipment, ts); err != nil {
		return failOpenIfMissing(err, "production_orders_runtime", schema, userLogID, logger)
	}
	if _, err := pool.Exec(ctx, fmt.Sprintf(sqlSupersedeRunningPO, schema), idEquipment, idEnterprise, idOrder); err != nil {
		return failOpenIfMissing(err, "production_orders", schema, userLogID, logger)
	}
	_, err := pool.Exec(ctx, fmt.Sprintf(sqlOpenWindow, schema, schema, schema), idEnterprise, idOrder, ts)
	return failOpenIfMissing(err, "production_orders_runtime", schema, userLogID, logger)
}

func closeRuntimeWindow(ctx context.Context, pool *pgxpool.Pool, schema string, idEnterprise int, idOrder int64, ts time.Time, userLogID int64, logger *slog.Logger) error {
	_, err := pool.Exec(ctx, fmt.Sprintf(sqlCloseWindowsForPO, schema, schema), idEnterprise, idOrder, ts)
	return failOpenIfMissing(err, "production_orders_runtime", schema, userLogID, logger)
}
