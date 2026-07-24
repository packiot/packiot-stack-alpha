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

	// foldShift — ADR-0014 fold rollback flag (SHIFT_FILL_FOLDED). When
	// true, the shift columns are folded into the UPSERT (shiftFold) and
	// BuildShiftFill returns nil (no separate UPDATE). When false, the
	// legacy split runs: UPSERT without shift columns + BuildShiftFill's
	// companion UPDATE. Set via SetShiftFillFolded.
	foldShift bool

	// bronzeRaw — ADR-0036 §3.6 B1 append-only Bronze dual-write flag
	// (BRONZE_RAW_APPEND). When true, BuildRaw / BuildEventMintRaw emit a
	// pure INSERT into the separate *_raw hypertables ALONGSIDE the
	// byte-identical merged UPSERT. Default false → both return nil, the
	// write path is unchanged. Set via SetBronzeRawAppend.
	bronzeRaw bool

	// rawSeq is the writer-assigned monotonic tiebreak for the append-only
	// Bronze key (id_equipment, ts_value, source_seq). Seeded from the
	// process start time (UnixNano) so values stay monotonic ACROSS restarts
	// too — two same-(equipment, ts_value) samples never collide, and a
	// restart cannot reuse a source_seq an earlier process already wrote.
	rawSeq atomic.Uint64
}

func NewEquipmentValues(r *sparkplug.Resolver, logger *slog.Logger) *EquipmentValues {
	w := &EquipmentValues{resolver: r, logger: logger}
	w.rawSeq.Store(uint64(time.Now().UnixNano()))
	return w
}

// SetShiftResolver enables the ADR-0014 Phase 2 shift fill. Whether it is
// applied as a fold (into the UPSERT) or as a separate companion UPDATE
// (BuildShiftFill) is selected by SetShiftFillFolded.
func (w *EquipmentValues) SetShiftResolver(r *shiftresolver.Resolver) { w.shifts = r }

// SetShiftFillFolded selects the ADR-0014 fold path (SHIFT_FILL_FOLDED).
// true → shift columns folded into the UPSERT + BuildShiftFill returns nil;
// false (default) → legacy split (bare UPSERT + separate UPDATE).
func (w *EquipmentValues) SetShiftFillFolded(folded bool) { w.foldShift = folded }

// SetBronzeRawAppend enables the ADR-0036 §3.6 B1 append-only Bronze
// dual-write (BRONZE_RAW_APPEND). true → BuildRaw / BuildEventMintRaw emit a
// pure INSERT into the *_raw hypertables; false (default) → both return nil
// and the write path is byte-identical to pre-B1.
func (w *EquipmentValues) SetBronzeRawAppend(on bool) { w.bronzeRaw = on }

// sqlShiftFill ports piot_set_shift_on_equipment_values() as a companion
// UPDATE queued right after the metric's UPSERT in the same pgx.Batch. Used
// only on the LEGACY (unfolded) path — when SHIFT_FILL_FOLDED is true the
// same columns ride inside the UPSERT via shiftFold instead. COALESCE
// everywhere = the trigger's "only fill when NULL" semantics; ($1)::date
// matches the trigger's NEW.ts_value::date (session-timezone cast, evaluated
// in this worker's session exactly as the trigger evaluated in the
// inserting session).
const sqlShiftFill = `
	UPDATE %s.equipment_values SET
		id_shift            = COALESCE(id_shift, $3),
		id_shift_hour       = COALESCE(id_shift_hour, $4),
		ts_value_production = COALESCE(ts_value_production, ($1)::date)
	WHERE ts_value = $1 AND id_equipment = $2`

