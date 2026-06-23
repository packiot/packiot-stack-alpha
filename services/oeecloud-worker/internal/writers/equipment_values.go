// Package writers owns the postgres-write side of each handler. One file
// per target table keeps the topic-routing logic in handlers/sparkplug.go
// clean and lets writers be reused across routing keys.
package writers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// EquipmentValues writes production counter metrics (ProdProcessedCount /
// ProdConsumedCount / ProdDefectiveCount) to public.equipment_values.
//
// Mirrors the columns the Node-RED "UPSERT: equipment_values / ..." node
// writes for these three kinds:
//
//   ProdProcessedCount → net_production_incr, net_production_val, curspeed
//   ProdConsumedCount  → gross_production_incr, gross_production_val, curspeed
//   ProdDefectiveCount → scrap_incr, scrap_val
//
// All UPSERT on (ts_value, id_equipment). tp_equipment is set from
// metric.IsLineTopic() to match Prep's `topic_unit == 0 → 3, else 1`.
// ts_value is bucketed to whole seconds (matches Node-RED's
// Math.round(parseInt(ts)/1000)*1000).
type EquipmentValues struct {
	pool     *pgxpool.Pool
	resolver *sparkplug.Resolver
	logger   *slog.Logger
}

func NewEquipmentValues(pool *pgxpool.Pool, r *sparkplug.Resolver, logger *slog.Logger) *EquipmentValues {
	return &EquipmentValues{pool: pool, resolver: r, logger: logger}
}

// CanWrite returns true for kinds whose values land in equipment_values.
// State/Mode/Counters share the same UPSERT key (ts_value, id_equipment);
// postgres triggers on equipment_values then populate equipment_events
// from state column changes (so we don't write equipment_events directly).
func (w *EquipmentValues) CanWrite(kind sparkplug.MetricKind) bool {
	switch kind {
	case sparkplug.KindProdProcessedCount,
		sparkplug.KindProdConsumedCount,
		sparkplug.KindProdDefectiveCount,
		sparkplug.KindStateCurrent,
		sparkplug.KindUnitModeCurrent:
		return true
	}
	return false
}

// Write inserts (or updates on conflict) one row. Returns nil on success
// or a wrapped error the caller propagates upward — the AMQP consumer
// nacks → DLX → retry on error, so writers should only return errors for
// transient failures. Missing packml_register rows return nil (skip).
func (w *EquipmentValues) Write(ctx context.Context, m *sparkplug.Metric, gateway string) error {
	kind := m.Classify()
	if !w.CanWrite(kind) {
		return fmt.Errorf("EquipmentValues.Write called with unsupported kind %s", kind)
	}

	topic := m.TopicForRegister()
	info, err := w.resolver.Resolve(ctx, topic)
	if err != nil {
		return fmt.Errorf("resolve topic %s: %w", topic, err)
	}
	if info == nil {
		w.logger.Debug("equipment_values: topic not registered, skipping",
			slog.String("topic", topic),
			slog.String("name", m.Name),
			slog.String("kind", kind.String()),
		)
		return nil
	}

	// Bucket to whole seconds so multiple metrics arriving in the same
	// second UPSERT into one row (matches Node-RED's behaviour).
	ts := time.UnixMilli(m.Timestamp).Truncate(time.Second).UTC()

	// Parse value as float (Sparkplug metric.value is a JSON number — but
	// some sources serialise as string). pgx accepts both via Encode.
	var value float64
	if err := json.Unmarshal(m.Value, &value); err != nil {
		// Some metric values are non-numeric (e.g. faults as JSON). For
		// production counters we expect numeric; bail with an error so
		// retry catches it (could be a transient producer bug worth
		// investigating via DLQ).
		return fmt.Errorf("parse value as float (kind=%s, name=%s): %w", kind, m.Name, err)
	}

	tpEquipment := 1
	if m.IsLineTopic() {
		tpEquipment = 3
	}

	// Build the UPSERT. ON CONFLICT (ts_value, id_equipment) is the
	// existing equipment_values uniqueness constraint — running this
	// alongside Node-RED's writer is safe (whichever wrote last wins,
	// and the values are derived from the same source).
	switch kind {
	case sparkplug.KindProdProcessedCount:
		return w.upsertProcessed(ctx, ts, info, tpEquipment, value, m.Counter, m.CurSpeed)
	case sparkplug.KindProdConsumedCount:
		return w.upsertConsumed(ctx, ts, info, tpEquipment, value, m.Counter, m.CurSpeed)
	case sparkplug.KindProdDefectiveCount:
		return w.upsertDefective(ctx, ts, info, tpEquipment, value, m.Counter)
	case sparkplug.KindStateCurrent:
		return w.upsertState(ctx, ts, info, tpEquipment, int(value))
	case sparkplug.KindUnitModeCurrent:
		// UnitModeCurrent payload may carry sub_mode in metric.alias —
		// extract as string if present and non-null.
		var subMode *string
		if len(m.Alias) > 0 && string(m.Alias) != "null" {
			var s string
			if err := json.Unmarshal(m.Alias, &s); err == nil && s != "" {
				subMode = &s
			}
		}
		return w.upsertMode(ctx, ts, info, tpEquipment, int(value), subMode)
	}
	return nil
}

