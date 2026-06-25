package replay

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/translate"
)

// order-created-started — operator's "create + start in one shot" flow.
// Most important replay handler for closing Gap 1: new POs created via
// the operator's New PO button stay invisible to staging until this fires.
//
// Uses prod's timestamp directly. Faithful but may collide via edge-api's
// getOrderDateConflict against historical finished POs on the same equipment.
// Backfill scripts use a now-5s workaround; real-time replays of fresh prod
// actions don't have that problem (prod's ts_start is current).
type OrderCreatedStartedPayload struct {
	IDArea                  int         `json:"idArea"`
	IDSite                  int         `json:"idSite"`
	IDOrder                 json.Number `json:"idOrder"`
	Timestamp               string      `json:"timestamp"`
	IDEquipment             int         `json:"idEquipment"`
	ProductionOrderQuantity json.Number `json:"productionOrderQuantity"`
}

func OrderCreatedStarted(
	cfg *config.Config,
	t *translate.Translator,
	prodDB *db.Prod,
	stagingDB *db.Staging,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, tx pgx.Tx, row db.ProdUserLog) error {
		var p OrderCreatedStartedPayload
		if err := decodeWithNumbers(row.Payload, &p); err != nil {
			return fmt.Errorf("parse order-created-started payload: %w", err)
		}
		if p.IDEquipment == 0 || p.IDOrder == "" {
			return fmt.Errorf("order-created-started payload missing fields: %+v", p)
		}
		idOrderNum, err := p.IDOrder.Int64()
		if err != nil {
			return fmt.Errorf("idOrder not numeric: %w", err)
		}
		qty, err := p.ProductionOrderQuantity.Float64()
		if err != nil {
			return fmt.Errorf("productionOrderQuantity not numeric: %w", err)
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

		var prodPOIDStr string
		// ts_creation: see comment in order_created.go (same prod-vs-staging column drift).
		found, err := prodDB.SelectOne(ctx,
			`SELECT id_production_order::text FROM production_orders
			  WHERE id_enterprise = $1 AND id_order = $2
			    AND ts_creation >= $3::timestamptz - interval '1 minute'
			  ORDER BY id_production_order DESC LIMIT 1`,
			[]any{cfg.ProdEnterpriseID, idOrderNum, row.TsEvent}, &prodPOIDStr)
		if err != nil {
			return fmt.Errorf("prod PO lookup: %w", err)
		}
		if !found {
			return fmt.Errorf("no prod production_order for id_enterprise=%d id_order=%d", cfg.ProdEnterpriseID, idOrderNum)
		}
		prodPOID, err := parseBigint(prodPOIDStr)
		if err != nil {
			return fmt.Errorf("parse prod PO id: %w", err)
		}

		if existing, hit, err := stagingDB.LookupMapping(ctx, "production_order", cfg.SourceName, prodPOID); err != nil {
			return fmt.Errorf("mapping lookup: %w", err)
		} else if hit {
			logger.Info("order-created-started already mapped, skipping",
				slog.Int64("sourceLogID", row.IDUserLogs),
				slog.Int64("prodPOID", prodPOID),
				slog.Int64("stagingPOID", existing))
			return nil
		}

		body := map[string]any{
			"idEnterprise":            cfg.StagingEnterpriseID,
			"idSite":                  stagingSiteID,
			"idArea":                  stagingAreaID,
			"idEquipment":             stagingEqID,
			"idOrder":                 idOrderNum,
			"productionOrderQuantity": qty,
			"timestamp":               p.Timestamp,
		}
		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/production-orders/create-and-start", body)
		if err != nil {
			return err
		}

		var stagingPOIDStr string
		found, err = stagingDB.SelectOne(ctx,
			`SELECT id_production_order::text FROM production_orders
			  WHERE id_enterprise = $1 AND id_order = $2
			  ORDER BY id_production_order DESC LIMIT 1`,
			[]any{cfg.StagingEnterpriseID, idOrderNum}, &stagingPOIDStr)
		if err != nil {
			return fmt.Errorf("staging PO lookup: %w", err)
		}
		if !found {
			return fmt.Errorf("create-and-start returned %d but staging PO with id_order=%d not found", status, idOrderNum)
		}
		stagingPOID, err := parseBigint(stagingPOIDStr)
		if err != nil {
			return fmt.Errorf("parse staging PO id: %w", err)
		}

		if err := db.InsertMapping(ctx, tx, db.MapInsert{
			EntityType:  "production_order",
			Source:      cfg.SourceName,
			ProdID:      prodPOID,
			StagingID:   stagingPOID,
			SourceLogID: row.IDUserLogs,
		}); err != nil {
			return fmt.Errorf("insert mapping: %w", err)
		}

		logger.Info("replayed order-created-started",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodPOID", prodPOID),
			slog.Int64("stagingPOID", stagingPOID),
			slog.Int64("idOrder", idOrderNum),
			slog.Int("status", status))
		return nil
	}
}
