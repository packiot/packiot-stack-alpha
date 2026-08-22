package replicate

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ─── shared observability + fail-open (mirrors internal/replay/handlers) ───

var noopObserver = func(table string) {}

// SetNoopObserver wires the zero-row-UPDATE callback (main -> metrics).
func SetNoopObserver(fn func(table string)) { noopObserver = fn }

// execExpectingRows runs an UPDATE, recording a warn + metric on a zero-row
// match. A zero-row UPDATE is a replay gap (base row not yet present), not a
// poison message — it still advances the cursor.
func execExpectingRows(ctx context.Context, pool *pgxpool.Pool, table string, userLogID int64, logger *slog.Logger, sql string, args ...any) error {
	ct, err := pool.Exec(ctx, sql, args...)
	if err != nil {
		return failOpenIfMissing(err, table, userLogID, logger)
	}
	if ct.RowsAffected() == 0 {
		noopObserver(table)
		logger.Warn("update matched no rows", slog.Int64("id_user_log", userLogID), slog.String("table", table))
	}
	return nil
}

// failOpenIfMissing swallows 42P01 (missing table) so a partially
// provisioned staging plane never wedges the loop.
func failOpenIfMissing(err error, table string, userLogID int64, logger *slog.Logger) error {
	if err == nil {
		return nil
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "42P01" {
		logger.Warn("target table missing — fail-open", slog.Int64("id_user_log", userLogID), slog.String("table", table))
		return nil
	}
	return err
}

func parseTS(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t, true
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, true
	}
	return time.Time{}, false
}

// resolveLegacyOrder maps a legacy id_production_order (surrogate) to its
// natural id_order, verifying it belongs to the polled source enterprise.
// The staging PO is keyed by (dst_enterprise, id_order) — never the legacy
// surrogate, which lives in a different id space (bug-248 discipline).
func resolveLegacyOrder(ctx context.Context, legacy *pgxpool.Pool, idProductionOrder int64, srcEnterprise int) (int64, bool, error) {
	var idOrder int64
	var ent int
	err := legacy.QueryRow(ctx,
		`SELECT id_order, id_enterprise FROM production_orders WHERE id_production_order = $1`,
		idProductionOrder).Scan(&idOrder, &ent)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	if ent != srcEnterprise {
		return 0, false, nil
	}
	return idOrder, true, nil
}

// resolveLegacyEventTS maps a legacy id_equipment_event to its (legacy
// id_equipment, ts_event). ts_event is deterministic from the PLC stream,
// so it is the join key against staging's equipment_events.
func resolveLegacyEventTS(ctx context.Context, legacy *pgxpool.Pool, idEquipmentEvent int64) (int, time.Time, bool, error) {
	var idEq int
	var ts time.Time
	err := legacy.QueryRow(ctx,
		`SELECT id_equipment, ts_event FROM equipment_events WHERE id_equipment_event = $1`,
		idEquipmentEvent).Scan(&idEq, &ts)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, time.Time{}, false, nil
	}
	if err != nil {
		return 0, time.Time{}, false, err
	}
	return idEq, ts, true, nil
}

// resolveLegacyManualTS maps a legacy equipment_events_man surrogate id to
// its current (legacy id_equipment, ts_event).
func resolveLegacyManualTS(ctx context.Context, legacy *pgxpool.Pool, idEquipmentEvent int64) (int, time.Time, bool, error) {
	var idEq int
	var ts time.Time
	err := legacy.QueryRow(ctx,
		`SELECT id_equipment, ts_event FROM equipment_events_man WHERE id_equipment_event = $1`,
		idEquipmentEvent).Scan(&idEq, &ts)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, time.Time{}, false, nil
	}
	if err != nil {
		return 0, time.Time{}, false, err
	}
	return idEq, ts, true, nil
}

// ─── runtime-window machinery (single-dest port of production_orders.go) ───
// Staging's OEE runtime chain reads production_orders_runtime windows; a PO
// without a window starves the compute jobs. All ids here are already
// translated to staging.

