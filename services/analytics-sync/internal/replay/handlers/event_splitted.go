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

// EventSplittedPayload — user_logs.category='event-splitted'. Payload
// carries an events[] array of downtime rows the operator produced by
// splitting an existing event into multiple. Each entry becomes a new
// equipment_events_man INSERT.
type EventSplittedPayload struct {
	Events []struct {
		Type            string `json:"type"` // "downtime"
		Note            string `json:"note"`
		StartTime       string `json:"startTime"`
		EndTime         string `json:"endTime"`
		Idle            string `json:"idle"`
		MachineCode     string `json:"machineCode"`
		CategoryCode    string `json:"categoryCode"`
		SubcategoryCode string `json:"subcategoryCode"`
		DescCategory    string `json:"descCategory"`
		DescSubcategory string `json:"descSubcategory"`
		ChangeOver      bool   `json:"changeOver"`
		PlannedDowntime bool   `json:"plannedDowntime"`
	} `json:"events"`
	// idEquipment / idEnterprise are typically siblings at the payload
	// root level too; keep flexible for whichever shape edge-api emits.
	IDEquipment  int `json:"idEquipment"`
	IDEnterprise int `json:"idEnterprise"`
}

// EventSplitted iterates the events[] array and inserts each as its
// own equipment_events_man row in both shadow paths, preserving Flow 1's
// id_equipment_event per row (resolved by ts_event PK lookup — see
// resolveEventID) so later edits-by-id resolve on the shadow paths.
func EventSplitted(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, shadowPool *pgxpool.Pool, u *replay.UserLog) error {
		var p EventSplittedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return replay.ErrSkip
		}
		if len(p.Events) == 0 {
			return replay.ErrSkip
		}
		if err := insertSplitEvents(ctx, mainPool, mainPool, "shadow_go_port", &p, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port: %w", err)
		}
		if shadowPool != nil {
			if err := insertSplitEvents(ctx, mainPool, shadowPool, "public", &p, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_shadow: %w", err)
			}
		}
		return nil
	}
}

const sqlInsertSplitEvent = `INSERT INTO %s.equipment_events_man (
		id_equipment_event,
		id_equipment, id_enterprise, ts_event, ts_end,
		cd_machine, cd_category, cd_subcategory,
		desc_category, desc_subcategory,
		change_over, planned_downtime,
		txt_downtime_notes,
		forced_creation_system, last_update
	) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,true,now())
	ON CONFLICT (ts_event) DO NOTHING`

func insertSplitEvents(ctx context.Context, mainPool, pool *pgxpool.Pool, schema string, p *EventSplittedPayload, userLogID int64, logger *slog.Logger) error {
	sql := fmt.Sprintf(sqlInsertSplitEvent, schema)
	for _, ev := range p.Events {
		if ev.Type != "downtime" {
			continue // split payloads only carry downtime rows today
		}
		tsStart, err := time.Parse(time.RFC3339, ev.StartTime)
		if err != nil {
			continue
		}
		tsEnd, err := time.Parse(time.RFC3339, ev.EndTime)
		if err != nil {
			continue
		}
		flow1ID, found, err := resolveEventID(ctx, mainPool, tsStart)
		if err != nil {
			return fmt.Errorf("resolve split event id: %w", err)
		}
		if !found {
			logger.Warn("event-splitted: Flow 1 event not found by ts_event — skipping row",
				slog.Int64("id_user_log", userLogID),
				slog.Time("ts_event", tsStart))
			continue
		}
		_, execErr := pool.Exec(ctx, sql,
			flow1ID,
			p.IDEquipment, p.IDEnterprise, tsStart, tsEnd,
			ev.MachineCode, ev.CategoryCode, ev.SubcategoryCode,
			ev.DescCategory, ev.DescSubcategory,
			ev.ChangeOver, ev.PlannedDowntime,
			ev.Note,
		)
		if err := failOpenIfMissing(execErr, "equipment_events_man", schema, userLogID, logger); err != nil {
			return err
		}
	}
	return nil
}
