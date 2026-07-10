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
	"math"
	"sync/atomic"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/shiftresolver"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// EquipmentValues builds production-counter + state/mode UPSERTs for
// public.equipment_values. Mirrors the columns the Node-RED "UPSERT:
// equipment_values / ..." node writes:
//
//	ProdProcessedCount → net_production_incr, net_production_val, speed
//	ProdConsumedCount  → gross_production_incr, gross_production_val, speed
//	ProdDefectiveCount → scrap_incr, scrap_val
//	StateCurrent       → state
//	UnitModeCurrent    → mode, sub_mode
//
// All UPSERT on (ts_value, id_equipment). tp_equipment is set from
// metric.IsLineTopic() (3 for line, 1 for unit). ts_value bucketed to
// whole seconds — matches Node-RED's Math.round(ts/1000)*1000.
type EquipmentValues struct {
	skipSample atomic.Uint64

	resolver *sparkplug.Resolver
	logger   *slog.Logger

	// shifts — ADR-0014 Phase 2 Go port of the shift trigger. nil =
	// disabled (SHIFT_RESOLVER_ENABLED=false); set via SetShiftResolver.
	shifts *shiftresolver.Resolver
}

func NewEquipmentValues(r *sparkplug.Resolver, logger *slog.Logger) *EquipmentValues {
	return &EquipmentValues{resolver: r, logger: logger}
}

// SetShiftResolver enables the ADR-0014 Phase 2 shift fill (see
// BuildShiftFill).
func (w *EquipmentValues) SetShiftResolver(r *shiftresolver.Resolver) { w.shifts = r }

// sqlShiftFill ports piot_set_shift_on_equipment_values() as a companion
// UPDATE queued right after the metric's UPSERT in the same pgx.Batch.
// COALESCE everywhere = the trigger's "only fill when NULL" semantics;
// ($1)::date matches the trigger's NEW.ts_value::date (session-timezone
// cast, evaluated in this worker's session exactly as the trigger
// evaluates in the inserting session).
const sqlShiftFill = `
	UPDATE %s.equipment_values SET
		id_shift            = COALESCE(id_shift, $3),
		id_shift_hour       = COALESCE(id_shift_hour, $4),
		ts_value_production = COALESCE(ts_value_production, ($1)::date)
	WHERE ts_value = $1 AND id_equipment = $2`