const sqlCloseWindowsForEquipment = `UPDATE public.production_orders_runtime r
	   SET runtime_timerange = tstzrange(lower(runtime_timerange), $2), recalc_needed = true
	 WHERE r.id_equipment = $1 AND upper(runtime_timerange) IS NULL AND lower(runtime_timerange) < $2`

const sqlSupersedeRunningPO = `UPDATE public.production_orders
	   SET status = 3, last_update = now()
	 WHERE id_equipment = $1 AND status = 2 AND NOT (id_enterprise = $2 AND id_order = $3)`

const sqlOpenWindow = `INSERT INTO public.production_orders_runtime
	       (id_production_order, id_equipment, runtime_timerange, recalc_needed)
	SELECT po.id_production_order, po.id_equipment, tstzrange($3, NULL), true
	  FROM public.production_orders po
	 WHERE po.id_enterprise = $1 AND po.id_order = $2
	   AND NOT EXISTS (SELECT 1 FROM public.production_orders_runtime x
	        WHERE x.id_production_order = po.id_production_order AND upper(x.runtime_timerange) IS NULL)`

const sqlCloseWindowsForPO = `UPDATE public.production_orders_runtime r
	   SET runtime_timerange = tstzrange(lower(runtime_timerange), $3), recalc_needed = true
	  FROM public.production_orders po
	 WHERE po.id_enterprise = $1 AND po.id_order = $2
	   AND r.id_production_order = po.id_production_order
	   AND upper(r.runtime_timerange) IS NULL AND lower(r.runtime_timerange) < $3`

func openRuntimeWindow(ctx context.Context, dst *pgxpool.Pool, ent int, idOrder int64, idEquipment int, ts time.Time, userLogID int64, logger *slog.Logger) error {
	if _, err := dst.Exec(ctx, sqlCloseWindowsForEquipment, idEquipment, ts); err != nil {
		return failOpenIfMissing(err, "production_orders_runtime", userLogID, logger)
	}
	if _, err := dst.Exec(ctx, sqlSupersedeRunningPO, idEquipment, ent, idOrder); err != nil {
		return failOpenIfMissing(err, "production_orders", userLogID, logger)
	}
	_, err := dst.Exec(ctx, sqlOpenWindow, ent, idOrder, ts)
	return failOpenIfMissing(err, "production_orders_runtime", userLogID, logger)
}

func closeRuntimeWindow(ctx context.Context, dst *pgxpool.Pool, ent int, idOrder int64, ts time.Time, userLogID int64, logger *slog.Logger) error {
	_, err := dst.Exec(ctx, sqlCloseWindowsForPO, ent, idOrder, ts)
	return failOpenIfMissing(err, "production_orders_runtime", userLogID, logger)
}

// ─── production_orders SQL (staging-keyed) ───

const sqlInsertPOAvailable = `INSERT INTO public.production_orders (
		id_enterprise, id_site, id_area, id_equipment, id_order,
		nm_production_order, production_programmed, production_ordered,
		txt_production_order_notes, status)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$7,$8,1)
	ON CONFLICT (id_enterprise, id_order) DO NOTHING`

const sqlInsertPORunning = `INSERT INTO public.production_orders (
		id_enterprise, id_site, id_area, id_equipment, id_order,
		nm_production_order, production_programmed, production_ordered,
		txt_production_order_notes, status, ts_start)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$7,$8,2,$9)
	ON CONFLICT (id_enterprise, id_order) DO NOTHING`

const sqlUpdatePOStart = `UPDATE public.production_orders
	   SET status = 2, ts_start = $1, last_update = now()
	 WHERE id_enterprise = $2 AND id_order = $3`

const sqlUpdatePOStop = `UPDATE public.production_orders
	   SET status = $1, ts_end = $2, production_real = $3, last_update = now()
	 WHERE id_enterprise = $4 AND id_order = $5`

const sqlUpdatePOTsStart = `UPDATE public.production_orders
	   SET ts_start = $1, last_update = now()
	 WHERE id_enterprise = $2 AND id_order = $3`

