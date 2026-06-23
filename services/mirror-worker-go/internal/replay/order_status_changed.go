package replay

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/translate"
)

// OrderStatusChangedPayload mirrors the TS shape. Compared to TS, we
// have proper typed errors when fields are missing — Go's json.Unmarshal
// fails the whole struct rather than letting NaN propagate downstream.
type OrderStatusChangedPayload struct {
	IDEquipment       int   `json:"idEquipment"`
	IDProductionOrder int64 `json:"idProductionOrder"`
}

// OrderStatusChanged returns a Handler closure with the worker's deps
// captured. Same signature pattern for every category — see TS for the
// remaining 9 handlers; ports follow the same shape.
//
// MW-4: sends Idempotency-Key header derived from row.id_user_logs.
// Edge-api can ignore it today; honoring it later doesn't require a
// worker change.
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
			return fmt.Errorf("translate production_order: %w", err)
		}

		body := map[string]any{
			"idProductionOrder": stagingPOID,
			"idEquipment":       stagingEqID,
		}
		raw, _ := json.Marshal(body)

		nmUser := "mirror-worker-go"
		if row.NmUser != nil {
			nmUser = *row.NmUser
		}

		url := fmt.Sprintf("%s/api/production-orders/change-status?token=%s&idEnterprise=%d",
			cfg.StagingAPIBaseURL, apiToken(), cfg.StagingEnterpriseID)
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(raw))
		if err != nil {
			return fmt.Errorf("build request: %w", err)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("x-user", nmUser)
		req.Header.Set("X-Mirror-Source", cfg.SourceName)
		req.Header.Set("Idempotency-Key", fmt.Sprintf("%s/%d", cfg.SourceName, row.IDUserLogs))

		ctx2, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		req = req.WithContext(ctx2)

		resp, err := httpc.Do(req)
		if err != nil {
			return fmt.Errorf("POST change-status: %w", err)
		}
		defer resp.Body.Close()
		respBody, _ := io.ReadAll(resp.Body)
		if resp.StatusCode >= 400 {
			return fmt.Errorf("staging change-status returned %d: %s", resp.StatusCode, string(respBody))
		}

		logger.Info("replayed order-status-changed",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodPOID", p.IDProductionOrder),
			slog.Int64("stagingPOID", stagingPOID),
			slog.Int("status", resp.StatusCode),
		)
		return nil
	}
}
