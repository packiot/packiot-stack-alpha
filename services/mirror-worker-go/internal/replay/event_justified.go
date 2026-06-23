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

// JustifyPayload mirrors prod's shape. Forwarded almost verbatim to staging
// — we replace idEquipment / idEquipmentEvent with their staging IDs and
// add idEnterprise. Unknown extra fields are tolerated by class-validator.
type JustifyPayload struct {
	Idle             string  `json:"idle,omitempty"`
	CdMachine        string  `json:"cdMachine,omitempty"`
	CdCategory       string  `json:"cdCategory,omitempty"`
	DescCategory     string  `json:"descCategory,omitempty"`
	CdSubcategory    string  `json:"cdSubcategory,omitempty"`
	DescSubcategory  string  `json:"descSubcategory,omitempty"`
	ChangeOver       *bool   `json:"changeOver,omitempty"`
	PlannedDowntime  *bool   `json:"plannedDowntime,omitempty"`
	IDEquipment      int     `json:"idEquipment"`
	IDEquipmentEvent int64   `json:"idEquipmentEvent"`
	TxtDowntimeNotes string  `json:"txtDowntimeNotes,omitempty"`
}

func EventJustified(
	cfg *config.Config,
	t *translate.Translator,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, tx pgx.Tx, row db.ProdUserLog) error {
		var p JustifyPayload
		if err := json.Unmarshal(row.Payload, &p); err != nil {
			return fmt.Errorf("parse event-justified payload: %w", err)
		}
		if p.IDEquipment == 0 || p.IDEquipmentEvent == 0 {
			return fmt.Errorf("event-justified payload missing fields: %+v", p)
		}

		stagingEqID, err := t.Equipment(ctx, p.IDEquipment)
		if err != nil {
			return fmt.Errorf("translate equipment: %w", err)
		}
		stagingEventID, err := t.EquipmentEvent(ctx, p.IDEquipmentEvent)
		if err != nil {
			if errors.Is(err, translate.ErrUnmapped) {
				return fmt.Errorf("equipment_event %d unmapped (no staging row with >=%ds interval overlap; see WARN log): %w",
					p.IDEquipmentEvent, cfg.EventMinOverlapSec, err)
			}
			return fmt.Errorf("translate equipment_event: %w", err)
		}

		// Cache the equipment_event mapping after the first business-key
		// resolution so future event-edited / event-splitted on the same
		// prod event skip the matcher SELECT.
		if err := db.InsertMapping(ctx, tx, db.MapInsert{
			EntityType:  "equipment_event",
			Source:      cfg.SourceName,
			ProdID:      p.IDEquipmentEvent,
			StagingID:   stagingEventID,
			SourceLogID: row.IDUserLogs,
		}); err != nil {
			return fmt.Errorf("insert mapping: %w", err)
		}

		// Pass payload through verbatim, override the translated fields.
		// json.RawMessage round-trip preserves any extra fields prod sent.
		var raw map[string]any
		if err := json.Unmarshal(row.Payload, &raw); err != nil {
			return fmt.Errorf("re-parse payload: %w", err)
		}
		raw["idEquipment"] = stagingEqID
		raw["idEquipmentEvent"] = stagingEventID
		raw["idEnterprise"] = cfg.StagingEnterpriseID

		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/downtimes/justify", raw)
		if err != nil {
			return err
		}
		logger.Info("replayed event-justified",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodEventID", p.IDEquipmentEvent),
			slog.Int64("stagingEventID", stagingEventID),
			slog.Int("status", status))
		return nil
	}
}
