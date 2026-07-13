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
	"strconv"
	"strings"
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

// SetShiftResolver enables the ADR-0014 Phase 2 shift fill, now folded
// straight into the equipment_values UPSERT (see shiftFold + Build).
func (w *EquipmentValues) SetShiftResolver(r *shiftresolver.Resolver) { w.shifts = r }

// shiftFold splices the ADR-0014 shift-fill columns (id_shift,
// id_shift_hour, ts_value_production) into an equipment_values UPSERT so the
// shift labels ride along with the row's own INSERT instead of a separate
// companion UPDATE (BuildShiftFill, removed). This halves the per-metric
// statement count on the equipment_values surface (~60→~40 stmts/msg on a
// typical CPACK payload) while preserving the dropped trigger's semantics
// byte-for-byte:
//
//   - keep-existing-else-fill → COALESCE(equipment_values.col, EXCLUDED.col)
//     on conflict (identical to the trigger's / old UPDATE's
//     COALESCE(col, $n) "only fill when NULL").
//   - session-tz date cast → ts_value_production = ($1)::date, reusing the
//     ts_value bind ($1) so the cast runs in this worker's session exactly
//     as piot_set_shift_on_equipment_values() cast NEW.ts_value::date.
//
// baseArgs is the count of positional args the builder already uses
// ($1..$baseArgs); the two shift-id binds append as $baseArgs+1 / +2. When
// the resolver is disabled (withShift=false) it returns empty fragments and
// no args — the row inserts with NULL shift labels, mirroring the old
// BuildShiftFill nil-return under `if w.shifts == nil`.
func shiftFold(withShift bool, idShift, idShiftHour *int, baseArgs int) (cols, vals, set string, args []any) {
	if !withShift {
		return "", "", "", nil
	}
	cols = ",\n\t\t\t id_shift, id_shift_hour, ts_value_production"
	vals = fmt.Sprintf(", $%d, $%d, ($1)::date", baseArgs+1, baseArgs+2)
	set = `,
			id_shift            = COALESCE(equipment_values.id_shift, EXCLUDED.id_shift),
			id_shift_hour       = COALESCE(equipment_values.id_shift_hour, EXCLUDED.id_shift_hour),
			ts_value_production = COALESCE(equipment_values.ts_value_production, EXCLUDED.ts_value_production)`
	return cols, vals, set, []any{idShift, idShiftHour}
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

	// Accept a JSON number (3.14) OR a numeric JSON string ("3.14") — Incoplast
	// quotes UnitModeCurrent and some counters. A value that is neither (a mode
	// NAME, null, object) is PERMANENTLY malformed: retrying can never succeed,
	// so SKIP (nil,nil) with a sampled log — exactly like the absurd-value guard
	// below. Returning an error here nacks the delivery and RabbitMQ redelivers
	// it forever: on 2026-07-12 an Incoplast UnitModeCurrent carrying a
	// non-numeric string flooded the worker with an infinite nack-retry poison
	// storm (dozens/sec), starving the other jobs and blocking Incoplast ingest.
	value, ok := parseNumericValue(m.Value)
	if !ok {
		if w.skipSample.Add(1)%64 == 1 {
			w.logger.Warn("equipment_values: non-numeric value, skipping (sampled 1/64; poison-storm guard)",
				slog.String("name", m.Name), slog.String("kind", kind.String()),
				slog.String("raw", truncateRaw(m.Value, 48)))
		}
		return nil, nil
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

	// ADR-0014 fold: resolve the shift ONCE here and thread the labels into
	// the row's own UPSERT (shiftFold), replacing the separate companion
	// UPDATE that BuildShiftFill used to queue. withShift mirrors the old
	// `if w.shifts == nil { return nil,nil }` guard: when the resolver is
	// disabled the labels stay NULL and no shift binds are added. When it is
	// enabled the fill is fail-open — an unresolvable shift still stamps
	// ts_value_production (($1)::date) and leaves the id_* columns NULL,
	// byte-for-byte what the dropped trigger did.
	withShift := w.shifts != nil
	var idShift, idShiftHour *int
	if withShift {
		idShift, idShiftHour = w.shifts.Resolve(ctx, info.IDEnterprise, info.IDEquipment, ts)
	}

	switch kind {
	case sparkplug.KindProdProcessedCount:
		return buildProcessed(ts, info, tpEquipment, value, (*float64)(m.Counter), (*float64)(m.CurSpeed), faults, checkNumber, schema, withShift, idShift, idShiftHour), nil
	case sparkplug.KindProdConsumedCount:
		return buildConsumed(ts, info, tpEquipment, value, (*float64)(m.Counter), (*float64)(m.CurSpeed), faults, checkNumber, schema, withShift, idShift, idShiftHour), nil
	case sparkplug.KindProdDefectiveCount:
		return buildDefective(ts, info, tpEquipment, value, (*float64)(m.Counter), faults, checkNumber, schema, withShift, idShift, idShiftHour), nil
	case sparkplug.KindStateCurrent:
		return buildState(ts, info, tpEquipment, int(value), faults, checkNumber, schema, withShift, idShift, idShiftHour), nil
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
		return buildMode(ts, info, tpEquipment, int(value), subMode, faults, checkNumber, schema, withShift, idShift, idShiftHour), nil
	}
	return nil, nil
}

// parseNumericValue accepts a Sparkplug metric value as either a JSON number
// (3.14) or a numeric JSON string ("3.14"). Some producers — notably the
// Incoplast edge — quote UnitModeCurrent and certain counters. Returns
// (0,false) for anything that is not numeric (a mode NAME, null, object) so the
// caller can SKIP the metric rather than nack-and-retry a permanently-malformed
// payload forever. See the poison-storm note in Build.
func parseNumericValue(raw json.RawMessage) (float64, bool) {
	var f float64
	if json.Unmarshal(raw, &f) == nil {
		return f, true
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		if f, err := strconv.ParseFloat(strings.TrimSpace(s), 64); err == nil {
			return f, true
		}
	}
	return 0, false
}

// truncateRaw renders a raw JSON value for a log line, capped to n bytes.
func truncateRaw(raw json.RawMessage, n int) string {
	s := string(raw)
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
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
	withShift bool, idShift, idShiftHour *int,
) *Query {
	sCols, sVals, sSet, sArgs := shiftFold(withShift, idShift, idShiftHour, 12)
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, net_production_incr, net_production_val, speed, signal_quality, faults, check_number%s)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12%s)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			net_production_incr = EXCLUDED.net_production_incr,
			net_production_val  = COALESCE(EXCLUDED.net_production_val, equipment_values.net_production_val),
			speed               = COALESCE(EXCLUDED.speed, equipment_values.speed),
			signal_quality      = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality),
			faults              = COALESCE(EXCLUDED.faults, equipment_values.faults),
			check_number        = EXCLUDED.check_number%s
	`, schema, sCols, sVals, sSet)
	args := []any{
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		tpEquipment, value, counter, curspeed, info.SignalQuality, faults, checkNumber,
	}
	args = append(args, sArgs...)
	return &Query{
		SQL:  sql,
		Args: args,
		Desc: fmt.Sprintf("upsert %s.equipment_values (processed) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildConsumed(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter, curspeed *float64,
	faults *string, checkNumber int64, schema string,
	withShift bool, idShift, idShiftHour *int,
) *Query {
	sCols, sVals, sSet, sArgs := shiftFold(withShift, idShift, idShiftHour, 12)
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, gross_production_incr, gross_production_val, speed, signal_quality, faults, check_number%s)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12%s)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			gross_production_incr = EXCLUDED.gross_production_incr,
			gross_production_val  = COALESCE(EXCLUDED.gross_production_val, equipment_values.gross_production_val),
			speed                 = COALESCE(EXCLUDED.speed, equipment_values.speed),
			signal_quality        = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality),
			faults                = COALESCE(EXCLUDED.faults, equipment_values.faults),
			check_number          = EXCLUDED.check_number%s
	`, schema, sCols, sVals, sSet)
	args := []any{
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		tpEquipment, value, counter, curspeed, info.SignalQuality, faults, checkNumber,
	}
	args = append(args, sArgs...)
	return &Query{
		SQL:  sql,
		Args: args,
		Desc: fmt.Sprintf("upsert %s.equipment_values (consumed) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildDefective(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter *float64,
	faults *string, checkNumber int64, schema string,
	withShift bool, idShift, idShiftHour *int,
) *Query {
	sCols, sVals, sSet, sArgs := shiftFold(withShift, idShift, idShiftHour, 11)
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, scrap_incr, scrap_val, signal_quality, faults, check_number%s)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11%s)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			scrap_incr     = EXCLUDED.scrap_incr,
			scrap_val      = COALESCE(EXCLUDED.scrap_val, equipment_values.scrap_val),
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality),
			faults         = COALESCE(EXCLUDED.faults, equipment_values.faults),
			check_number   = EXCLUDED.check_number%s
	`, schema, sCols, sVals, sSet)
	args := []any{
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		tpEquipment, value, counter, info.SignalQuality, faults, checkNumber,
	}
	args = append(args, sArgs...)
	return &Query{
		SQL:  sql,
		Args: args,
		Desc: fmt.Sprintf("upsert %s.equipment_values (defective) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildState(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment, state int, faults *string, checkNumber int64, schema string,
	withShift bool, idShift, idShiftHour *int,
) *Query {
	sCols, sVals, sSet, sArgs := shiftFold(withShift, idShift, idShiftHour, 10)
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, state, signal_quality, faults, check_number%s)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10%s)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			state          = EXCLUDED.state,
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality),
			faults         = COALESCE(EXCLUDED.faults, equipment_values.faults),
			check_number   = EXCLUDED.check_number%s
	`, schema, sCols, sVals, sSet)
	args := []any{
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		tpEquipment, state, info.SignalQuality, faults, checkNumber,
	}
	args = append(args, sArgs...)
	return &Query{
		SQL:  sql,
		Args: args,
		Desc: fmt.Sprintf("upsert %s.equipment_values (state) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}

func buildMode(
	ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment, mode int, subMode *string, faults *string, checkNumber int64, schema string,
	withShift bool, idShift, idShiftHour *int,
) *Query {
	sCols, sVals, sSet, sArgs := shiftFold(withShift, idShift, idShiftHour, 11)
	sql := fmt.Sprintf(`
		INSERT INTO %s.equipment_values
			(ts_value, id_enterprise, id_site, id_area, id_equipment,
			 tp_equipment, mode, sub_mode, signal_quality, faults, check_number%s)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11%s)
		ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
			mode           = EXCLUDED.mode,
			sub_mode       = COALESCE(EXCLUDED.sub_mode, equipment_values.sub_mode),
			signal_quality = COALESCE(EXCLUDED.signal_quality, equipment_values.signal_quality),
			faults         = COALESCE(EXCLUDED.faults, equipment_values.faults),
			check_number   = EXCLUDED.check_number%s
	`, schema, sCols, sVals, sSet)
	args := []any{
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		tpEquipment, mode, subMode, info.SignalQuality, faults, checkNumber,
	}
	args = append(args, sArgs...)
	return &Query{
		SQL:  sql,
		Args: args,
		Desc: fmt.Sprintf("upsert %s.equipment_values (mode) eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339)),
	}
}