const sqlUpdatePORecalc = `UPDATE public.production_orders
	   SET recalc_needed = true, last_update = now()
	 WHERE id_enterprise = $1 AND id_order = $2`

const sqlClosePOChanged = `UPDATE public.production_orders
	   SET status = $1, ts_end = $2, production_final = $3, recalc_needed = true, last_update = now()
	 WHERE id_enterprise = $4 AND id_order = $5`

// ─── equipment_events / _man SQL (staging-keyed) ───

// downtime-event-created: base PLC event. id_equipment_event is NOT NULL
// with no default on staging, so we synthesise a deterministic value from
// (ts_ms, id_equipment) — it carries no cross-flow meaning (no unique index
// on it); the natural key is (id_equipment, ts_event).
const sqlInsertEquipmentEvent = `INSERT INTO public.equipment_events (
		id_equipment, ts_event, status, id_equipment_event, id_enterprise,
		forced_creation_system, last_update)
	VALUES ($1,$2,$3,$4,$5,true,now())
	ON CONFLICT (id_equipment, ts_event) DO NOTHING`

const sqlUpdateEventClassification = `UPDATE public.equipment_events
	   SET cd_category = $1, desc_category = $2, cd_machine = $3,
	       cd_subcategory = $4, desc_subcategory = $5, txt_downtime_notes = $6,
	       change_over = $7, idle = $8, planned_downtime = $9, last_update = now()
	 WHERE id_equipment = $10 AND ts_event = $11`

// equipment_events_man: id_equipment_event is a staging IDENTITY serial —
// deliberately OMITTED from the column list (the coordinator's warning: do
// not copy the legacy serial). Idempotent via the ts_event unique key.
const sqlInsertManualEvent = `INSERT INTO public.equipment_events_man (
		id_equipment, id_enterprise, ts_event, ts_end, duration,
		cd_machine, cd_category, cd_subcategory, desc_category, desc_subcategory,
		change_over, planned_downtime, txt_downtime_notes,
		forced_creation_system, last_update)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,true,now())
	ON CONFLICT (id_equipment, ts_event) DO NOTHING`

const sqlUpdateManualEvent = `UPDATE public.equipment_events_man
	   SET ts_event = COALESCE($1, ts_event), ts_end = COALESCE($2, ts_end),
	       cd_machine = $3, cd_category = $4, cd_subcategory = $5,
	       desc_category = $6, desc_subcategory = $7,
	       change_over = $8, planned_downtime = $9, txt_downtime_notes = $10, last_update = now()
	 WHERE id_equipment = $11 AND ts_event = $12`

func genEventID(ts time.Time, stagingEquip int) int64 {
	return ts.UnixMilli()*1000 + int64(stagingEquip%1000)
}

// ═══════════════════════════ handlers ═══════════════════════════

type downtimeEventCreatedPayload struct {
	Events []struct {
		Topic       string    `json:"topic"`
		Status      *int      `json:"status"`
		Timestamp   flexInt64 `json:"timestamp"` // epoch ms
		IDEquipment int       `json:"idEquipment"`
	} `json:"events"`
}

// DowntimeEventCreated inserts the raw PLC equipment_events rows (the base
// rows event-justified/edited later classify). Gated by cfg — the
// in-instance mirror defers this, but the twin's tee does not carry every
// line, so we fill the base rows. ON CONFLICT never clobbers a tee row.
func DowntimeEventCreated(logger *slog.Logger, enabled bool) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		if !enabled {
			return ErrSkip
		}
		var p downtimeEventCreatedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if len(p.Events) == 0 {
			return ErrSkip
		}
		for _, ev := range p.Events {
			eq, ok := r.ResolveEquipment(ev.IDEquipment)
			if !ok {
				logger.Warn("downtime-event-created: unresolved equipment", slog.Int64("id_user_log", u.ID), slog.Int("legacy_equipment", ev.IDEquipment))
				continue
			}
			if ev.Timestamp == 0 {
				continue
			}
			ts := time.UnixMilli(ev.Timestamp.Int64()).UTC()
			_, err := dst.Exec(ctx, sqlInsertEquipmentEvent,
				eq.IDEquipment, ts, ev.Status, genEventID(ts, eq.IDEquipment), eq.IDEnterprise)
			if err := failOpenIfMissing(err, "equipment_events", u.ID, logger); err != nil {
				return err
			}
		}
		return nil
	}
}