// BuildShiftFill returns the shift-fill *Query for one metric on the LEGACY
// (unfolded) path, or nil when the resolver is disabled, the fold is active
// (SHIFT_FILL_FOLDED=true — the UPSERT carries the columns itself), or the
// topic is unregistered. Fail-open end to end: an unresolvable shift still
// fills ts_value_production and leaves the shift columns NULL — byte-for-byte
// what the trigger did.
func (w *EquipmentValues) BuildShiftFill(ctx context.Context, m *sparkplug.Metric, schema string) (*Query, error) {
	if w.shifts == nil || w.foldShift {
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

	// ADR-0014 fold (flag-gated, SHIFT_FILL_FOLDED): when folding is active
	// resolve the shift ONCE here and thread the labels into the row's own
	// UPSERT (shiftFold), so the separate BuildShiftFill UPDATE can be
	// skipped — halving the per-metric statement count. withShift requires
	// BOTH the resolver enabled AND the fold flag on; when the flag is off
	// the columns are omitted here and the legacy BuildShiftFill UPDATE
	// carries them instead. When on, the fill is fail-open — an unresolvable
	// shift still stamps ts_value_production (($1)::date) and leaves the
	// id_* columns NULL, byte-for-byte what the dropped trigger did.
	withShift := w.shifts != nil && w.foldShift
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

// ── ADR-0036 §3.6 B1 — append-only Bronze dual-write ─────────────────────────
//
// BuildRaw / BuildEventMintRaw are ADDITIVE to Build / BuildEventMint: they run
// only when BRONZE_RAW_APPEND is on and NEVER touch the merged UPSERT path. The
// merged write (Build*) is left byte-identical — this is a dual-write, not a
// cutover. The raw append differs from the merged write in exactly three ways
// that make Bronze the durable replay source (§3.6.3):
//   1. pure INSERT — NO `ON CONFLICT`. Two same-(equipment, ts_value) samples
//      COEXIST via the source_seq tiebreak instead of the second overwriting
//      the first, so no decoded sample is ever lost to a key collision (the
//      structural fix for ADR-0037 (g), §3.4).
//   2. ms-precision ts — NO Truncate(time.Second). The merged write truncates
//      to the whole second (equipment_values.go:194); Bronze keeps what came
//      off the wire.
//   3. a writer-assigned monotonic source_seq column (§5A) as the tiebreak.
//
// The guard chain (resolve / numeric-parse / absurd-value) is re-run here rather
// than shared with Build DELIBERATELY: it keeps Build 100% untouched (the
// paramount B1 requirement) at the cost of a few cheap, deterministic checks on
// the same metric (Resolve is memoised, parse is trivial). The handler only
// reaches BuildRaw after Build already returned a non-nil query, so these guards
// are effectively free cache hits on the hot path.

// rawValuesInsert assembles the append-only equipment_values_raw INSERT from a
// per-kind (cols, args) pair. ingested_at is omitted → the table DEFAULT now()
// stamps arrival time (§5A). No ON CONFLICT: the (id_equipment, ts_value,
// source_seq) PK admits every sample.
func rawValuesInsert(schema string, cols []string, args []any, eq int, ts time.Time, kind string) *Query {
	ph := make([]string, len(args))
	for i := range args {
		ph[i] = fmt.Sprintf("$%d", i+1)
	}
	return &Query{
		SQL: fmt.Sprintf("INSERT INTO %s.equipment_values_raw (%s) VALUES (%s)",
			schema, strings.Join(cols, ", "), strings.Join(ph, ", ")),
		Args: args,
		Desc: fmt.Sprintf("raw-append %s.equipment_values_raw (%s) eq=%d ts=%s",
			schema, kind, eq, ts.Format(time.RFC3339Nano)),
	}
}

// BuildRaw returns the ADR-0036 §3.6 B1 append-only Bronze INSERT for one
// equipment_values sample, or (nil, nil) when the flag is off, the kind does
// not land in equipment_values, the topic is unregistered, or the value is
// non-numeric/absurd (same skip semantics as Build). Additive — the merged
// UPSERT is untouched.
func (w *EquipmentValues) BuildRaw(ctx context.Context, m *sparkplug.Metric, schema string) (*Query, error) {
	if !w.bronzeRaw {
		return nil, nil
	}
	kind := m.Classify()
	if !w.CanWrite(kind) {
		return nil, nil
	}
	info, err := w.resolver.Resolve(ctx, m.TopicForRegister())
	if err != nil {
		return nil, fmt.Errorf("bronze-raw resolve %s: %w", m.TopicForRegister(), err)
	}
	if info == nil {
		return nil, nil
	}
	value, ok := parseNumericValue(m.Value)
	if !ok {
		return nil, nil
	}
	if math.Abs(value) > 1e12 || math.IsNaN(value) || math.IsInf(value, 0) {
		return nil, nil
	}

	// Bronze keeps the ORIGINAL ms-precision ts — NO Truncate(time.Second).
	ts := time.UnixMilli(m.Timestamp).UTC()
	seq := int64(w.rawSeq.Add(1))

	tpEquipment := 1
	if m.IsLineTopic() {
		tpEquipment = 3
	}
	var faults *string
	if len(m.Faults) > 0 && string(m.Faults) != "null" {
		s := string(m.Faults)
		faults = &s
	}
	checkNumber := m.Timestamp

	// Envelope columns common to every kind (mirror the merged write's).
	cols := []string{"ts_value", "id_enterprise", "id_site", "id_area", "id_equipment", "tp_equipment"}
	args := []any{ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment, tpEquipment}

	// Per-kind columns — the SAME columns the corresponding build* func writes.
	switch kind {
	case sparkplug.KindProdProcessedCount:
		cols = append(cols, "net_production_incr", "net_production_val", "speed")
		args = append(args, value, (*float64)(m.Counter), (*float64)(m.CurSpeed))
	case sparkplug.KindProdConsumedCount:
		cols = append(cols, "gross_production_incr", "gross_production_val", "speed")
		args = append(args, value, (*float64)(m.Counter), (*float64)(m.CurSpeed))
	case sparkplug.KindProdDefectiveCount:
		cols = append(cols, "scrap_incr", "scrap_val")
		args = append(args, value, (*float64)(m.Counter))
	case sparkplug.KindStateCurrent:
		cols = append(cols, "state")
		args = append(args, int(value))
	case sparkplug.KindUnitModeCurrent:
		var subMode *string
		if len(m.Alias) > 0 && string(m.Alias) != "null" {
			var s string
			if err := json.Unmarshal(m.Alias, &s); err == nil && s != "" {
				subMode = &s
			}
		}
		cols = append(cols, "mode", "sub_mode")
		args = append(args, int(value), subMode)
	default:
		return nil, nil
	}

	// Tail columns + the Bronze lineage tiebreak.
	cols = append(cols, "signal_quality", "faults", "check_number", "source_seq")
	args = append(args, info.SignalQuality, faults, checkNumber, seq)

	return rawValuesInsert(schema, cols, args, info.IDEquipment, ts, kind.String()), nil
}

// BuildEventMintRaw is the append-only Bronze twin of BuildEventMint: a pure
// INSERT into equipment_events_raw (no ON CONFLICT, ms-precision ts_event,
// source_seq tiebreak). It shadows the SAME scope BuildEventMint mints (a
// StateCurrent sample from status_type=4 equipment) so the raw events table
// tracks exactly what the worker writes to equipment_events. Returns (nil, nil)
// when the flag is off or the scope does not match.
func (w *EquipmentValues) BuildEventMintRaw(ctx context.Context, m *sparkplug.Metric, schema string) (*Query, error) {
	if !w.bronzeRaw {
		return nil, nil
	}
	if m.Classify() != sparkplug.KindStateCurrent {
		return nil, nil
	}
	info, err := w.resolver.Resolve(ctx, m.TopicForRegister())
	if err != nil || info == nil {
		return nil, err
	}
	if info.StatusType != 4 {
		return nil, nil
	}
	var value float64
	if err := json.Unmarshal(m.Value, &value); err != nil {
		return nil, nil // non-numeric state → skip (deterministic, don't nack)
	}
	ts := time.UnixMilli(m.Timestamp).UTC() // ms precision — no Truncate
	seq := int64(w.rawSeq.Add(1))
	return &Query{
		SQL: fmt.Sprintf(`
			INSERT INTO %s.equipment_events_raw (id_equipment, ts_event, id_enterprise, status, source_seq)
			VALUES ($1, $2, $3, $4, $5)`, schema),
		Args: []any{info.IDEquipment, ts, info.IDEnterprise, int(value), seq},
		Desc: fmt.Sprintf("raw-append %s.equipment_events_raw eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339Nano)),
	}, nil
}

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