// BuildShiftFill returns the shift-fill *Query for one metric, or nil
// when the resolver is disabled or the topic is unregistered. Fail-open
// end to end: an unresolvable shift still fills ts_value_production and
// leaves the shift columns NULL — byte-for-byte what the trigger does.
func (w *EquipmentValues) BuildShiftFill(ctx context.Context, m *sparkplug.Metric, schema string) (*Query, error) {
	if w.shifts == nil {
		return nil, nil
	}
	topic := m.TopicForRegister()
	info, err := w.resolver.Resolve(ctx, topic)
	if err != nil {
		return nil, fmt.Errorf("resolve topic %s: %w", topic, err)
	}
	if info == nil {
		return nil, nil
	}
	ts := time.UnixMilli(m.Timestamp).Truncate(time.Second).UTC()
	idShift, idShiftHour := w.shifts.Resolve(ctx, info.IDEnterprise, info.IDEquipment, ts)
	return &Query{
		SQL:  fmt.Sprintf(sqlShiftFill, schema),
		Args: []any{ts, info.IDEquipment, idShift, idShiftHour},
		Desc: fmt.Sprintf("shift-fill %s.equipment_values eq=%d ts=%s", schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}, nil
}

// CanWrite returns true for kinds whose values land in equipment_values.
// State/Mode/Counters share the same UPSERT key (ts_value, id_equipment).
//
// equipment_events: prod's pipeline UPSERTS an event row directly for
// every StateCurrent sample (captured node: ON CONFLICT (id_equipment,
// ts_event) DO UPDATE status) — Flow 1 on staging gets the same effect
// from its PL/pgSQL trigger; the SHADOW flows have no trigger, so
// BuildEventMint provides the prod-faithful companion (ADR-0010 10.4).
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
		// INFO 1-in-32 sample (was Debug = invisible): the f1
		// empty_batch trickle (~3/min) is THESE — every skipped topic
		// deserves a name in the logs (gap-closure 2026-07-07).
		if w.skipSample.Add(1)%32 == 1 {
			w.logger.Info("equipment_values: topic not registered, skipping (sampled 1/32)",
				slog.String("topic", topic),
				slog.String("name", m.Name),
				slog.String("kind", kind.String()),
			)
		}
		return nil, nil
	}

	ts := time.UnixMilli(m.Timestamp).Truncate(time.Second).UTC()

	var value float64
	if err := json.Unmarshal(m.Value, &value); err != nil {
		return nil, fmt.Errorf("parse value as float (kind=%s, name=%s): %w", kind, m.Name, err)
	}
	// Absurd-value guard (oscillator incident 2026-07-04): no factory
	// counter/state value approaches 1e12; beyond it the payload is
	// corrupt — skip with a loud log rather than poison the stream.
	if math.Abs(value) > 1e12 || math.IsNaN(value) || math.IsInf(value, 0) {
		w.logger.Error("equipment_values: ABSURD value rejected (stream-poison guard)",
			slog.String("name", m.Name), slog.Float64("value", value))
		return nil, nil
	}

	tpEquipment := 1
	if m.IsLineTopic() {
		tpEquipment = 3
	}

	// Column parity with prod's mega-node (ADR-0010 audit 2026-07-03):
	// faults rides along on ANY metric that carries it; check_number is
	// the raw Sparkplug ms-timestamp, written on every row.
	var faults *string
	if len(m.Faults) > 0 && string(m.Faults) != "null" {
		s := string(m.Faults)
		faults = &s
	}
	checkNumber := m.Timestamp

	switch kind {
	case sparkplug.KindProdProcessedCount:
		return buildProcessed(ts, info, tpEquipment, value, (*float64)(m.Counter), (*float64)(m.CurSpeed), faults, checkNumber, schema), nil
	case sparkplug.KindProdConsumedCount:
		return buildConsumed(ts, info, tpEquipment, value, (*float64)(m.Counter), (*float64)(m.CurSpeed), faults, checkNumber, schema), nil
	case sparkplug.KindProdDefectiveCount:
		return buildDefective(ts, info, tpEquipment, value, (*float64)(m.Counter), faults, checkNumber, schema), nil
	case sparkplug.KindStateCurrent:
		return buildState(ts, info, tpEquipment, int(value), faults, checkNumber, schema), nil
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
		return buildMode(ts, info, tpEquipment, int(value), subMode, faults, checkNumber, schema), nil
	}
	return nil, nil
}