type eventClassifiedPayload struct {
	IDEquipment      int    `json:"idEquipment"`
	IDEquipmentEvent int64  `json:"idEquipmentEvent"`
	CdMachine        string `json:"cdMachine"`
	CdCategory       string `json:"cdCategory"`
	CdSubcategory    string `json:"cdSubcategory"`
	DescCategory     string `json:"descCategory"`
	DescSubcategory  string `json:"descSubcategory"`
	TxtDowntimeNotes string `json:"txtDowntimeNotes"`
	ChangeOver       bool   `json:"changeOver"`
	PlannedDowntime  bool   `json:"plannedDowntime"`
	Idle             string `json:"idle"`
}

// EventClassified serves both event-justified and event-edited: it UPDATEs
// the base equipment_events row (created by the tee or by
// DowntimeEventCreated) with the operator's downtime classification,
// re-keyed onto the flow-stable natural key (staging id_equipment,
// ts_event) resolved from the LEGACY event.
func EventClassified(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p eventClassifiedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDEquipmentEvent == 0 {
			return ErrSkip
		}
		legEq, ts, found, err := resolveLegacyEventTS(ctx, legacy, p.IDEquipmentEvent)
		if err != nil {
			return fmt.Errorf("resolve legacy event: %w", err)
		}
		if !found {
			logger.Warn("event-classified: legacy event gone", slog.Int64("id_user_log", u.ID), slog.Int64("id_equipment_event", p.IDEquipmentEvent))
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(legEq)
		if !ok {
			logger.Warn("event-classified: unresolved equipment", slog.Int64("id_user_log", u.ID), slog.Int("legacy_equipment", legEq))
			return ErrSkip
		}
		return execExpectingRows(ctx, dst, "equipment_events", u.ID, logger, sqlUpdateEventClassification,
			p.CdCategory, p.DescCategory, p.CdMachine,
			p.CdSubcategory, p.DescSubcategory, p.TxtDowntimeNotes,
			p.ChangeOver, p.Idle, p.PlannedDowntime,
			eq.IDEquipment, ts)
	}
}

type manualEventCreatedPayload struct {
	IDEquipment      int    `json:"idEquipment"`
	TsEvent          string `json:"tsEvent"`
	TsEnd            string `json:"tsEnd"`
	Duration         int    `json:"duration"`
	CdMachine        string `json:"cdMachine"`
	CdCategory       string `json:"cdCategory"`
	CdSubcategory    string `json:"cdSubcategory"`
	DescCategory     string `json:"descCategory"`
	DescSubcategory  string `json:"descSubcategory"`
	TxtDowntimeNotes string `json:"txtDowntimeNotes"`
}

// ManualEventCreated inserts an operator-authored downtime into staging
// equipment_events_man. Idempotent via the ts_event unique key.
func ManualEventCreated(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p manualEventCreatedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		tsEvent, ok := parseTS(p.TsEvent)
		if p.IDEquipment == 0 || !ok {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(p.IDEquipment)
		if !ok {
			logger.Warn("manual-event-created: unresolved equipment", slog.Int64("id_user_log", u.ID), slog.Int("legacy_equipment", p.IDEquipment))
			return ErrSkip
		}
		var tsEnd *time.Time
		if t, ok := parseTS(p.TsEnd); ok {
			tsEnd = &t
		}
		_, err := dst.Exec(ctx, sqlInsertManualEvent,
			eq.IDEquipment, eq.IDEnterprise, tsEvent, tsEnd, p.Duration,
			p.CdMachine, p.CdCategory, p.CdSubcategory, p.DescCategory, p.DescSubcategory,
			false, false, p.TxtDowntimeNotes)
		return failOpenIfMissing(err, "equipment_events_man", u.ID, logger)
	}
}

