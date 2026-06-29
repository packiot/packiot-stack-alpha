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

// OrderStopped — same endpoint as order-changed but with the prod payload
// shape that explicitly carries idProductionOrder (rather than the
// oldIdProductionOrder used by order-changed's setup-flow encoding).
type OrderStoppedPayload struct {
	Timestamp               string      `json:"timestamp"`
	StopType                string      `json:"stopType"`
	IDEquipment             int         `json:"idEquipment"`
	IDProductionOrder       int64       `json:"idProductionOrder"`
	ProductionOrderQuantity json.Number `json:"productionOrderQuantity"`
}

func OrderStopped(
	cfg *config.Config,
	t *translate.Translator,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, _ pgx.Tx, row db.ProdUserLog) error {
		var p OrderStoppedPayload
		if err := decodeWithNumbers(row.Payload, &p); err != nil {
			return fmt.Errorf("parse order-stopped payload: %w", err)
		}
		if p.IDEquipment == 0 || p.IDProductionOrder == 0 {
			return fmt.Errorf("order-stopped payload missing fields: %+v", p)
		}
		qty, _ := p.ProductionOrderQuantity.Float64()

		stagingEqID, err := t.Equipment(ctx, p.IDEquipment)
		if err != nil {
			return fmt.Errorf("translate equipment: %w", err)
		}
		stagingPOID, err := t.ProductionOrder(ctx, p.IDProductionOrder)
		if err != nil {
			if errors.Is(err, translate.ErrUnmapped) {
				// Same structural-mismatch shape as order-changed / order-started:
				// the PO exists on prod but was never mirrored to staging. No
				// retry will fix this; skip + advance cursor instead of DLQ.
				logger.Info("skipping order-stopped: production_order unmappable on staging",
					slog.Int64("sourceLogID", row.IDUserLogs),
					slog.Int64("prodPOID", p.IDProductionOrder),
					slog.String("translatorErr", err.Error()))
				return fmt.Errorf("production_order %d unmapped (no mirror_id_map row and no id_order business-key match): %w",
					p.IDProductionOrder, ErrSkipReplay)
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
		logger.Info("replayed order-stopped",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodPOID", p.IDProductionOrder),
			slog.Int64("stagingPOID", stagingPOID),
			slog.String("stopType", p.StopType),
			slog.Int("status", status))
		return nil
	}
}
