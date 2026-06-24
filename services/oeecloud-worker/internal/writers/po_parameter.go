package writers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// POParameter handles KindParameter (metric.ID in 30700-30899 — line
// config + PO control).
//
// Phased port:
//
//	30700  line order              → ❌ not yet — needs packml_register lookup
//	                                  + multi-row equipment_values UPDATE
//	30701  ideal_production_speed  → ✅ implemented (single equipment_values UPSERT)
//	30800-30899
//	       PO control (start/stop) → ❌ not yet — touches production_orders +
//	                                  production_orders_runtime via complex
//	                                  SELECT-then-decide logic in Node-RED
//	                                  (~200 lines)
//
// Unhandled IDs are LOGGED with a counter so we can measure their real
// frequency under live CPACK traffic before investing porting effort.
type POParameter struct {
	resolver *sparkplug.Resolver
	logger   *slog.Logger

	wroteIdealSpeed  atomic.Uint64
	skippedLineOrder atomic.Uint64
	skippedPOCtl     atomic.Uint64
	skippedOther     atomic.Uint64
}

func NewPOParameter(r *sparkplug.Resolver, logger *slog.Logger) *POParameter {
	return &POParameter{resolver: r, logger: logger}
}

func (w *POParameter) CanWrite(kind sparkplug.MetricKind) bool {
	return kind == sparkplug.KindParameter
}

func (w *POParameter) Build(ctx context.Context, m *sparkplug.Metric, _ string) (*Query, error) {
	if m.ID == nil {
		w.skippedOther.Add(1)
		return nil, nil
	}
	id := *m.ID

	switch {
	case id == 30701:
		return w.buildIdealProductionSpeed(ctx, m)
	case id == 30700:
		w.skippedLineOrder.Add(1)
		w.logger.Debug("po-parameter: 30700 line-order not yet ported, skipping",
			slog.String("name", m.Name), slog.Int("id", id))
		return nil, nil
	case id >= 30800 && id <= 30899:
		w.skippedPOCtl.Add(1)
		w.logger.Debug("po-parameter: 30800-30899 PO control not yet ported, skipping",
			slog.String("name", m.Name), slog.Int("id", id))
		return nil, nil
	default:
		w.skippedOther.Add(1)
		w.logger.Debug("po-parameter: unrecognised id, skipping",
			slog.String("name", m.Name), slog.Int("id", id))
		return nil, nil
	}
}

// buildIdealProductionSpeed mirrors Node-RED's Prep for parameter 30701:
// UPSERT equipment_values.ideal_production_speed for (ts_value, id_equipment).
func (w *POParameter) buildIdealProductionSpeed(ctx context.Context, m *sparkplug.Metric) (*Query, error) {
	topic := m.TopicForRegister()
	info, err := w.resolver.Resolve(ctx, topic)
	if err != nil {
		return nil, fmt.Errorf("resolve topic %s: %w", topic, err)
	}
	if info == nil {
		w.logger.Debug("po-parameter 30701: topic not registered, skipping",
			slog.String("topic", topic), slog.String("name", m.Name))
		return nil, nil
	}

	var speed float64
	if err := json.Unmarshal(m.Value, &speed); err != nil {
		return nil, fmt.Errorf("parse 30701 ideal_production_speed value (name=%s): %w", m.Name, err)
	}
	ts := time.UnixMilli(m.Timestamp).Truncate(time.Second).UTC()

	// ideal_production_speed is integer; Sparkplug sometimes carries float
	// (100.0). Round to nearest int — matches Node-RED's implicit coercion.
	speedInt := int(speed + 0.5)

	const sql = `
		INSERT INTO public.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 ideal_production_speed, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			ideal_production_speed = EXCLUDED.ideal_production_speed,
			signal_quality         = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`
	w.wroteIdealSpeed.Add(1)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			speedInt, info.SignalQuality,
		},
		Desc: fmt.Sprintf("upsert equipment_values (ideal_production_speed) eq=%d ts=%s",
			info.IDEquipment, ts.Format(time.RFC3339)),
	}, nil
}

// Stats returns per-ID counters for /health expansion later.
type POParameterStats struct {
	WroteIdealSpeed  uint64 `json:"po_param_wrote_ideal_speed"`
	SkippedLineOrder uint64 `json:"po_param_skipped_30700"`
	SkippedPOCtl     uint64 `json:"po_param_skipped_30800_30899"`
	SkippedOther     uint64 `json:"po_param_skipped_other"`
}

func (w *POParameter) Stats() POParameterStats {
	return POParameterStats{
		WroteIdealSpeed:  w.wroteIdealSpeed.Load(),
		SkippedLineOrder: w.skippedLineOrder.Load(),
		SkippedPOCtl:     w.skippedPOCtl.Load(),
		SkippedOther:     w.skippedOther.Load(),
	}
}