type manualEventEditedPayload struct {
	Start            string `json:"start"`
	End              string `json:"end"`
	CdMachine        string `json:"cdMachine"`
	CdCategory       string `json:"cdCategory"`
	CdSubcategory    string `json:"cdSubcategory"`
	DescCategory     string `json:"descCategory"`
	DescSubcategory  string `json:"descSubcategory"`
	IDEquipment      int    `json:"idEquipment"`
	IDEquipmentEvent int64  `json:"idEquipmentEvent"`
	ChangeOver       bool   `json:"changeOver"`
	PlannedDowntime  bool   `json:"plannedDowntime"`
	TxtDowntimeNotes string `json:"txtDowntimeNotes"`
}

// ManualEventEdited best-effort UPDATEs a replicated manual event by
// (staging id_equipment, legacy current ts_event). If the operator edited
// the START time the legacy row's ts_event has moved and the staging row —
// keyed on the original ts_event — won't match; that surfaces as an
// observable no-op (execExpectingRows), never a failure. Manual edits are
// rare (~3/48h) so this is an accepted limitation, not a data-loss path.
func ManualEventEdited(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p manualEventEditedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDEquipmentEvent == 0 {
			return ErrSkip
		}
		legEq, curTS, found, err := resolveLegacyManualTS(ctx, legacy, p.IDEquipmentEvent)
		if err != nil {
			return fmt.Errorf("resolve legacy manual event: %w", err)
		}
		if !found {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(legEq)
		if !ok {
			return ErrSkip
		}
		var newStart, newEnd *time.Time
		if t, ok := parseTS(p.Start); ok {
			newStart = &t
		}
		if t, ok := parseTS(p.End); ok {
			newEnd = &t
		}
		return execExpectingRows(ctx, dst, "equipment_events_man", u.ID, logger, sqlUpdateManualEvent,
			newStart, newEnd, p.CdMachine, p.CdCategory, p.CdSubcategory,
			p.DescCategory, p.DescSubcategory, p.ChangeOver, p.PlannedDowntime, p.TxtDowntimeNotes,
			eq.IDEquipment, curTS)
	}
}

type eventSplittedPayload struct {
	Events []struct {
		Type            string `json:"type"`
		Note            string `json:"note"`
		StartTime       string `json:"startTime"`
		EndTime         string `json:"endTime"`
		MachineCode     string `json:"machineCode"`
		CategoryCode    string `json:"categoryCode"`
		SubcategoryCode string `json:"subcategoryCode"`
		DescCategory    string `json:"descCategory"`
		DescSubcategory string `json:"descSubcategory"`
		ChangeOver      bool   `json:"changeOver"`
		PlannedDowntime bool   `json:"plannedDowntime"`
	} `json:"events"`
	IDEquipment int `json:"idEquipment"`
}

// EventSplitted inserts each split downtime as its own manual event.
func EventSplitted(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p eventSplittedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if len(p.Events) == 0 || p.IDEquipment == 0 {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(p.IDEquipment)
		if !ok {
			logger.Warn("event-splitted: unresolved equipment", slog.Int64("id_user_log", u.ID), slog.Int("legacy_equipment", p.IDEquipment))
			return ErrSkip
		}
		for _, ev := range p.Events {
			if ev.Type != "downtime" {
				continue
			}
			tsStart, ok := parseTS(ev.StartTime)
			if !ok {
				continue
			}
			var tsEnd *time.Time
			if t, ok := parseTS(ev.EndTime); ok {
				tsEnd = &t
			}
			_, err := dst.Exec(ctx, sqlInsertManualEvent,
				eq.IDEquipment, eq.IDEnterprise, tsStart, tsEnd, 0,
				ev.MachineCode, ev.CategoryCode, ev.SubcategoryCode, ev.DescCategory, ev.DescSubcategory,
				ev.ChangeOver, ev.PlannedDowntime, ev.Note)
			if err := failOpenIfMissing(err, "equipment_events_man", u.ID, logger); err != nil {
				return err
			}
		}
		return nil
	}
}

