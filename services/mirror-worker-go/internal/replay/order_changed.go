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

// OrderChanged maps to POST /api/production-orders/stop (the operator's
// "change order" action stops the current PO; setup of the new one is a
// separate user_logs row). The DTO ignores the extra payload fields prod
// sends (shouldCreatePo etc.) — class-validator default behavior.
type OrderChangedPayload struct {
	StopType                string      `json:"stopType"`
	Timestamp               string      `json:"timestamp"`
	IDEquipment             int         `json:"idEquipment"`
	OldIDProductionOrder    int64       `json:"oldIdProductionOrder"`
	ProductionOrderQuantity json.Number `json:"productionOrderQuantity"`
}

func OrderChanged(
	cfg *config.Config,
	t *translate.Translator,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, _ pgx.Tx, row db.ProdUserLog) error {
		var p OrderChangedPayload
		if err := decodeWithNumbers(row.Payload, &p); err != nil {
			return fmt.Errorf("parse order-changed payload: %w", err)
		}
		if p.IDEquipment == 0 || p.OldIDProductionOrder == 0 || p.StopType == "" {
			return fmt.Errorf("order-changed payload missing fields: %+v", p)
		}
		qty, _ := p.ProductionOrderQuantity.Float64()

		stagingEqID, err := t.Equipment(ctx, p.IDEquipment)
		if err != nil {
			return fmt.Errorf("translate equipment: %w", err)
		}
		stagingPOID, err := t.ProductionOrder(ctx, p.OldIDProductionOrder)
		if err != nil {
			if errors.Is(err, translate.ErrUnmapped) {
				return fmt.Errorf("production_order %d unmapped (no mirror_id_map row and no id_order business-key match — run backfill-pos): %w",
					p.OldIDProductionOrder, err)
			}
			return fmt.Errorf("translate production_order: %w", err)
		}

		body := map[string]any{
			"timestamp":               p.Timestamp,
			"stopType":                p.StopType,
			"idEnterprise":            cfg.StagingEnterpriseID,
			"idEquipment":             stagingEqID,
			"idProductionOrder":       stagingPOID,
			"productionOrderQuantity": qty,
		}
		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/production-orders/stop", body)
		if err != nil {
			return err
		}
		logger.Info("replayed order-changed",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodPOID", p.OldIDProductionOrder),
			slog.Int64("stagingPOID", stagingPOID),
			slog.String("stopType", p.StopType),
			slog.Int("status", status))
		return nil
	}
}
