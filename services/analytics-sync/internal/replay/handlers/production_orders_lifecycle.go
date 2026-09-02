package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/replay"
)

// OrderCreatedPayload — user_logs.category='order-created'. Similar to
// order-created-started but the PO is available (status=1) not running.
// Used by mirror-worker-go's EnsureActivePOs reconciliation.
type OrderCreatedPayload struct {
	IDOrder                 int64  `json:"idOrder"`
	IDEnterprise            int    `json:"idEnterprise"`
	IDSite                  int    `json:"idSite"`
	IDArea                  int    `json:"idArea"`
	IDEquipment             int    `json:"idEquipment"`
	NmProductionOrder       string `json:"nmProductionOrder"`
	ProductionOrderQuantity int64  `json:"productionOrderQuantity"`
	TxtProductionOrderNotes string `json:"txtProductionOrderNotes"`
}

// OrderCreated inserts a PO row with status=1 (available). Idempotent
// via ON CONFLICT DO NOTHING.
func OrderCreated(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, analyticsPool *pgxpool.Pool, u *replay.UserLog) error {
		var p OrderCreatedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return replay.ErrSkip
		}
		if p.IDOrder == 0 || p.IDEquipment == 0 {
			return replay.ErrSkip
		}
		if err := insertPOAvailable(ctx, mainPool, "shadow_go_port", &p, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port: %w", err)
		}
		if analyticsPool != nil {
			if err := insertPOAvailable(ctx, analyticsPool, "public", &p, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_analytics: %w", err)
			}
		}
		return nil
	}
}

const sqlInsertPOAvailable = `INSERT INTO %s.production_orders (
		id_enterprise, id_site, id_area, id_equipment, id_order,
		nm_production_order, production_programmed, production_ordered,
		txt_production_order_notes, status
	) VALUES ($1,$2,$3,$4,$5,$6,$7,$7,$8,1)
	ON CONFLICT (id_enterprise, id_order) DO NOTHING`

func insertPOAvailable(ctx context.Context, pool *pgxpool.Pool, schema string, p *OrderCreatedPayload, userLogID int64, logger *slog.Logger) error {
	// production_programmed + production_ordered both NOT NULL on prod.
	// Conflict target qualified per bug 247 — see OrderCreatedStarted.
	sql := fmt.Sprintf(sqlInsertPOAvailable, schema)
	_, err := pool.Exec(ctx, sql,
		p.IDEnterprise, p.IDSite, p.IDArea, p.IDEquipment, p.IDOrder,
		p.NmProductionOrder, p.ProductionOrderQuantity, p.TxtProductionOrderNotes,
	)
	return failOpenIfMissing(err, "production_orders", schema, userLogID, logger)
}

// OrderStartedPayload — user_logs.category='order-started'.
// Transitions an available PO (status=1) into running (status=2).
type OrderStartedPayload struct {
	IDArea            int    `json:"idArea"`
	IDSite            int    `json:"idSite"`
	Timestamp         string `json:"timestamp"`
	IDEquipment       int    `json:"idEquipment"`
	IDEnterprise      int    `json:"idEnterprise"`
	IDProductionOrder int64  `json:"idProductionOrder"`
}

func OrderStarted(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, analyticsPool *pgxpool.Pool, u *replay.UserLog) error {
		var p OrderStartedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return replay.ErrSkip
		}
		if p.IDProductionOrder == 0 {
			return replay.ErrSkip
		}
		tsStart, err := time.Parse(time.RFC3339, p.Timestamp)
		if err != nil {
			return replay.ErrSkip
		}
		k, found, err := resolvePOKey(ctx, mainPool, p.IDProductionOrder)
		if err != nil {
			return fmt.Errorf("resolve PO natural key: %w", err)
		}
		if !found {
			logger.Warn("order-started: Flow 1 PO not found",
				slog.Int64("id_user_log", u.ID),
				slog.Int64("id_production_order", p.IDProductionOrder))
			return replay.ErrSkip
		}
		if err := updatePOStart(ctx, mainPool, "shadow_go_port", k, tsStart, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port: %w", err)
		}
		if err := openRuntimeWindow(ctx, mainPool, "shadow_go_port", k.IDEnterprise, k.IDOrder, p.IDEquipment, tsStart, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port window: %w", err)
		}
		if analyticsPool != nil {
			if err := updatePOStart(ctx, analyticsPool, "public", k, tsStart, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_analytics: %w", err)
			}
			if err := openRuntimeWindow(ctx, analyticsPool, "public", k.IDEnterprise, k.IDOrder, p.IDEquipment, tsStart, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_analytics window: %w", err)
			}
		}
		return nil
	}
}

