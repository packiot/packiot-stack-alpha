package handlers

import (
	"context"
	"log/slog"
	"sync/atomic"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/writers"
	amqp "github.com/rabbitmq/amqp091-go"
)

// SparkplugHandler is the top-level handler for routing-key "sparkplug.data".
//
// Per-AMQP-message flow:
//   1. Parse JSON payload (sparkplug.Parse)
//   2. For each metric:
//      - Classify by name (sparkplug.Metric.Classify)
//      - Route to the right writer based on kind
//      - Unknown kinds: log + skip (don't fail the whole batch)
//   3. If ANY write returned an error, return the FIRST one — consumer nacks
//      to DLX → retry. Successful writes earlier in the batch are idempotent
//      (UPSERT on (ts_value, id_equipment)) so re-processing is safe.
//
// Currently only the EquipmentValues writer is wired. Adding more writers
// (equipment_events, uns_metrics, PO parameters) is a single line each:
//
//	if h.equipmentEvents.CanWrite(kind) { … }
//
// Counters expose per-kind activity via metrics for /health expansion later.
type SparkplugHandler struct {
	parsed      atomic.Uint64
	written     atomic.Uint64
	skippedUnk  atomic.Uint64
	writeErrors atomic.Uint64

	equipmentValues *writers.EquipmentValues
	unsMetrics      *writers.UnsMetrics
	logger          *slog.Logger
}

func NewSparkplugHandler(
	ev *writers.EquipmentValues,
	uns *writers.UnsMetrics,
	logger *slog.Logger,
) *SparkplugHandler {
	return &SparkplugHandler{
		equipmentValues: ev,
		unsMetrics:      uns,
		logger:          logger,
	}
}

// Handle is the Handler signature consumed by Dispatcher.
func (h *SparkplugHandler) Handle(ctx context.Context, d *amqp.Delivery) error {
	p, err := sparkplug.Parse(d.Body)
	if err != nil {
		// Bad JSON is terminal — return error so the consumer nacks; after
		// MaxRetries the message lands in oee-failed for inspection. The
		// retry won't fix the parse, but the retry-loop is short and the
		// failed queue captures the bad bytes for postmortem.
		return err
	}
	h.parsed.Add(1)

	var firstErr error
	for i := range p.Metrics {
		m := &p.Metrics[i]
		kind := m.Classify()
		switch {
		case h.equipmentValues.CanWrite(kind):
			if err := h.equipmentValues.Write(ctx, m, p.Gateway); err != nil {
				h.writeErrors.Add(1)
				if firstErr == nil {
					firstErr = err
				}
				continue
			}
			h.written.Add(1)
		case h.unsMetrics.CanWrite(kind):
			if err := h.unsMetrics.Write(ctx, m, p.Gateway); err != nil {
				h.writeErrors.Add(1)
				if firstErr == nil {
					firstErr = err
				}
				continue
			}
			h.written.Add(1)
		default:
			// PO-control parameter and any unrecognised kinds. Tracked but
			// not nacked — retry won't change the classification.
			h.skippedUnk.Add(1)
		}
	}
	return firstErr
}

// Stats returns aggregate counters for /health JSON.
type SparkplugStats struct {
	Parsed          uint64 `json:"sparkplug_parsed"`
	Written         uint64 `json:"sparkplug_written"`
	SkippedUnknown  uint64 `json:"sparkplug_skipped_unknown_kind"`
	WriteErrors     uint64 `json:"sparkplug_write_errors"`
}

func (h *SparkplugHandler) Stats() SparkplugStats {
	return SparkplugStats{
		Parsed:         h.parsed.Load(),
		Written:        h.written.Load(),
		SkippedUnknown: h.skippedUnk.Load(),
		WriteErrors:    h.writeErrors.Load(),
	}
}
