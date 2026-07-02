package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/shadow-mirror/internal/replay"
)

// ManualEventCreatedPayload is the JSON shape emitted by staging
// edge-api for user_logs.category = 'manual-event-created'.
//
// Confirmed against 2026-07-01 staging entries (sampled via
// SELECT payload FROM user_logs WHERE category='manual-event-created').
type ManualEventCreatedPayload struct {
	IDEquipment      int    `json:"idEquipment"`
	IDEnterprise     int    `json:"idEnterprise"`
	TsEvent          string `json:"tsEvent"` // ISO-8601 UTC
	TsEnd            string `json:"tsEnd"`
	Duration         int    `json:"duration"`
	CdMachine        string `json:"cdMachine"`
	CdCategory       string `json:"cdCategory"`
	CdSubcategory    string `json:"cdSubcategory"`
	DescCategory     string `json:"descCategory"`
	DescSubcategory  string `json:"descSubcategory"`
	TxtDowntimeNotes string `json:"txtDowntimeNotes"`
}

// ManualEventCreated is the Phase 2 replacement for the Phase 1
// placeholder. It parses the payload and INSERTs a row into
// equipment_events_man in BOTH shadow paths.
//
// forced_creation_system=true bypasses the piot_trig_equipment_events
// dedup trigger — same posture as mirror-worker's events reconciler
// (see PR #76 discussion in memory).
//
// Idempotency: ON CONFLICT DO NOTHING keyed on
// (id_equipment, ts_event, cd_machine) — a triple that's stable across
// replays. If the row already exists (repeated cursor iteration or
// replay from resume), the INSERT is a no-op.
//
// Fail-open on missing tables (SQLSTATE 42P01) — logs a warn and
// continues so shadow-mirror doesn't jam when the operator hasn't yet
// provisioned equipment_events_man in the shadow schemas. Once the
// tables exist, the handler starts inserting on the next event.
func ManualEventCreated(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, shadowPool *pgxpool.Pool, u *replay.UserLog) error {
		var p ManualEventCreatedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			logger.Warn("manual-event-created: payload unmarshal failed — skipping",
				slog.Int64("id_user_log", u.ID),
				slog.String("err", err.Error()))
			return replay.ErrSkip
		}
		if p.IDEquipment == 0 || p.TsEvent == "" {
			logger.Warn("manual-event-created: missing idEquipment or tsEvent — skipping",
				slog.Int64("id_user_log", u.ID))
			return replay.ErrSkip
		}
		tsEvent, err := time.Parse(time.RFC3339, p.TsEvent)
		if err != nil {
			logger.Warn("manual-event-created: tsEvent parse failed — skipping",
				slog.Int64("id_user_log", u.ID),
				slog.String("ts_event_raw", p.TsEvent),
				slog.String("err", err.Error()))
			return replay.ErrSkip
		}
		var tsEnd *time.Time
		if p.TsEnd != "" {
			if t, err := time.Parse(time.RFC3339, p.TsEnd); err == nil {
				tsEnd = &t
			}
		}

		// Path 1: shadow_go_port on main pool
		if err := insertManualEvent(ctx, mainPool, "shadow_go_port", &p, tsEvent, tsEnd, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port write: %w", err)
		}

		// Path 2: public on shadow pool (may be nil = disabled)
		if shadowPool != nil {
			if err := insertManualEvent(ctx, shadowPool, "public", &p, tsEvent, tsEnd, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_shadow write: %w", err)
			}
		}
		return nil
	}
}

// insertManualEvent is the shared INSERT builder for both shadow paths.
// Fail-open on 42P01 (relation does not exist) — logs a warn and
// returns nil so the cursor advances.
func insertManualEvent(ctx context.Context, pool *pgxpool.Pool, schema string, p *ManualEventCreatedPayload, tsEvent time.Time, tsEnd *time.Time, userLogID int64, logger *slog.Logger) error {
	const sqlTpl = `INSERT INTO %s.equipment_events_man (
	    id_equipment, id_enterprise, ts_event, ts_end, duration,
	    cd_machine, cd_category, cd_subcategory,
	    desc_category, desc_subcategory,
	    txt_downtime_notes,
	    forced_creation_system, last_update
	) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, true, now())
	  ON CONFLICT DO NOTHING`
	sql := fmt.Sprintf(sqlTpl, schema)
	_, err := pool.Exec(ctx, sql,
		p.IDEquipment, p.IDEnterprise, tsEvent, tsEnd, p.Duration,
		p.CdMachine, p.CdCategory, p.CdSubcategory,
		p.DescCategory, p.DescSubcategory,
		p.TxtDowntimeNotes,
	)
	return failOpenIfMissing(err, "equipment_events_man", schema, userLogID, logger)
}