func (w *EquipmentValues) upsertProcessed(
	ctx context.Context, ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter, curspeed *float64,
) error {
	const q = `
		INSERT INTO public.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, net_production_incr, net_production_val, speed, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			net_production_incr = EXCLUDED.net_production_incr,
			net_production_val  = COALESCE(EXCLUDED.net_production_val, equipment_values.net_production_val),
			speed               = COALESCE(EXCLUDED.speed, equipment_values.speed),
			signal_quality      = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`
	_, err := w.pool.Exec(ctx, q,
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		tpEquipment, value, counter, curspeed, info.SignalQuality,
	)
	if err != nil {
		return fmt.Errorf("upsert equipment_values (processed) eq=%d ts=%s: %w",
			info.IDEquipment, ts.Format(time.RFC3339), err)
	}
	return nil
}

func (w *EquipmentValues) upsertConsumed(
	ctx context.Context, ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter, curspeed *float64,
) error {
	const q = `
		INSERT INTO public.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, gross_production_incr, gross_production_val, speed, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			gross_production_incr = EXCLUDED.gross_production_incr,
			gross_production_val  = COALESCE(EXCLUDED.gross_production_val, equipment_values.gross_production_val),
			speed                 = COALESCE(EXCLUDED.speed, equipment_values.speed),
			signal_quality        = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`
	_, err := w.pool.Exec(ctx, q,
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		tpEquipment, value, counter, curspeed, info.SignalQuality,
	)
	if err != nil {
		return fmt.Errorf("upsert equipment_values (consumed) eq=%d ts=%s: %w",
			info.IDEquipment, ts.Format(time.RFC3339), err)
	}
	return nil
}

func (w *EquipmentValues) upsertDefective(
	ctx context.Context, ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter *float64,
) error {
	const q = `
		INSERT INTO public.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, scrap_incr, scrap_val, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			scrap_incr     = EXCLUDED.scrap_incr,
			scrap_val      = COALESCE(EXCLUDED.scrap_val, equipment_values.scrap_val),
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`
	_, err := w.pool.Exec(ctx, q,
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		tpEquipment, value, counter, info.SignalQuality,
	)
	if err != nil {
		return fmt.Errorf("upsert equipment_values (defective) eq=%d ts=%s: %w",
			info.IDEquipment, ts.Format(time.RFC3339), err)
	}
	return nil
}

func (w *EquipmentValues) upsertState(
	ctx context.Context, ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment, state int,
) error {
	const q = `
		INSERT INTO public.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, state, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			state          = EXCLUDED.state,
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`
	_, err := w.pool.Exec(ctx, q,
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		tpEquipment, state, info.SignalQuality,
	)
	if err != nil {
		return fmt.Errorf("upsert equipment_values (state) eq=%d ts=%s: %w",
			info.IDEquipment, ts.Format(time.RFC3339), err)
	}
	return nil
}

func (w *EquipmentValues) upsertMode(
	ctx context.Context, ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment, mode int, subMode *string,
) error {
	const q = `
		INSERT INTO public.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, mode, sub_mode, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			mode           = EXCLUDED.mode,
			sub_mode       = COALESCE(EXCLUDED.sub_mode, equipment_values.sub_mode),
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`
	_, err := w.pool.Exec(ctx, q,
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		tpEquipment, mode, subMode, info.SignalQuality,
	)
	if err != nil {
		return fmt.Errorf("upsert equipment_values (mode) eq=%d ts=%s: %w",
			info.IDEquipment, ts.Format(time.RFC3339), err)
	}
	return nil
}

