package handlers

import (
	"context"
	"log/slog"
	"sync/atomic"
	"time"

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
	poParameter     *writers.POParameter
	logger          *slog.Logger
}

func NewSparkplugHandler(
	ev *writers.EquipmentValues,
	uns *writers.UnsMetrics,
	po *writers.POParameter,
	logger *slog.Logger,
) *SparkplugHandler {
	return &SparkplugHandler{
		equipmentValues: ev,
		unsMetrics:      uns,
		poParameter:     po,
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

	// Per-metric timestamp fallback — Sparkplug spec allows metrics without
	// their own timestamp (only payload-level required). Node-RED's Prep
	// node falls back to payload timestamp, then to now(). Without this,
	// writers' time.UnixMilli(0).Truncate(...) lands rows at 1970-01-01.
	nowMs := time.Now().UnixMilli()
	for i := range p.Metrics {
		if p.Metrics[i].Timestamp == 0 {
			p.Metrics[i].Timestamp = p.Timestamp
		}
		if p.Metrics[i].Timestamp == 0 {
			p.Metrics[i].Timestamp = nowMs
		}
	}

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
		case h.poParameter.CanWrite(kind):
			if err := h.poParameter.Write(ctx, m, p.Gateway); err != nil {
				h.writeErrors.Add(1)
				if firstErr == nil {
					firstErr = err
				}
				continue
			}
			// Writer returns nil for the not-yet-ported sub-ranges (30700,
			// 30800-30899) without writing. The internal stats counter
			// tracks how often each branch fires so we can size the next
			// porting effort. Don't double-count "written" here for the
			// skip paths.
			h.written.Add(1)
		default:
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
