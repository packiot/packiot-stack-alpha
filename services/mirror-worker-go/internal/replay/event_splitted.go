package replay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/translate"
)

type SplitPayload struct {
	Events           []any  `json:"events"`
	EventType        string `json:"eventType"`
	IDEquipment      int    `json:"idEquipment"`
	IDEquipmentEvent int64  `json:"idEquipmentEvent"`
}

// EventSplitted — events array passes through verbatim (operator-set
// metadata only, no nested IDs to translate). Same translation chain as
// event-justified / event-edited.
func EventSplitted(
	cfg *config.Config,
	t *translate.Translator,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, tx pgx.Tx, row db.ProdUserLog) error {
		var p SplitPayload
		if err := json.Unmarshal(row.Payload, &p); err != nil {
			return fmt.Errorf("parse event-splitted payload: %w", err)
		}
		if p.IDEquipment == 0 || p.IDEquipmentEvent == 0 || p.EventType == "" {
			return fmt.Errorf("event-splitted payload missing fields: %+v", p)
		}
		if len(p.Events) == 0 {
			return fmt.Errorf("event-splitted payload missing non-empty events array")
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

		if err := db.InsertMapping(ctx, tx, db.MapInsert{
			EntityType:  "equipment_event",
			Source:      cfg.SourceName,
			ProdID:      p.IDEquipmentEvent,
			StagingID:   stagingEventID,
			SourceLogID: row.IDUserLogs,
		}); err != nil {
			return fmt.Errorf("insert mapping: %w", err)
		}

		body := map[string]any{
			"idEquipment":      stagingEqID,
			"idEquipmentEvent": stagingEventID,
			"eventType":        p.EventType,
			"events":           p.Events,
		}
		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/downtimes/split", body)
		if err != nil {
			return err
		}
		logger.Info("replayed event-splitted",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodEventID", p.IDEquipmentEvent),
			slog.Int64("stagingEventID", stagingEventID),
			slog.Int("splitInto", len(p.Events)),
			slog.Int("status", status))
		return nil
	}
}
