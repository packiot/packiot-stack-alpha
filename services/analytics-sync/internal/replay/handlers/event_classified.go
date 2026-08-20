package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/replay"
)

// EventClassifiedPayload is the JSON shape edge-api emits for BOTH
// user_logs.category = 'event-justified' AND 'event-edited'. The two
// categories are the same operator action on the same row — attaching
// (or re-attaching) a downtime reason to an automated PLC event. edge-api
// (usecases/downtimes/justify) runs one code path for both and only
// splits the log category on whether the event was already classified:
// cd_category already set => 'event-edited', else 'event-justified'
// (JustifyService.execute). The resulting SQL effect (DowntimesDAO.update)
// is byte-identical, so a single handler serves both categories.
//
// Confirmed against staging user_logs 2026-07-16 (771 event-justified +
// 390 event-edited rows sampled). Shape is identical for both.
type EventClassifiedPayload struct {
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
	Idle             string `json:"idle"` // "yes"/"no" string in this payload (JustifyDto.idle)
}

// EventJustified and EventEdited both return the same underlying handler
// (eventClassified). They are exposed as two named constructors so main.go
// registers one per category, matching the edge-api category split, while
// the classification logic lives in exactly one place.
func EventJustified(logger *slog.Logger) replay.Handler { return eventClassified(logger) }
func EventEdited(logger *slog.Logger) replay.Handler    { return eventClassified(logger) }

// eventClassified mirrors edge-api's DowntimesDAO.update onto the shadow
// flows: it UPDATEs the automated equipment_events row (the PLC downtime)
// with the operator's classification (category/subcategory/machine/notes/
// change_over/idle/planned_downtime).
//
// Natural-key join (bug-248): the payload carries Flow 1's surrogate
// id_equipment_event, which is NOT aligned across flows (F1 and F2 mint
// ids from independent sequences — observed off-by-one on the same PLC
// event). So we resolve Flow 1's (id_equipment, ts_event) — the table's
// PRIMARY KEY, deterministic from the PLC stream and identical across all
// three flows — and UPDATE the shadow rows by that key.
//
// The target equipment_events row is created on the shadow flows by the
// oeecloud ingestion pipeline (the same raw PLC stream), NOT by
// shadow-mirror — which is exactly why downtime-event-created stays
// deferred (see main.go). If ingestion hasn't produced the row yet (or
// the equipment isn't simulated on the shadow flows), the UPDATE matches
// zero rows: an observable no-op via execExpectingRows, not an error.
//
// Idempotent: the UPDATE is a pure set-to-payload-values, so replaying the
// same log entry converges to the same row state.
func eventClassified(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, shadowPool *pgxpool.Pool, u *replay.UserLog) error {
		var p EventClassifiedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			logger.Warn("event-classified: payload unmarshal failed — skipping",
				slog.Int64("id_user_log", u.ID),
				slog.String("err", err.Error()))
			return replay.ErrSkip
		}
		if p.IDEquipmentEvent == 0 {
			logger.Warn("event-classified: missing idEquipmentEvent — skipping",
				slog.Int64("id_user_log", u.ID))
			return replay.ErrSkip
		}

		key, found, err := resolveEquipmentEventKey(ctx, mainPool, p.IDEquipmentEvent)
		if err != nil {
			return fmt.Errorf("resolve equipment_event natural key: %w", err)
		}
		if !found {
			// Flow 1 event gone (pre-cursor history) — nothing to key on.
			logger.Warn("event-classified: Flow 1 event not found by id_equipment_event — skipping",
				slog.Int64("id_user_log", u.ID),
				slog.Int64("id_equipment_event", p.IDEquipmentEvent))
			return replay.ErrSkip
		}

		// Path 1: shadow_go_port (F2) on main pool.
		if err := updateEventClassification(ctx, mainPool, "shadow_go_port", &p, key, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port: %w", err)
		}
		// Path 2: public (F3) on shadow pool (may be nil = disabled).
		if shadowPool != nil {
			if err := updateEventClassification(ctx, shadowPool, "public", &p, key, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_shadow: %w", err)
			}
		}
		return nil
	}
}

// sqlUpdateEventClassification mirrors edge-api DowntimesDAO.update
// (usecases/downtimes/justify) column-for-column, but re-keyed onto the
// flow-stable natural key (id_equipment, ts_event) instead of Flow 1's
// per-flow id_equipment_event. last_update = now() follows the shadow
// handler convention (equipment_events has no update trigger on the
// shadow schemas; last_update is an audit column, not compared for
// parity).
const sqlUpdateEventClassification = `UPDATE %s.equipment_events
	   SET cd_category = $1,
	       desc_category = $2,
	       cd_machine = $3,
	       cd_subcategory = $4,
	       desc_subcategory = $5,
	       txt_downtime_notes = $6,
	       change_over = $7,
	       idle = $8,
	       planned_downtime = $9,
	       last_update = now()
	 WHERE id_equipment = $10 AND ts_event = $11`

func updateEventClassification(ctx context.Context, pool *pgxpool.Pool, schema string, p *EventClassifiedPayload, key equipmentEventKey, userLogID int64, logger *slog.Logger) error {
	sql := fmt.Sprintf(sqlUpdateEventClassification, schema)
	return execExpectingRows(ctx, pool, schema, "equipment_events", userLogID, logger,
		sql,
		p.CdCategory, p.DescCategory, p.CdMachine,
		p.CdSubcategory, p.DescSubcategory, p.TxtDowntimeNotes,
		p.ChangeOver, p.Idle, p.PlannedDowntime,
		key.IDEquipment, key.TsEvent,
	)
}