// ─── production-order lifecycle ───

type orderCreatedPayload struct {
	IDOrder                 flexInt64 `json:"idOrder"`
	IDEquipment             int       `json:"idEquipment"`
	NmProductionOrder       string    `json:"nmProductionOrder"`
	ProductionOrderQuantity flexInt64 `json:"productionOrderQuantity"`
	TxtProductionOrderNotes string    `json:"txtProductionOrderNotes"`
}

func OrderCreated(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderCreatedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDOrder == 0 || p.IDEquipment == 0 {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(p.IDEquipment)
		if !ok {
			return ErrSkip
		}
		_, err := dst.Exec(ctx, sqlInsertPOAvailable,
			eq.IDEnterprise, eq.IDSite, eq.IDArea, eq.IDEquipment, p.IDOrder.Int64(),
			p.NmProductionOrder, p.ProductionOrderQuantity.Int64(), p.TxtProductionOrderNotes)
		return failOpenIfMissing(err, "production_orders", u.ID, logger)
	}
}

type orderCreatedStartedPayload struct {
	IDOrder                 flexInt64 `json:"idOrder"`
	IDEquipment             int       `json:"idEquipment"`
	Timestamp               string    `json:"timestamp"`
	NmProductionOrder       string    `json:"nmProductionOrder"`
	ProductionOrderQuantity flexInt64 `json:"productionOrderQuantity"`
	TxtProductionOrderNotes string    `json:"txtProductionOrderNotes"`
}

func OrderCreatedStarted(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderCreatedStartedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDOrder == 0 || p.IDEquipment == 0 {
			return ErrSkip
		}
		tsStart, ok := parseTS(p.Timestamp)
		if !ok {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(p.IDEquipment)
		if !ok {
			return ErrSkip
		}
		if err := openRuntimeWindow(ctx, dst, eq.IDEnterprise, p.IDOrder.Int64(), eq.IDEquipment, tsStart, u.ID, logger); err != nil {
			return err
		}
		if _, err := dst.Exec(ctx, sqlInsertPORunning,
			eq.IDEnterprise, eq.IDSite, eq.IDArea, eq.IDEquipment, p.IDOrder.Int64(),
			p.NmProductionOrder, p.ProductionOrderQuantity.Int64(), p.TxtProductionOrderNotes, tsStart); err != nil {
			if e := failOpenIfMissing(err, "production_orders", u.ID, logger); e != nil {
				return e
			}
		}
		return openRuntimeWindow(ctx, dst, eq.IDEnterprise, p.IDOrder.Int64(), eq.IDEquipment, tsStart, u.ID, logger)
	}
}

type orderStartedPayload struct {
	Timestamp         string `json:"timestamp"`
	IDEquipment       int    `json:"idEquipment"`
	IDProductionOrder int64  `json:"idProductionOrder"`
}

func OrderStarted(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderStartedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDProductionOrder == 0 {
			return ErrSkip
		}
		tsStart, ok := parseTS(p.Timestamp)
		if !ok {
			return ErrSkip
		}
		idOrder, found, err := resolveLegacyOrder(ctx, legacy, p.IDProductionOrder, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		ent := r.DstEnterprise()
		if err := execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlUpdatePOStart, tsStart, ent, idOrder); err != nil {
			return err
		}
		if eq, ok := r.ResolveEquipment(p.IDEquipment); ok {
			return openRuntimeWindow(ctx, dst, ent, idOrder, eq.IDEquipment, tsStart, u.ID, logger)
		}
		return nil
	}
}

type orderStoppedPayload struct {
	StopType                string    `json:"stopType"`
	Timestamp               string    `json:"timestamp"`
	IDProductionOrder       int64     `json:"idProductionOrder"`
	ProductionOrderQuantity flexInt64 `json:"productionOrderQuantity"`
}

