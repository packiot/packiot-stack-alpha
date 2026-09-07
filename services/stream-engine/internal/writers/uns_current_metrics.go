package writers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

// UnsMetrics builds the live-state UPSERT for public.equipment_live_metrics
// — keyed by id_equipment alone (one row per equipment, always the latest
// value). ON CONFLICT (id_equipment) DO UPDATE. Mirrors Node-RED's
// "Prep: CurMachSpeed → UNS Metric" function.
type UnsMetrics struct {
	resolver *sparkplug.Resolver
	logger   *slog.Logger
}

func NewUnsMetrics(r *sparkplug.Resolver, logger *slog.Logger) *UnsMetrics {
	return &UnsMetrics{resolver: r, logger: logger}
}

func (w *UnsMetrics) CanWrite(kind sparkplug.MetricKind) bool {
	return kind == sparkplug.KindCurMachSpeed
}

// Build returns the *Query for one CurMachSpeed metric. The `schema`
// parameter selects the target schema (public vs shadow_go_port) —
// ADR-0010 Phase 3 shadow-mode DB comparison.
func (w *UnsMetrics) Build(ctx context.Context, m *sparkplug.Metric, _ string, schema string) (*Query, error) {
	topic := m.TopicForRegister()
	info, err := w.resolver.Resolve(ctx, topic)
	if err != nil {
		return nil, fmt.Errorf("resolve topic %s: %w", topic, err)
	}
	if info == nil {
		w.logger.Debug("uns_metrics: topic not registered, skipping",
			slog.String("topic", topic),
			slog.String("name", m.Name),
		)
		return nil, nil
	}

	var speed float64
	if err := json.Unmarshal(m.Value, &speed); err != nil {
		return nil, fmt.Errorf("parse CurMachSpeed value (name=%s): %w", m.Name, err)
	}

	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_live_metrics
			(id_enterprise, id_site, id_area, id_equipment, speed, updated_at)
		VALUES ($1, $2, $3, $4, $5, NOW())
		ON CONFLICT (id_equipment) DO UPDATE SET
			speed      = EXCLUDED.speed,
			updated_at = EXCLUDED.updated_at
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment, speed,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_live_metrics eq=%d speed=%v",
			schema, info.IDEquipment, speed),
	}, nil
}
