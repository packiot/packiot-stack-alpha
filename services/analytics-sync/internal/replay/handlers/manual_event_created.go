package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/analytics-sync/internal/replay"
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
// ID PRESERVATION: equipment_events_man's PK on packiot.public is
// (ts_event) — globally unique — so the Flow 1 surrogate id is
// resolvable by exact PK lookup at replay time. Shadow rows are
// inserted WITH Flow 1's id_equipment_event, which makes
// manual-event-edited's UPDATE-by-id work unchanged on the shadow
// paths (the bug-248 id-space problem, solved here by copying the id
// instead of natural-key rewrites — events have no other natural key
// once ts_event itself is edited).
//
// Idempotency: ON CONFLICT (id_equipment, ts_event) DO NOTHING — ts_event is unique
// in Flow 1 by PK, so a conflict only means cursor re-replay. The
// target is qualified deliberately (bug 247): any other constraint
// violation must fail loudly.
//
// Fail-open on missing tables (SQLSTATE 42P01) — logs a warn and
// continues so shadow-mirror doesn't jam when the operator hasn't yet
// provisioned equipment_events_man in the shadow schemas. Once the
// tables exist, the handler starts inserting on the next event.
func ManualEventCreated(logger *slog.Logger) replay.Handler {
	return func(ctx context.Context, mainPool, analyticsPool *pgxpool.Pool, u *replay.UserLog) error {
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

		flow1ID, found, err := resolveEventID(ctx, mainPool, tsEvent)
		if err != nil {
			return fmt.Errorf("resolve event id: %w", err)
		}
		if !found {
			// Flow 1 row gone — only happens when ts_event was already
			// edited before the cursor caught up (edge-api writes the row
			// before logging). Skip: an unmapped stray row could never be
			// edited and would poison ts_event-keyed idempotency.
			logger.Warn("manual-event-created: Flow 1 event not found by ts_event — skipping",
				slog.Int64("id_user_log", u.ID),
				slog.Time("ts_event", tsEvent))
			return replay.ErrSkip
		}

		// Path 1: shadow_go_port on main pool
		if err := insertManualEvent(ctx, mainPool, "shadow_go_port", &p, flow1ID, tsEvent, tsEnd, u.ID, logger); err != nil {
			return fmt.Errorf("shadow_go_port write: %w", err)
		}

		// Path 2: public on shadow pool (may be nil = disabled)
		if analyticsPool != nil {
			if err := insertManualEvent(ctx, analyticsPool, "public", &p, flow1ID, tsEvent, tsEnd, u.ID, logger); err != nil {
				return fmt.Errorf("packiot_analytics write: %w", err)
			}
		}
		return nil
	}
}

const sqlInsertManualEvent = `INSERT INTO %s.equipment_events_man (
	    id_equipment_event,
	    id_equipment, id_enterprise, ts_event, ts_end, duration,
	    cd_machine, cd_category, cd_subcategory,
	    desc_category, desc_subcategory,
	    txt_downtime_notes,
	    forced_creation_system, last_update
	) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, true, now())
	  ON CONFLICT (id_equipment, ts_event) DO NOTHING`

// insertManualEvent is the shared INSERT builder for both shadow paths.
// The row carries Flow 1's id_equipment_event so edits-by-id resolve.
// Fail-open on 42P01 (relation does not exist) — logs a warn and
// returns nil so the cursor advances.
func insertManualEvent(ctx context.Context, pool *pgxpool.Pool, schema string, p *ManualEventCreatedPayload, flow1ID int64, tsEvent time.Time, tsEnd *time.Time, userLogID int64, logger *slog.Logger) error {
	sql := fmt.Sprintf(sqlInsertManualEvent, schema)
	_, err := pool.Exec(ctx, sql,
		flow1ID,
		p.IDEquipment, p.IDEnterprise, tsEvent, tsEnd, p.Duration,
		p.CdMachine, p.CdCategory, p.CdSubcategory,
		p.DescCategory, p.DescSubcategory,
		p.TxtDowntimeNotes,
	)
	return failOpenIfMissing(err, "equipment_events_man", schema, userLogID, logger)
}
