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

// DowntimeEventCreated — replays the operator action that the
// staging/prod edge-api logs under category=`downtime-event-created`.
//
// The matching controller (`POST /api/downtimes`, body validated against
// `UpsertDowntimeDto`) receives an `events: []` array. Each event has:
//
//	{
//	  "topic":       "C-PACK/.../Status/StateCurrent",
//	  "status":      6 | 10,         // running | stopped (Status enum)
//	  "timestamp":   <ms epoch>,
//	  "idEquipment": <prod equipment id>
//	}
//
// Prod sample (id_user_logs=2501637 on 2026-06-24, taken via SSM):
//
//	{"events":[{"topic":"C-PACK/SC/LINHAS/L10/DXL/Status/StateCurrent",
//	            "status":10,"timestamp":1782333900000,"idEquipment":564}]}
//
// Translation: each event's idEquipment goes through Translator.Equipment;
// the topic gets RemapTopic (purely cosmetic — staging's upsert.service.ts
// ignores `topic` and only uses idEquipment + timestamp + status — but we
// remap anyway so DB-side audit logs and any future server that DOES look
// at topic stay consistent).
//
// idEnterprise is appended as a query param by PostStaging.
//
// Single staging POST per user_logs row, even when prod batched multiple
// events into one payload — mirrors what the operator originally did.

type downtimeEvent struct {
	Topic       string `json:"topic"`
	Status      int    `json:"status"`
	Timestamp   int64  `json:"timestamp"`
	IDEquipment int    `json:"idEquipment"`
}

// DowntimeEventCreatedPayload mirrors UpsertDowntimeDto's shape.
type DowntimeEventCreatedPayload struct {
	Events []downtimeEvent `json:"events"`
}

func DowntimeEventCreated(
	cfg *config.Config,
	t *translate.Translator,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) Handler {
	return func(ctx context.Context, _ pgx.Tx, row db.ProdUserLog) error {
		var p DowntimeEventCreatedPayload
		if err := json.Unmarshal(row.Payload, &p); err != nil {
			return fmt.Errorf("parse downtime-event-created payload: %w", err)
		}
		if len(p.Events) == 0 {
			return fmt.Errorf("downtime-event-created payload missing events array: %s", string(row.Payload))
		}

		// Translate each event's idEquipment + topic. We keep the same
		// shape on the wire — translating in place via a fresh slice so a
		// malformed event in the middle of the batch surfaces as a clear
		// error instead of partially-mutating the original.
		translated := make([]map[string]any, 0, len(p.Events))
		for i, e := range p.Events {
			if e.IDEquipment == 0 || e.Status == 0 || e.Timestamp == 0 {
				return fmt.Errorf("downtime-event-created event[%d] missing fields: %+v", i, e)
			}
			stagingEqID, err := t.Equipment(ctx, e.IDEquipment)
			if err != nil {
				if errors.Is(err, translate.ErrUnmapped) {
					// The topic isn't on staging's packml_register — most
					// commonly because the prod packml_topic has bogus
					// content an upstream edge-nodered emits (e.g. the
					// LLLLL-prefix bursts we see in prod). Fixing that is
					// not this worker's job; record outcome=skipped and
					// keep it out of mirror_replay_dlq. Match the existing
					// fail-fast style: ANY unmappable event in the batch
					// skips the whole row (consistent with how a malformed
					// event aborts the whole row).
					logger.Info("skipping downtime-event-created: equipment unmappable on staging",
						slog.Int64("sourceLogID", row.IDUserLogs),
						slog.Int("eventIndex", i),
						slog.Int("prodEquipmentID", e.IDEquipment),
						slog.String("prodTopic", e.Topic),
						slog.String("translatorErr", err.Error()))
					return fmt.Errorf("event[%d] equipment %d unmapped on staging: %w", i, e.IDEquipment, ErrSkipReplay)
				}
				return fmt.Errorf("translate equipment for event[%d]: %w", i, err)
			}
			translated = append(translated, map[string]any{
				"topic":       translate.RemapTopic(e.Topic),
				"status":      e.Status,
				"timestamp":   e.Timestamp,
				"idEquipment": stagingEqID,
			})
		}

		body := map[string]any{"events": translated}

		status, _, err := PostStaging(ctx, cfg, httpc, apiToken(), row,
			"/api/downtimes", body)
		if err != nil {
			return err
		}
		logger.Info("replayed downtime-event-created",
			slog.Int64("sourceLogID", row.IDUserLogs),
			slog.Int("eventCount", len(translated)),
			slog.Int("status", status),
		)
		return nil
	}
}
