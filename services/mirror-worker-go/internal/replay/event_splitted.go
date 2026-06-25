package replay

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/translate"
)

type SplitPayload struct {
	Events           []any  `json:"events"`
	EventType        string `json:"eventType"`
	IDEquipment      int    `json:"idEquipment"`
	IDEquipmentEvent int64  `json:"idEquipmentEvent"`
}

// stagingISOFormat matches JS `new Date(...).toISOString()` — split.service.ts
// runs that conversion on both sides of its equality check, so the layout we
// send needs to round-trip through it cleanly. Millisecond precision, UTC.
const stagingISOFormat = "2006-01-02T15:04:05.000Z"

// EventSplitted replays an operator split. The operator's payload carries
// THEIR timestamps — first event start = original event start, last event
// end = original event end. split.service.ts validates those equalities
// strictly against the staging row's ts_event/ts_end. Because prod runs
// CPAC 5-min smoothing while staging carries raw PLC transitions, prod's
// boundaries don't always match staging's boundaries even when the matcher
// correctly identifies the same physical event — yielding 400s like DLQ id
// 282 (prod start 2026-06-22 17:06, staging start 2026-06-22 20:41:07, same
// end 2026-06-25 06:54).
//
// Fix: rewrite events[0].startTime and events[N-1].endTime to staging's
// boundaries before sending. Operator's interior split points (the actual
// annotation transitions they care about) pass through unchanged. If staging
// is still open (ts_end IS NULL), leave the operator's endTime as-is —
// staging will close the event at that timestamp (see edge-api PR #130).
func EventSplitted(
	cfg *config.Config,
	t *translate.Translator,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, tx pgx.Tx, row db.ProdUserLog) error {
		var p SplitPayload
		if err := json.Unmarshal(row.Payload, &p); err != nil {
			return fmt.Errorf("parse event-splitted payload: %w", err)
		}
		if p.IDEquipment == 0 || p.IDEquipmentEvent == 0 || p.EventType == "" {
			return fmt.Errorf("event-splitted payload missing fields: %+v", p)
		}
		if len(p.Events) == 0 {
			return fmt.Errorf("event-splitted payload missing non-empty events array")
		}

		stagingEqID, err := t.Equipment(ctx, p.IDEquipment)
		if err != nil {
			return fmt.Errorf("translate equipment: %w", err)
		}
		stagingEventID, err := t.EquipmentEvent(ctx, p.IDEquipmentEvent)
		if err != nil {
			if errors.Is(err, translate.ErrUnmapped) {
				return fmt.Errorf("equipment_event %d unmapped (no staging interval overlap; see WARN log): %w",
					p.IDEquipmentEvent, err)
			}
			return fmt.Errorf("translate equipment_event: %w", err)
		}

		if err := db.InsertMapping(ctx, tx, db.MapInsert{
			EntityType:  "equipment_event",
			Source:      cfg.SourceName,
			ProdID:      p.IDEquipmentEvent,
			StagingID:   stagingEventID,
			SourceLogID: row.IDUserLogs,
		}); err != nil {
			return fmt.Errorf("insert mapping: %w", err)
		}

		stagingTsEvent, stagingTsEnd, err := t.EquipmentEventBoundaries(ctx, stagingEventID)
		if err != nil {
			return fmt.Errorf("read staging boundaries: %w", err)
		}
		startDriftSec, endDriftSec := alignSplitEventsToStaging(p.Events, stagingTsEvent, stagingTsEnd)

		body := map[string]any{
			"idEquipment":      stagingEqID,
			"idEquipmentEvent": stagingEventID,
			"eventType":        p.EventType,
			"events":           p.Events,
		}
		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/downtimes/split", body)
		if err != nil {
			return err
		}
		logger.Info("replayed event-splitted",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int64("prodEventID", p.IDEquipmentEvent),
			slog.Int64("stagingEventID", stagingEventID),
			slog.Int("splitInto", len(p.Events)),
			slog.Int("startDriftSec", startDriftSec),
			slog.Int("endDriftSec", endDriftSec),
			slog.Int("status", status))
		return nil
	}
}

// alignSplitEventsToStaging mutates events[0].startTime to stagingTsEvent
// and (when stagingTsEnd is non-null) events[N-1].endTime to stagingTsEnd.
// Returns the drift in seconds for log diagnostics — large drift indicates
// the matcher chose a staging event with significantly different boundaries
// than prod's, which is informational but not actionable (the match is
// valid; the boundaries simply differ).
//
// Type assertions are best-effort: if events[i] isn't a JSON object after
// decode (shouldn't happen for real payloads but might for malformed ones),
// we skip the rewrite for that element and let staging reject the original.
func alignSplitEventsToStaging(events []any, stagingTsEvent time.Time, stagingTsEnd sql.NullTime) (startDriftSec, endDriftSec int) {
	first, ok := events[0].(map[string]any)
	if !ok {
		return 0, 0
	}
	if prev, ok := first["startTime"].(string); ok {
		if t, err := time.Parse(time.RFC3339Nano, prev); err == nil {
			startDriftSec = int(stagingTsEvent.Sub(t).Seconds())
		}
	}
	first["startTime"] = stagingTsEvent.UTC().Format(stagingISOFormat)

	if !stagingTsEnd.Valid {
		return startDriftSec, 0
	}
	last, ok := events[len(events)-1].(map[string]any)
	if !ok {
		return startDriftSec, 0
	}
	if prev, ok := last["endTime"].(string); ok {
		if t, err := time.Parse(time.RFC3339Nano, prev); err == nil {
			endDriftSec = int(stagingTsEnd.Time.Sub(t).Seconds())
		}
	}
	last["endTime"] = stagingTsEnd.Time.UTC().Format(stagingISOFormat)
	return startDriftSec, endDriftSec
}
