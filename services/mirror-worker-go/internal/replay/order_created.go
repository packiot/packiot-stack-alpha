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

// OrderCreatedPayload — prod payload is wider than these fields (also
// equipmentSetup, unitMultiplier, idEnterprise); we only need what staging's
// CreateProductionOrderDto wants. idOrder is `number | string` in prod —
// json.Number handles both without losing precision.
type OrderCreatedPayload struct {
	IDArea                  int         `json:"idArea"`
	IDSite                  int         `json:"idSite"`
	IDOrder                 json.Number `json:"idOrder"`
	IDEquipment             int         `json:"idEquipment"`
	ProductionOrderQuantity json.Number `json:"productionOrderQuantity"`
}

// OrderCreated: replay /api/production-orders/create then resolve the
// resulting prod PO + staging PO and persist the mapping. Same shape as
// order-created-started, only differs by endpoint + body.
//
// Idempotency: prod payload doesn't carry id_production_order, so we look
// it up post-hoc via (id_enterprise, id_order, ts_creation >= ts_event - 1m).
// If a mapping row already exists for that prod PO id, skip.
func OrderCreated(
	cfg *config.Config,
	t *translate.Translator,
	prodDB *db.Prod,
	stagingDB *db.Staging,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, tx pgx.Tx, row db.ProdUserLog) error {
		var p OrderCreatedPayload
		if err := decodeWithNumbers(row.Payload, &p); err != nil {
			return fmt.Errorf("parse order-created payload: %w", err)
		}
		if p.IDEquipment == 0 || p.IDOrder == "" {
			return fmt.Errorf("order-created payload missing fields: %+v", p)
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

		// Find the prod PO we're mirroring — most recent one matching
		// (enterprise, id_order) created near this user_logs row.
		var prodPOIDStr string
		// ts_creation: prod's production_orders has no created_at column
		// (SQLSTATE 42703 in DLQ id 284).
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

		// Already mapped? Skip — idempotent re-run.
		if existing, hit, err := stagingDB.LookupMapping(ctx, "production_order", cfg.SourceName, prodPOID); err != nil {
			return fmt.Errorf("mapping lookup: %w", err)
		} else if hit {
			logger.Info("order-created already mapped, skipping",
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
		}
		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/production-orders/create", body)
		if err != nil {
			return err
		}

		// Resolve the staging PO just created.
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
			return fmt.Errorf("create returned %d but staging PO with id_order=%d not found", status, idOrderNum)
		}
		stagingPOID, err := parseBigint(stagingPOIDStr)
		if err != nil {
			return fmt.Errorf("parse staging PO id: %w", err)
		}

		// Insert via the per-row tx — atomic with cursor advance done by
		// processRow. The TS code originally opened a SECOND tx here
		// (see 7e5b0bf for the bug it caused); the Go port skips that
		// trap by reusing the outer tx.
		if err := db.InsertMapping(ctx, tx, db.MapInsert{
			EntityType:  "production_order",
			Source:      cfg.SourceName,
			ProdID:      prodPOID,
			StagingID:   stagingPOID,
			SourceLogID: row.IDUserLogs,
		}); err != nil {
			return fmt.Errorf("insert mapping: %w", err)
		}

		logger.Info("replayed order-created",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodPOID", prodPOID),
			slog.Int64("stagingPOID", stagingPOID),
			slog.Int64("idOrder", idOrderNum),
			slog.Int("status", status))
		return nil
	}
}