// BuildEventMint is the ADR-0010 10.4 companion for KindStateCurrent:
// prod mints an equipment_events row from every state sample. Returns
// (nil, nil) for other kinds or unregistered topics. Shadow paths only —
// the handler gates on SourceType (Flow 1's trigger already mints).
func (w *EquipmentValues) BuildEventMint(ctx context.Context, m *sparkplug.Metric, schema string) (*Query, error) {
	if m.Classify() != sparkplug.KindStateCurrent {
		return nil, nil
	}
	info, err := w.resolver.Resolve(ctx, m.TopicForRegister())
	if err != nil || info == nil {
		return nil, err
	}
	// Only status_type=4 equipment is in the events deriver's scope (ADR-0014
	// P3a converts their raw per-sample mints into interval events + deletes
	// the non-transition rows). For status_type!=4 equipment (lines/sectors and
	// non-state machines), the deriver never cleans up, so a per-sample mint
	// here leaves open (ts_end NULL) events that the running_time compute counts
	// to now() — a massive over-count (eq=51: 6914 open events → 44,182 h/day
	// vs legacy's 13.6). Prod mints for these via line-aggregation
	// (forced_creation_system), not per-sample. So: gate to the deriver's scope.
	if info.StatusType != 4 {
		return nil, nil
	}
	var value float64
	if err := json.Unmarshal(m.Value, &value); err != nil {
		return nil, fmt.Errorf("parse state value (name=%s): %w", m.Name, err)
	}
	ts := time.UnixMilli(m.Timestamp).Truncate(time.Second).UTC()
	return &Query{
		SQL:  fmt.Sprintf(eventMintSQL, schema),
		Args: []any{info.IDEquipment, ts, info.IDEnterprise, int(value)},
		Desc: fmt.Sprintf("mint %s.equipment_events eq=%d ts=%s", schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}, nil
}

// Verbatim from the captured prod node ("INSERT State in equipment_events").
const eventMintSQL = `
	INSERT INTO %s.equipment_events (id_equipment, ts_event, id_enterprise, status)
	VALUES ($1, $2, $3, $4)
	ON CONFLICT (id_equipment, ts_event) DO UPDATE SET
		id_enterprise = EXCLUDED.id_enterprise, status = EXCLUDED.status`

func buildProcessed(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter, curspeed *float64,
	faults *string, checkNumber int64, schema string,
) *Query {
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, net_production_incr, net_production_val, speed, signal_quality, faults, check_number)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			net_production_incr = EXCLUDED.net_production_incr,
			net_production_val  = COALESCE(EXCLUDED.net_production_val, equipment_values.net_production_val),
			speed               = COALESCE(EXCLUDED.speed, equipment_values.speed),
			signal_quality      = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality),
			faults              = COALESCE(EXCLUDED.faults, equipment_values.faults),
			check_number        = EXCLUDED.check_number
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			tpEquipment, value, counter, curspeed, info.SignalQuality, faults, checkNumber,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_values (processed) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildConsumed(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter, curspeed *float64,
	faults *string, checkNumber int64, schema string,
) *Query {
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, gross_production_incr, gross_production_val, speed, signal_quality, faults, check_number)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			gross_production_incr = EXCLUDED.gross_production_incr,
			gross_production_val  = COALESCE(EXCLUDED.gross_production_val, equipment_values.gross_production_val),
			speed                 = COALESCE(EXCLUDED.speed, equipment_values.speed),
			signal_quality        = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality),
			faults                = COALESCE(EXCLUDED.faults, equipment_values.faults),
			check_number          = EXCLUDED.check_number
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			tpEquipment, value, counter, curspeed, info.SignalQuality, faults, checkNumber,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_values (consumed) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildDefective(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter *float64,
	faults *string, checkNumber int64, schema string,
) *Query {
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, scrap_incr, scrap_val, signal_quality, faults, check_number)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			scrap_incr     = EXCLUDED.scrap_incr,
			scrap_val      = COALESCE(EXCLUDED.scrap_val, equipment_values.scrap_val),
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality),
			faults         = COALESCE(EXCLUDED.faults, equipment_values.faults),
			check_number   = EXCLUDED.check_number
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			tpEquipment, value, counter, info.SignalQuality, faults, checkNumber,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_values (defective) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildState(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment, state int, faults *string, checkNumber int64, schema string,
) *Query {
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, state, signal_quality, faults, check_number)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			state          = EXCLUDED.state,
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality),
			faults         = COALESCE(EXCLUDED.faults, equipment_values.faults),
			check_number   = EXCLUDED.check_number
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			tpEquipment, state, info.SignalQuality, faults, checkNumber,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_values (state) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildMode(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment, mode int, subMode *string, faults *string, checkNumber int64, schema string,
) *Query {
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, mode, sub_mode, signal_quality, faults, check_number)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			mode           = EXCLUDED.mode,
			sub_mode       = COALESCE(EXCLUDED.sub_mode, equipment_values.sub_mode),
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality),
			faults         = COALESCE(EXCLUDED.faults, equipment_values.faults),
			check_number   = EXCLUDED.check_number
	`, schema)
	return &Query{
		SQL: sql,
		Args: []any{
			ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			tpEquipment, mode, subMode, info.SignalQuality, faults, checkNumber,
		},
		Desc: fmt.Sprintf("upsert %s.equipment_values (mode) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}