const sqlUpdatePOStart = `UPDATE %s.production_orders
	   SET status = 2, ts_start = $1, last_update = now()
	 WHERE id_enterprise = $2 AND id_order = $3`

func updatePOStart(ctx context.Context, pool *pgxpool.Pool, schema string, k poKey, tsStart time.Time, userLogID int64, logger *slog.Logger) error {
	sql := fmt.Sprintf(sqlUpdatePOStart, schema)
	return execExpectingRows(ctx, pool, schema, "production_orders", userLogID, logger,
		sql, tsStart, k.IDEnterprise, k.IDOrder)
}

// OrderTimeChangedPayload — user_logs.category='order-time-changed'.
// Updates ts_start of an existing PO.
type OrderTimeChangedPayload struct {
	Start                    string `json:"start"`
	IDEquipment              int    `json:"idEquipment"`
	IDProductionOrder        int64  `json:"idProductionOrder"`
	IDProductionOrderRuntime int64  `json:"idProductionOrderRuntime"`
}

func OrderTimeChanged(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, analyticsPool *pgxpool.Pool, u *replay.UserLog) error {
		var p OrderTimeChangedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return replay.ErrSkip
		}
		if p.IDProductionOrder == 0 || p.Start == "" {
			return replay.ErrSkip
		}
		tsStart, err := time.Parse(time.RFC3339Nano, p.Start)
		if err != nil {
			return replay.ErrSkip
		}
		k, found, err := resolvePOKey(ctx, mainPool, p.IDProductionOrder)
		if err != nil {
			return fmt.Errorf("resolve PO natural key: %w", err)
		}
		if !found {
			logger.Warn("order-time-changed: Flow 1 PO not found",
				slog.Int64("id_user_log", u.ID),
				slog.Int64("id_production_order", p.IDProductionOrder))
			return replay.ErrSkip
		}
		if err := updatePOTsStart(ctx, mainPool, "shadow_go_port", k, tsStart, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port: %w", err)
		}
		if analyticsPool != nil {
			if err := updatePOTsStart(ctx, analyticsPool, "public", k, tsStart, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_analytics: %w", err)
			}
		}
		return nil
	}
}

const sqlUpdatePOTsStart = `UPDATE %s.production_orders
	   SET ts_start = $1, last_update = now()
	 WHERE id_enterprise = $2 AND id_order = $3`

func updatePOTsStart(ctx context.Context, pool *pgxpool.Pool, schema string, k poKey, tsStart time.Time, userLogID int64, logger *slog.Logger) error {
	sql := fmt.Sprintf(sqlUpdatePOTsStart, schema)
	return execExpectingRows(ctx, pool, schema, "production_orders", userLogID, logger,
		sql, tsStart, k.IDEnterprise, k.IDOrder)
}

// OrderReplacedPayload — user_logs.category='order-replaced'.
// Marks the PO as replaced by another (recalc_needed=true to force
// runtime aggregate recomputation).
type OrderReplacedPayload struct {
	IDEquipment       int   `json:"idEquipment"`
	IDEnterprise      int   `json:"idEnterprise"`
	IDProductionOrder int64 `json:"idProductionOrder"`
}

func OrderReplaced(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, analyticsPool *pgxpool.Pool, u *replay.UserLog) error {
		var p OrderReplacedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return replay.ErrSkip
		}
		if p.IDProductionOrder == 0 {
			return replay.ErrSkip
		}
		k, found, err := resolvePOKey(ctx, mainPool, p.IDProductionOrder)
		if err != nil {
			return fmt.Errorf("resolve PO natural key: %w", err)
		}
		if !found {
			logger.Warn("order-replaced: Flow 1 PO not found",
				slog.Int64("id_user_log", u.ID),
				slog.Int64("id_production_order", p.IDProductionOrder))
			return replay.ErrSkip
		}
		if err := updatePORecalc(ctx, mainPool, "shadow_go_port", k, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port: %w", err)
		}
		if analyticsPool != nil {
			if err := updatePORecalc(ctx, analyticsPool, "public", k, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_analytics: %w", err)
			}
		}
		return nil
	}
}

// OrderStatusChangedPayload — user_logs.category='order-status-changed'.
// Minimal payload — just triggers a recalc on the PO.
type OrderStatusChangedPayload struct {
	IDEquipment       int   `json:"idEquipment"`
	IDProductionOrder int64 `json:"idProductionOrder"`
}

