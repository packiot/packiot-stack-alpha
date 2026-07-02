// Package handlers holds per-category shadow-mirror handlers.
//
// Phase 1 (this session): one placeholder handler for
// `manual-event-created`. Logs the intent + calls the metric hook, but
// executes zero SQL — so the service can be safely deployed and
// observed without touching shadow DBs yet.
//
// Phase 2 (future sessions): flesh out real handlers per ADR-0013.
package handlers

import (
	"context"
	"encoding/json"
	"log/slog"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/shadow-mirror/internal/replay"
)

// ManualEventCreatedPlaceholder decodes the payload and logs what it
// WOULD do — no writes yet. This lets the service be deployed + observed
// end-to-end (poll runs, dispatcher fires, handler ack + metric emission
// all exercised) without any risk to the shadow DBs.
//
// When the real handler lands, replace the log call with the actual
// INSERT SQL and remove the "placeholder" note.
func ManualEventCreatedPlaceholder(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, shadowPool *pgxpool.Pool, u *replay.UserLog) error {
		// Decode enough of the payload to log the intent — the real
		// handler will use the fields directly.
		var p struct {
			IDEquipment  int    `json:"idEquipment"`
			CdMachine    string `json:"cdMachine"`
			CdCategory   string `json:"cdCategory"`
			DescCategory string `json:"descCategory"`
			Duration     int    `json:"duration"`
		}
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			// Malformed payload — skip rather than DLQ. Bad log
			// entries shouldn't jam the cursor.
			logger.Warn("manual-event-created: payload unmarshal failed — skipping",
				slog.Int64("id_user_log", u.ID),
				slog.String("err", err.Error()))
			return replay.ErrSkip
		}
		hasShadow := shadowPool != nil
		logger.Info("manual-event-created: would replay to shadow paths (Phase 1 placeholder — no writes)",
			slog.Int64("id_user_log", u.ID),
			slog.Int("id_equipment", p.IDEquipment),
			slog.String("cd_machine", p.CdMachine),
			slog.String("cd_category", p.CdCategory),
			slog.Int("duration", p.Duration),
			slog.Bool("shadow_pool_configured", hasShadow),
		)
		return nil
	}
}