func OrderStopped(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderStoppedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDProductionOrder == 0 {
			return ErrSkip
		}
		tsEnd, ok := parseTS(p.Timestamp)
		if !ok {
			return ErrSkip
		}
		idOrder, found, err := resolveLegacyOrder(ctx, legacy, p.IDProductionOrder, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		status := 3
		if p.StopType == "pause" {
			status = 4
		}
		ent := r.DstEnterprise()
		if err := closeRuntimeWindow(ctx, dst, ent, idOrder, tsEnd, u.ID, logger); err != nil {
			return err
		}
		return execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlUpdatePOStop,
			status, tsEnd, p.ProductionOrderQuantity.Int64(), ent, idOrder)
	}
}

type orderTimeChangedPayload struct {
	Start             string `json:"start"`
	IDProductionOrder int64  `json:"idProductionOrder"`
}

func OrderTimeChanged(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderTimeChangedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDProductionOrder == 0 || p.Start == "" {
			return ErrSkip
		}
		tsStart, ok := parseTS(p.Start)
		if !ok {
			return ErrSkip
		}
		idOrder, found, err := resolveLegacyOrder(ctx, legacy, p.IDProductionOrder, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		return execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlUpdatePOTsStart, tsStart, r.DstEnterprise(), idOrder)
	}
}

type orderRecalcPayload struct {
	IDProductionOrder int64 `json:"idProductionOrder"`
}

// OrderRecalc serves order-replaced + order-status-changed — both just flag
// the PO for runtime recomputation.
func OrderRecalc(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderRecalcPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDProductionOrder == 0 {
			return ErrSkip
		}
		idOrder, found, err := resolveLegacyOrder(ctx, legacy, p.IDProductionOrder, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		return execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlUpdatePORecalc, r.DstEnterprise(), idOrder)
	}
}

type orderChangedPayload struct {
	IDOrder                     flexInt64 `json:"idOrder"`
	StopType                    string    `json:"stopType"`
	Timestamp                   string    `json:"timestamp"`
	IDEquipment                 int       `json:"idEquipment"`
	ShouldCreatePo              bool      `json:"shouldCreatePo"`
	OldIDProductionOrder        int64     `json:"oldIdProductionOrder"`
	ProductionOrderQuantity     flexInt64 `json:"productionOrderQuantity"`
	OldProductionOrderProdFinal flexInt64 `json:"oldProductionOrderProdFinal"`
}

// OrderChanged closes the old PO (by natural key from the legacy surrogate)
// and optionally opens a new one — the combined operator step.
func OrderChanged(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderChangedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.OldIDProductionOrder == 0 {
			return ErrSkip
		}
		ts, ok := parseTS(p.Timestamp)
		if !ok {
			return ErrSkip
		}
		oldOrder, found, err := resolveLegacyOrder(ctx, legacy, p.OldIDProductionOrder, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve old legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		ent := r.DstEnterprise()
		status := 3
		if p.StopType == "pause" {
			status = 4
		}
		if err := closeRuntimeWindow(ctx, dst, ent, oldOrder, ts, u.ID, logger); err != nil {
			return err
		}
		if err := execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlClosePOChanged,
			status, ts, p.OldProductionOrderProdFinal.Int64(), ent, oldOrder); err != nil {
			return err
		}
		if !p.ShouldCreatePo || p.IDOrder == 0 {
			return nil
		}
		eq, ok := r.ResolveEquipment(p.IDEquipment)
		if !ok {
			return nil
		}
		if err := openRuntimeWindow(ctx, dst, ent, p.IDOrder.Int64(), eq.IDEquipment, ts, u.ID, logger); err != nil {
			return err
		}
		_, err = dst.Exec(ctx, sqlInsertPORunning,
			eq.IDEnterprise, eq.IDSite, eq.IDArea, eq.IDEquipment, p.IDOrder.Int64(),
			"", p.ProductionOrderQuantity.Int64(), "", ts)
		if err := failOpenIfMissing(err, "production_orders", u.ID, logger); err != nil {
			return err
		}
		return openRuntimeWindow(ctx, dst, ent, p.IDOrder.Int64(), eq.IDEquipment, ts, u.ID, logger)
	}
}