func OrderStatusChanged(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, analyticsPool *pgxpool.Pool, u *replay.UserLog) error {
		var p OrderStatusChangedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return replay.ErrSkip
		}
		if p.IDProductionOrder == 0 {
			return replay.ErrSkip
		}
		k, found, err := resolvePOKey(ctx, mainPool, p.IDProductionOrder)
		if err != nil {
			return fmt.Errorf("resolve PO natural key: %w", err)
		}
		if !found {
			logger.Warn("order-status-changed: Flow 1 PO not found",
				slog.Int64("id_user_log", u.ID),
				slog.Int64("id_production_order", p.IDProductionOrder))
			return replay.ErrSkip
		}
		if err := updatePORecalc(ctx, mainPool, "shadow_go_port", k, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port: %w", err)
		}
		if analyticsPool != nil {
			if err := updatePORecalc(ctx, analyticsPool, "public", k, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_analytics: %w", err)
			}
		}
		return nil
	}
}

const sqlUpdatePORecalc = `UPDATE %s.production_orders SET recalc_needed = true, last_update = now() WHERE id_enterprise = $1 AND id_order = $2`

func updatePORecalc(ctx context.Context, pool *pgxpool.Pool, schema string, k poKey, userLogID int64, logger *slog.Logger) error {
	sql := fmt.Sprintf(sqlUpdatePORecalc, schema)
	return execExpectingRows(ctx, pool, schema, "production_orders", userLogID, logger,
		sql, k.IDEnterprise, k.IDOrder)
}

// ManualEventEditedPayload — user_logs.category='manual-event-edited'.
// UPDATE existing equipment_events_man by id_equipment_event.
type ManualEventEditedPayload struct {
	End              string `json:"end"`
	Start            string `json:"start"`
	CdMachine        string `json:"cdMachine"`
	CdCategory       string `json:"cdCategory"`
	CdSubcategory    string `json:"cdSubcategory"`
	DescCategory     string `json:"descCategory"`
	DescSubcategory  string `json:"descSubcategory"`
	IDEquipment      int    `json:"idEquipment"`
	IDEquipmentEvent int    `json:"idEquipmentEvent"`
	ChangeOver       bool   `json:"changeOver"`
	PlannedDowntime  bool   `json:"plannedDowntime"`
	TxtDowntimeNotes string `json:"txtDowntimeNotes"`
}

func ManualEventEdited(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, analyticsPool *pgxpool.Pool, u *replay.UserLog) error {
		var p ManualEventEditedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return replay.ErrSkip
		}
		if p.IDEquipmentEvent == 0 {
			return replay.ErrSkip
		}
		var tsStart, tsEnd *time.Time
		if t, err := time.Parse(time.RFC3339, p.Start); err == nil {
			tsStart = &t
		}
		if t, err := time.Parse(time.RFC3339, p.End); err == nil {
			tsEnd = &t
		}
		if err := updateManualEvent(ctx, mainPool, "shadow_go_port", &p, tsStart, tsEnd, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port: %w", err)
		}
		if analyticsPool != nil {
			if err := updateManualEvent(ctx, analyticsPool, "public", &p, tsStart, tsEnd, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_analytics: %w", err)
			}
		}
		return nil
	}
}

func updateManualEvent(ctx context.Context, pool *pgxpool.Pool, schema string, p *ManualEventEditedPayload, tsStart, tsEnd *time.Time, userLogID int64, logger *slog.Logger) error {
	// Shadow rows preserve Flow 1's id_equipment_event at insert time
	// (see ManualEventCreated ID PRESERVATION), so this UPDATE-by-id
	// resolves on the shadow paths. Rows created before that shipped are
	// unmapped — their edits land here as observable no-ops via
	// execExpectingRows (cleared by the truth-reset).
	sql := fmt.Sprintf(`UPDATE %s.equipment_events_man
	   SET ts_event = COALESCE($1, ts_event),
	       ts_end = COALESCE($2, ts_end),
	       cd_machine = $3, cd_category = $4, cd_subcategory = $5,
	       desc_category = $6, desc_subcategory = $7,
	       change_over = $8, planned_downtime = $9,
	       txt_downtime_notes = $10, last_update = now()
	 WHERE id_equipment_event = $11`, schema)
	return execExpectingRows(ctx, pool, schema, "equipment_events_man", userLogID, logger,
		sql,
		tsStart, tsEnd,
		p.CdMachine, p.CdCategory, p.CdSubcategory,
		p.DescCategory, p.DescSubcategory,
		p.ChangeOver, p.PlannedDowntime,
		p.TxtDowntimeNotes,
		p.IDEquipmentEvent,
	)
}
