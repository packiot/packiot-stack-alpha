package writers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// UnsMetrics writes the live-state row in public.uns_equipment_current_metrics
// for the per-equipment dashboard (Grafana / the operator UI). Unlike
// equipment_values, this table is keyed by id_equipment ALONE — one row per
// equipment, always the latest value. ON CONFLICT (id_equipment) DO UPDATE.
//
// Mirrors the Node-RED "Prep: CurMachSpeed → UNS Metric" function. For now
// only CurMachSpeed lands here; future kinds (state, downtime category)
// would extend the switch.
type UnsMetrics struct {
	pool     *pgxpool.Pool
	resolver *sparkplug.Resolver
	logger   *slog.Logger
}

func NewUnsMetrics(pool *pgxpool.Pool, r *sparkplug.Resolver, logger *slog.Logger) *UnsMetrics {
	return &UnsMetrics{pool: pool, resolver: r, logger: logger}
}

func (w *UnsMetrics) CanWrite(kind sparkplug.MetricKind) bool {
	return kind == sparkplug.KindCurMachSpeed
}

func (w *UnsMetrics) Write(ctx context.Context, m *sparkplug.Metric, _ string) error {
	if m.Classify() != sparkplug.KindCurMachSpeed {
		return fmt.Errorf("UnsMetrics.Write called with unsupported kind %s", m.Classify())
	}

	topic := m.TopicForRegister()
	info, err := w.resolver.Resolve(ctx, topic)
	if err != nil {
		return fmt.Errorf("resolve topic %s: %w", topic, err)
	}
	if info == nil {
		w.logger.Debug("uns_metrics: topic not registered, skipping",
			slog.String("topic", topic),
			slog.String("name", m.Name),
		)
		return nil
	}

	var speed float64
	if err := json.Unmarshal(m.Value, &speed); err != nil {
		return fmt.Errorf("parse CurMachSpeed value (name=%s): %w", m.Name, err)
	}

	// Speed column is numeric(12,4); pgx accepts float64 via simple protocol.
	const q = `
		INSERT INTO public.uns_equipment_current_metrics
			(id_enterprise, id_site, id_area, id_equipment, speed, updated_at)
		VALUES ($1, $2, $3, $4, $5, NOW())
		ON CONFLICT (id_equipment) DO UPDATE SET
			speed      = EXCLUDED.speed,
			updated_at = EXCLUDED.updated_at
	`
	_, err = w.pool.Exec(ctx, q,
		info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment, speed,
	)
	if err != nil {
		return fmt.Errorf("upsert uns_equipment_current_metrics eq=%d speed=%v: %w",
			info.IDEquipment, speed, err)
	}
	return nil
}
