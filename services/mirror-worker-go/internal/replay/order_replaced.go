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

type OrderReplacedPayload struct {
	IDEquipment       int   `json:"idEquipment"`
	IDProductionOrder int64 `json:"idProductionOrder"`
}

// OrderReplaced — swap the current running PO with a different pre-existing
// one (distinct from create-and-start which makes a new PO).
func OrderReplaced(
	cfg *config.Config,
	t *translate.Translator,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, _ pgx.Tx, row db.ProdUserLog) error {
		var p OrderReplacedPayload
		if err := json.Unmarshal(row.Payload, &p); err != nil {
			return fmt.Errorf("parse order-replaced payload: %w", err)
		}
		if p.IDEquipment == 0 || p.IDProductionOrder == 0 {
			return fmt.Errorf("order-replaced payload missing fields: %+v", p)
		}

		stagingEqID, err := t.Equipment(ctx, p.IDEquipment)
		if err != nil {
			return fmt.Errorf("translate equipment: %w", err)
		}
		stagingPOID, err := t.ProductionOrder(ctx, p.IDProductionOrder)
		if err != nil {
			if errors.Is(err, translate.ErrUnmapped) {
				// Same structural-mismatch shape as order-changed: the PO
				// exists on prod but was never mirrored to staging. No
				// retry will fix it; skip + advance cursor instead of DLQ.
				logger.Info("skipping order-replaced: production_order unmappable on staging",
					slog.Int64("sourceLogID", row.IDUserLogs),
					slog.Int64("prodPOID", p.IDProductionOrder),
					slog.String("translatorErr", err.Error()))
				return fmt.Errorf("production_order %d unmapped (no mirror_id_map row and no id_order business-key match): %w",
					p.IDProductionOrder, ErrSkipReplay)
			}
			return fmt.Errorf("translate production_order: %w", err)
		}

		body := map[string]any{
			"idEnterprise":      cfg.StagingEnterpriseID,
			"idEquipment":       stagingEqID,
			"idProductionOrder": stagingPOID,
		}
		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/production-orders/replace", body)
		if err != nil {
			return err
		}
		logger.Info("replayed order-replaced",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodPOID", p.IDProductionOrder),
			slog.Int64("stagingPOID", stagingPOID),
			slog.Int("status", status))
		return nil
	}
}
