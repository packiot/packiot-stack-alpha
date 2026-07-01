// Package writers builds the postgres queries each handler needs. Writers
// no longer execute (since #9 / commit batching refactor) — they return
// *Query for the handler to enqueue into a pgx.Batch. Handler executes
// all of a delivery's queries as one batched round-trip.
package writers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// EquipmentValues builds production-counter + state/mode UPSERTs for
// public.equipment_values. Mirrors the columns the Node-RED "UPSERT:
// equipment_values / ..." node writes:
//
//   ProdProcessedCount → net_production_incr, net_production_val, speed
//   ProdConsumedCount  → gross_production_incr, gross_production_val, speed
//   ProdDefectiveCount → scrap_incr, scrap_val
//   StateCurrent       → state
//   UnitModeCurrent    → mode, sub_mode
//
// All UPSERT on (ts_value, id_equipment). tp_equipment is set from
// metric.IsLineTopic() (3 for line, 1 for unit). ts_value bucketed to
// whole seconds — matches Node-RED's Math.round(ts/1000)*1000.
type EquipmentValues struct {
	resolver *sparkplug.Resolver
	logger   *slog.Logger
}

func NewEquipmentValues(r *sparkplug.Resolver, logger *slog.Logger) *EquipmentValues {
	return &EquipmentValues{resolver: r, logger: logger}
}

// CanWrite returns true for kinds whose values land in equipment_values.
// State/Mode/Counters share the same UPSERT key (ts_value, id_equipment);
// postgres triggers on equipment_values populate equipment_events from
// state column changes — so we don't write equipment_events directly.
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

// Build returns the *Query for one metric, or (nil, nil) when the topic
// is not in packml_register (skip — not a write error). Returns an error
// for unexpected kinds or unparseable values.
//
// The `schema` parameter selects the target schema (public vs shadow_go_port
// per ADR-0010 Phase 3 shadow-mode DB comparison). Caller validates the
// value against a whitelist before calling — the writer trusts it.
func (w *EquipmentValues) Build(ctx context.Context, m *sparkplug.Metric, _ string, schema string) (*Query, error) {
	kind := m.Classify()
	if !w.CanWrite(kind) {
		return nil, fmt.Errorf("EquipmentValues.Build called with unsupported kind %s", kind)
	}

	topic := m.TopicForRegister()
	info, err := w.resolver.Resolve(ctx, topic)
	if err != nil {
		return nil, fmt.Errorf("resolve topic %s: %w", topic, err)
	}
	if info == nil {
		w.logger.Debug("equipment_values: topic not registered, skipping",
			slog.String("topic", topic),
			slog.String("name", m.Name),
			slog.String("kind", kind.String()),
		)
		return nil, nil
	}

	ts := time.UnixMilli(m.Timestamp).Truncate(time.Second).UTC()

	var value float64
	if err := json.Unmarshal(m.Value, &value); err != nil {
		return nil, fmt.Errorf("parse value as float (kind=%s, name=%s): %w", kind, m.Name, err)
	}

	tpEquipment := 1
	if m.IsLineTopic() {
		tpEquipment = 3
	}

	switch kind {
	case sparkplug.KindProdProcessedCount:
		return buildProcessed(ts, info, tpEquipment, value, m.Counter, m.CurSpeed, schema), nil
	case sparkplug.KindProdConsumedCount:
		return buildConsumed(ts, info, tpEquipment, value, m.Counter, m.CurSpeed, schema), nil
	case sparkplug.KindProdDefectiveCount:
		return buildDefective(ts, info, tpEquipment, value, m.Counter, schema), nil
	case sparkplug.KindStateCurrent:
		return buildState(ts, info, tpEquipment, int(value), schema), nil
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
		return buildMode(ts, info, tpEquipment, int(value), subMode, schema), nil
	}
	return nil, nil
}

func buildProcessed(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter, curspeed *float64,
	schema string,
) *Query {
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, net_production_incr, net_production_val, speed, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			net_production_incr = EXCLUDED.net_production_incr,
			net_production_val  = COALESCE(EXCLUDED.net_production_val, equipment_values.net_production_val),
			speed               = COALESCE(EXCLUDED.speed, equipment_values.speed),
			signal_quality      = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			tpEquipment, value, counter, curspeed, info.SignalQuality,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_values (processed) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildConsumed(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter, curspeed *float64,
	schema string,
) *Query {
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, gross_production_incr, gross_production_val, speed, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			gross_production_incr = EXCLUDED.gross_production_incr,
			gross_production_val  = COALESCE(EXCLUDED.gross_production_val, equipment_values.gross_production_val),
			speed                 = COALESCE(EXCLUDED.speed, equipment_values.speed),
			signal_quality        = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			tpEquipment, value, counter, curspeed, info.SignalQuality,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_values (consumed) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildDefective(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter *float64,
	schema string,
) *Query {
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, scrap_incr, scrap_val, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			scrap_incr     = EXCLUDED.scrap_incr,
			scrap_val      = COALESCE(EXCLUDED.scrap_val, equipment_values.scrap_val),
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			tpEquipment, value, counter, info.SignalQuality,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_values (defective) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildState(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment, state int, schema string,
) *Query {
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, state, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			state          = EXCLUDED.state,
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			tpEquipment, state, info.SignalQuality,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_values (state) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildMode(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment, mode int, subMode *string, schema string,
) *Query {
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, mode, sub_mode, signal_quality)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			mode           = EXCLUDED.mode,
			sub_mode       = COALESCE(EXCLUDED.sub_mode, equipment_values.sub_mode),
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality)
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			tpEquipment, mode, subMode, info.SignalQuality,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_values (mode) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}
