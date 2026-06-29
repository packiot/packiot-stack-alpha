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

type OrderStatusChangedPayload struct {
	IDEquipment       int   `json:"idEquipment"`
	IDProductionOrder int64 `json:"idProductionOrder"`
}

func OrderStatusChanged(
	cfg *config.Config,
	t *translate.Translator,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, _ pgx.Tx, row db.ProdUserLog) error {
		var p OrderStatusChangedPayload
		if err := json.Unmarshal(row.Payload, &p); err != nil {
			return fmt.Errorf("parse order-status-changed payload: %w", err)
		}
		if p.IDEquipment == 0 || p.IDProductionOrder == 0 {
			return fmt.Errorf("order-status-changed payload missing fields: %+v", p)
		}

		stagingEqID, err := t.Equipment(ctx, p.IDEquipment)
		if err != nil {
			return fmt.Errorf("translate equipment: %w", err)
		}
		stagingPOID, err := t.ProductionOrder(ctx, p.IDProductionOrder)
		if err != nil {
			if errors.Is(err, translate.ErrUnmapped) {
				// Same structural-mismatch shape as order-changed / order-started /
				// order-stopped: the PO exists on prod but was never mirrored to
				// staging. No retry will fix this; skip + advance cursor instead
				// of DLQ. Without this branch, every order-status-changed for an
				// unmapped prod PO would land in DLQ as a "translate production_order"
				// failure that retries 5 times and gets permanently stuck — same
				// failure mode that DLQ #316 hit for order-started.
				logger.Info("skipping order-status-changed: production_order unmappable on staging",
					slog.Int64("sourceLogID", row.IDUserLogs),
					slog.Int64("prodPOID", p.IDProductionOrder),
					slog.String("translatorErr", err.Error()))
				return fmt.Errorf("production_order %d unmapped (no mirror_id_map row and no id_order business-key match): %w",
					p.IDProductionOrder, ErrSkipReplay)
			}
			return fmt.Errorf("translate production_order: %w", err)
		}

		body := map[string]any{
			"idProductionOrder": stagingPOID,
			"idEquipment":       stagingEqID,
		}
		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/production-orders/change-status", body)
		if err != nil {
			return err
		}
		logger.Info("replayed order-status-changed",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodPOID", p.IDProductionOrder),
			slog.Int64("stagingPOID", stagingPOID),
			slog.Int("status", status),
		)
		return nil
	}
}
