package replay

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/translate"
)

type EditPayload struct {
	IDEquipment      int    `json:"idEquipment"`
	IDEquipmentEvent int64  `json:"idEquipmentEvent"`
}

// EventEdited — staging's edit-manual-event DTO requires start + end as
// NOT-NULL body fields. Derive them from the prod equipment_event row
// (preserves the operator's apparent intent of "keep boundaries, change
// metadata only"). If prod's ts_end is NULL (event still running), cap
// staging's end at now() — same fallback the TS port uses.
func EventEdited(
	cfg *config.Config,
	t *translate.Translator,
	prodDB *db.Prod,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, tx pgx.Tx, row db.ProdUserLog) error {
		var p EditPayload
		if err := json.Unmarshal(row.Payload, &p); err != nil {
			return fmt.Errorf("parse event-edited payload: %w", err)
		}
		if p.IDEquipment == 0 || p.IDEquipmentEvent == 0 {
			return fmt.Errorf("event-edited payload missing fields: %+v", p)
		}

		stagingEqID, err := t.Equipment(ctx, p.IDEquipment)
		if err != nil {
			return fmt.Errorf("translate equipment: %w", err)
		}
		stagingEventID, err := t.EquipmentEvent(ctx, p.IDEquipmentEvent)
		if err != nil {
			if errors.Is(err, translate.ErrUnmapped) {
				return fmt.Errorf("equipment_event %d unmapped (no staging interval overlap; see WARN log): %w",
					p.IDEquipmentEvent, err)
			}
			return fmt.Errorf("translate equipment_event: %w", err)
		}

		// Read prod equipment_event for ts_event + ts_end. The matcher
		// above already read this row, but caching to avoid a 2nd cheap
		// indexed SELECT is premature given <10 events/min in practice.
		var tsEvent time.Time
		var tsEnd sql.NullTime
		found, err := prodDB.SelectOne(ctx,
			`SELECT ts_event, ts_end FROM equipment_events
			  WHERE id_equipment_event = $1 AND id_enterprise = $2`,
			[]any{p.IDEquipmentEvent, cfg.ProdEnterpriseID}, &tsEvent, &tsEnd)
		if err != nil {
			return fmt.Errorf("prod equipment_event read: %w", err)
		}
		if !found {
			return fmt.Errorf("prod equipment_event %d disappeared between translation and replay", p.IDEquipmentEvent)
		}
		endTime := time.Now().UTC()
		if tsEnd.Valid {
			endTime = tsEnd.Time
		}

		if err := db.InsertMapping(ctx, tx, db.MapInsert{
			EntityType:  "equipment_event",
			Source:      cfg.SourceName,
			ProdID:      p.IDEquipmentEvent,
			StagingID:   stagingEventID,
			SourceLogID: row.IDUserLogs,
		}); err != nil {
			return fmt.Errorf("insert mapping: %w", err)
		}

		var raw map[string]any
		if err := json.Unmarshal(row.Payload, &raw); err != nil {
			return fmt.Errorf("re-parse payload: %w", err)
		}
		raw["idEquipment"] = stagingEqID
		raw["idEquipmentEvent"] = stagingEventID
		raw["idEnterprise"] = cfg.StagingEnterpriseID
		raw["start"] = tsEvent.UTC().Format(time.RFC3339Nano)
		raw["end"] = endTime.UTC().Format(time.RFC3339Nano)

		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/downtimes/edit-manual-event", raw)
		if err != nil {
			return err
		}
		logger.Info("replayed event-edited",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodEventID", p.IDEquipmentEvent),
			slog.Int64("stagingEventID", stagingEventID),
			slog.Int("status", status))
		return nil
	}
}
