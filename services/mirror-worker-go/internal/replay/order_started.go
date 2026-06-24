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

type OrderStartedPayload struct {
	IDArea            int    `json:"idArea"`
	IDSite            int    `json:"idSite"`
	Timestamp         string `json:"timestamp"`
	IDEquipment       int    `json:"idEquipment"`
	IDProductionOrder int64  `json:"idProductionOrder"`
}

// OrderStarted: replay /api/production-orders/start. Requires PO to be
// already mapped (via backfill or prior order-created/order-created-started
// replay) — translateProductionOrder returns ErrUnmapped otherwise.
func OrderStarted(
	cfg *config.Config,
	t *translate.Translator,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, _ pgx.Tx, row db.ProdUserLog) error {
		var p OrderStartedPayload
		if err := json.Unmarshal(row.Payload, &p); err != nil {
			return fmt.Errorf("parse order-started payload: %w", err)
		}
		if p.IDEquipment == 0 || p.IDProductionOrder == 0 {
			return fmt.Errorf("order-started payload missing fields: %+v", p)
		}

		stagingEqID, err := t.Equipment(ctx, p.IDEquipment)
		if err != nil {
			return fmt.Errorf("translate equipment: %w", err)
		}
		stagingSiteID, err := t.Site(ctx, p.IDSite)
		if err != nil {
			return fmt.Errorf("translate site: %w", err)
		}
		stagingAreaID, err := t.Area(ctx, p.IDArea)
		if err != nil {
			return fmt.Errorf("translate area: %w", err)
		}
		stagingPOID, err := t.ProductionOrder(ctx, p.IDProductionOrder)
		if err != nil {
			if errors.Is(err, translate.ErrUnmapped) {
				return fmt.Errorf("production_order %d unmapped (run backfill-pos or replay order-created/order-created-started first): %w",
					p.IDProductionOrder, err)
			}
			return fmt.Errorf("translate production_order: %w", err)
		}

		body := map[string]any{
			"timestamp":         p.Timestamp,
			"idEnterprise":      cfg.StagingEnterpriseID,
			"idSite":            stagingSiteID,
			"idArea":            stagingAreaID,
			"idEquipment":       stagingEqID,
			"idProductionOrder": stagingPOID,
		}
		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/production-orders/start", body)
		if err != nil {
			return err
		}
		logger.Info("replayed order-started",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodPOID", p.IDProductionOrder),
			slog.Int64("stagingPOID", stagingPOID),
			slog.Int("status", status))
		return nil
	}
}
