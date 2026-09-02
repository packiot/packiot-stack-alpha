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

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/shiftresolver"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
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

	// clamp — the per-equipment production-increment SANITY CLAMP
	// (ADR-0037 Silver invariant). nil ⇒ disabled
	// (INCREMENT_SANITY_CLAMP_ENABLED=false), the default; when nil Build
	// behaves byte-for-byte as before. Set via SetIncrementClamp.
	clamp *incrementClamp

	// bronzeRaw — ADR-0036 B1 medallion dual-write flag (BRONZE_RAW_APPEND).
	// false (default) ⇒ BuildRawAppend / BuildEventMintRaw return nil and no
	// _raw INSERT is ever queued, so the writer is byte-for-byte the old
	// behavior. true ⇒ every merged UPSERT is shadowed by an append-only
	// INSERT into the immutable Bronze *_raw hypertable. Set via
	// SetBronzeRawAppend.
	bronzeRaw bool

	// unresolved — Prometheus counter for the "unroutable topic" silent drop
	// (packml_unresolved_topic_total). Incremented once per metric whose
	// packml_topic resolves to no active packml_register row, labelled by
	// tenant. nil (default) ⇒ no-op, so unit tests that construct the writer
	// without metrics keep the old behavior byte-for-byte. Set via
	// SetUnresolvedMetric. Same nil-guarded direct-CounterVec idiom the
	// handler uses for batchWrites.
	unresolved *prometheus.CounterVec
}

func NewEquipmentValues(r *sparkplug.Resolver, logger *slog.Logger) *EquipmentValues {
	return &EquipmentValues{resolver: r, logger: logger}
}

// SetUnresolvedMetric wires the packml_unresolved_topic_total counter so the
// "topic not registered, skipping" branch — until now visible only in a 1/32
// sampled log — emits a real, alertable signal. Passing nil leaves it a no-op.
func (w *EquipmentValues) SetUnresolvedMetric(vec *prometheus.CounterVec) { w.unresolved = vec }

// tenantFromTopic derives the tenant (group_id) label from a metric name:
// the lowercased first '/'-separated segment. Mirrors handlers.tenantOf and
// packml_register tenant discovery (lower(split_part(packml_topic,'/',1))),
// keeping label cardinality bounded to one series per onboarded client
// rather than one per (unbounded) full topic string.
func tenantFromTopic(name string) string {
	if idx := strings.IndexByte(name, '/'); idx > 0 {
		return strings.ToLower(name[:idx])
	}
	if name != "" {
		return strings.ToLower(name)
	}
	return "unknown"
}

// SetIncrementClamp enables the production-increment sanity clamp
// (INCREMENT_SANITY_CLAMP_ENABLED). k is the plausibility factor
// (K·rate·Δt) and minDtSec floors Δt so a burst of sub-interval samples
// can't produce a near-zero bound that false-positives a legitimate count.
// Passing enabled=false leaves the clamp nil (no-op — flag-off parity).
func (w *EquipmentValues) SetIncrementClamp(enabled bool, k float64, minDtSec int, spikeFloor float64) {
	if !enabled {
		w.clamp = nil
		return
	}
	if k <= 0 {
		k = 4.0
	}
	if minDtSec <= 0 {
		minDtSec = 60
	}
	if spikeFloor <= 0 {
		// Default: 1000 parts. Spikes are the whole totalizer (5–6 digits);
		// a benign reset that ticks up a few parts (value==absolute, small) is
		// well under this, so it is never mistaken for a spike.
		spikeFloor = 1000
	}
	w.clamp = &incrementClamp{
		k:          k,
		minDt:      time.Duration(minDtSec) * time.Second,
		spikeFloor: spikeFloor,
		last:       make(map[clampKey]int64),
		logger:     w.logger,
	}
}

// SetBronzeRawAppend toggles the ADR-0036 B1 medallion Bronze dual-write
// (BRONZE_RAW_APPEND). enabled=false (default) leaves BuildRawAppend /
// BuildEventMintRaw returning nil — no _raw INSERT is ever queued, so the
// writer is byte-for-byte the old behavior.
func (w *EquipmentValues) SetBronzeRawAppend(enabled bool) { w.bronzeRaw = enabled }

// SetShiftResolver enables the ADR-0014 Phase 2 shift fill. Whether it is
// applied as a fold (into the UPSERT) or as a separate companion UPDATE
// (BuildShiftFill) is selected by SetShiftFillFolded.
func (w *EquipmentValues) SetShiftResolver(r *shiftresolver.Resolver) { w.shifts = r }

// SetShiftFillFolded selects the ADR-0014 fold path (SHIFT_FILL_FOLDED).
// true → shift columns folded into the UPSERT + BuildShiftFill returns nil;
// false (default) → legacy split (bare UPSERT + separate UPDATE).
func (w *EquipmentValues) SetShiftFillFolded(folded bool) { w.foldShift = folded }

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

// Build returns the *Query for one metric, or (nil, nil, nil) when the topic
// is not in packml_register (skip — not a write error). Returns an error
// for unexpected kinds or unparseable values.
//
// The middle return is a non-nil *ClampEvent ONLY when the increment sanity
// clamp (INCREMENT_SANITY_CLAMP_ENABLED) rejected this metric's increment: the
// *Query already carries the clamped (zeroed) value, and the caller records
// the event as a data_quality_event (observability, best-effort). It is always
// nil when the clamp is disabled — flag-off is byte-for-byte the old behavior.
//
// The `schema` parameter selects the target schema (public vs shadow_go_port
// per ADR-0010 Phase 3 shadow-mode DB comparison). Caller validates the
// value against a whitelist before calling — the writer trusts it.
func (w *EquipmentValues) Build(ctx context.Context, m *sparkplug.Metric, _ string, schema string) (*Query, *ClampEvent, error) {
	kind := m.Classify()
	if !w.CanWrite(kind) {
		return nil, nil, fmt.Errorf("EquipmentValues.Build called with unsupported kind %s", kind)
	}

	topic := m.TopicForRegister()
	info, err := w.resolver.Resolve(ctx, topic)
	if err != nil {
		return nil, nil, fmt.Errorf("resolve topic %s: %w", topic, err)
	}
	if info == nil {
		// Make the silent unroutable-topic drop LOUD: a topic with no active
		// packml_register row is acked-not-nacked (retry can't conjure the
		// row), so without this counter a missing/inactive routing row
		// produces ZERO equipment_values with green pipelines. Counter is
		// tenant-labelled (bounded) and always fires; the full topic still
		// rides the 1/32 sampled log below for debugging. nil-guarded so the
		// metric is optional (unit tests, flag-off parity).
		if w.unresolved != nil {
			w.unresolved.WithLabelValues(tenantFromTopic(m.Name)).Inc()
		}
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
		return nil, nil, nil
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
		return nil, nil, nil
	}
	// Absurd-value guard (oscillator incident 2026-07-04): no factory
	// counter/state value approaches 1e12; beyond it the payload is
	// corrupt — skip with a loud log rather than poison the stream.
	if math.Abs(value) > 1e12 || math.IsNaN(value) || math.IsInf(value, 0) {
		w.logger.Error("equipment_values: ABSURD value rejected (stream-poison guard)",
			slog.String("name", m.Name), slog.Float64("value", value))
		return nil, nil, nil
	}

	// ── Increment sanity clamp (ADR-0037 Silver invariant, flag-gated) ──────
	// For the three production counters, reject a physically-impossible
	// increment (> K · rated_speed · Δt) BEFORE it reaches the UPSERT and the
	// cagg SUM. w.clamp is nil (default) → no-op, value unchanged. clampEv is
	// non-nil only when this metric was clamped; the caller records it.
	var clampEv *ClampEvent
	if w.clamp != nil {
		switch kind {
		case sparkplug.KindProdProcessedCount,
			sparkplug.KindProdConsumedCount,
			sparkplug.KindProdDefectiveCount:
			var rate float64
			if info.ProductionSpeed != nil {
				rate = float64(*info.ProductionSpeed)
			}
			// absolute = the cumulative totalizer (net/gross/scrap_val). The
			// clamp compares it to the increment to catch the delta-from-zero
			// spike (value >= absolute) even when rate is unset — the line-lead
			// path. m.Counter is nil for producers that omit it → absolute 0 →
			// spike catch inert, rate·Δt path unaffected.
			var absolute float64
			if m.Counter != nil {
				absolute = float64(*m.Counter)
			}
			value, clampEv = w.clamp.eval(info.IDEquipment, info.IDEnterprise, kind, m.Timestamp, rate, value, absolute)
		}
	}

	// ── Derived-speed sanity void (couples to the increment clamp) ──────────
	// equipment_values.speed rides the counter metrics as m.CurSpeed, the
	// decode Phase-6 derived rate (incr·60000/Δt). It is NOT the count, so the
	// increment clamp above never touched it — yet the two derive from the SAME
	// delta, and the ADR-0049 no-speed-guard fallback deliberately disables the
	// decode rate guard for no-MachSpeed machines, delegating spike protection
	// to THIS Silver clamp (calc.go:599-600). Left unbounded, a glitch/tiny-Δt
	// delta lands speeds thousands of times over rated (id 55 L5-PTH: up to
	// 3.7M/min vs a 147/min rating). Void the speed when the coupled count was
	// clamped OR when the speed itself exceeds K·rate, so the UPSERT's
	// COALESCE(EXCLUDED.speed, existing) carries the prior good speed forward.
	// w.clamp nil (flag off) ⇒ curspeed passes through untouched — flag parity.
	curspeed := (*float64)(m.CurSpeed)
	if w.clamp != nil && curspeed != nil &&
		(kind == sparkplug.KindProdProcessedCount || kind == sparkplug.KindProdConsumedCount) {
		var rate float64
		if info.ProductionSpeed != nil {
			rate = float64(*info.ProductionSpeed)
		}
		if reject, bound := w.clamp.evalSpeed(clampEv != nil, rate, *curspeed); reject {
			if w.logger != nil {
				w.logger.Warn("increment sanity clamp VOIDED implausible derived speed",
					slog.Int("id_equipment", info.IDEquipment),
					slog.String("kind", kind.String()),
					slog.Float64("speed", *curspeed),
					slog.Float64("bound", bound),
					slog.Bool("count_clamped", clampEv != nil),
					slog.Float64("rate_per_min", rate),
				)
			}
			curspeed = nil
		}
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
		return buildProcessed(ts, info, tpEquipment, value, (*float64)(m.Counter), curspeed, faults, checkNumber, schema, withShift, idShift, idShiftHour), clampEv, nil
	case sparkplug.KindProdConsumedCount:
		return buildConsumed(ts, info, tpEquipment, value, (*float64)(m.Counter), curspeed, faults, checkNumber, schema, withShift, idShift, idShiftHour), clampEv, nil
	case sparkplug.KindProdDefectiveCount:
		return buildDefective(ts, info, tpEquipment, value, (*float64)(m.Counter), faults, checkNumber, schema, withShift, idShift, idShiftHour), clampEv, nil
	case sparkplug.KindStateCurrent:
		return buildState(ts, info, tpEquipment, int(value), faults, checkNumber, schema, withShift, idShift, idShiftHour), nil, nil
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
		return buildMode(ts, info, tpEquipment, int(value), subMode, faults, checkNumber, schema, withShift, idShift, idShiftHour), nil, nil
	}
	return nil, nil, nil
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

// ── ADR-0036 B1 — Bronze raw append (medallion immutable landing zone) ────────

// BuildRawAppend produces the append-only INSERT into %s.equipment_values_raw for
// one metric — flag-gated (BRONZE_RAW_APPEND via SetBronzeRawAppend). Returns nil
// when the flag is off, the kind is not an equipment_values kind, the topic is
// unregistered, or the value is non-numeric/absurd (the SAME skip semantics as
// Build, so Bronze receives exactly the samples the merged UPSERT would have).
// Unlike the merged UPSERT it:
//   - appends every sample (NO ON CONFLICT) — a per-second column collision that
//     the merged write folds into ONE row is preserved here as N distinct rows,
//     disambiguated by the source_seq sequence default;
//   - keeps the ORIGINAL sub-second precision (NO Truncate(time.Second));
//   - stores the RAW value — the increment sanity clamp is a Silver invariant and
//     is deliberately NOT applied to Bronze (corrections land as new appended rows,
//     never in-place edits — enforced by the bronze_raw_no_mutate trigger).
func (w *EquipmentValues) BuildRawAppend(ctx context.Context, m *sparkplug.Metric, schema string) (*Query, error) {
	if !w.bronzeRaw {
		return nil, nil
	}
	kind := m.Classify()
	if !w.CanWrite(kind) {
		return nil, nil
	}
	info, err := w.resolver.Resolve(ctx, m.TopicForRegister())
	if err != nil {
		return nil, err
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
	ts := time.UnixMilli(m.Timestamp).UTC() // FULL precision — no Truncate.

	tpEquipment := 1
	if m.IsLineTopic() {
		tpEquipment = 3
	}
	var faults *string
	if len(m.Faults) > 0 && string(m.Faults) != "null" {
		s := string(m.Faults)
		faults = &s
	}
	var subMode *string
	if kind == sparkplug.KindUnitModeCurrent && len(m.Alias) > 0 && string(m.Alias) != "null" {
		var s string
		if err := json.Unmarshal(m.Alias, &s); err == nil && s != "" {
			subMode = &s
		}
	}
	return buildRawAppend(kind, ts, info, tpEquipment, value,
		(*float64)(m.Counter), (*float64)(m.CurSpeed), subMode, faults, m.Timestamp, schema), nil
}

// buildRawAppend assembles the append-only INSERT into <schema>.equipment_values_raw,
// mirroring — per kind — the exact column set the corresponding merged builder writes
// (buildProcessed/buildConsumed/buildDefective/buildState/buildMode), minus the
// shift-fold columns (shift resolution is a Silver enrichment, not raw truth) and with
// NO ON CONFLICT clause. source_seq is left to its sequence default so every append is
// a distinct row even when (id_equipment, ts_value) collide.
func buildRawAppend(
	kind sparkplug.MetricKind, ts time.Time, info *sparkplug.EquipmentInfo,
	tpEquipment int, value float64, counter, curspeed *float64, subMode, faults *string,
	checkNumber int64, schema string,
) *Query {
	cols := "ts_value, id_enterprise, id_site, id_area, id_equipment, tp_equipment"
	args := []any{ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment, tpEquipment}
	switch kind {
	case sparkplug.KindProdProcessedCount:
		cols += ", net_production_incr, net_production_val, speed, signal_quality, faults, check_number"
		args = append(args, value, counter, curspeed, info.SignalQuality, faults, checkNumber)
	case sparkplug.KindProdConsumedCount:
		cols += ", gross_production_incr, gross_production_val, speed, signal_quality, faults, check_number"
		args = append(args, value, counter, curspeed, info.SignalQuality, faults, checkNumber)
	case sparkplug.KindProdDefectiveCount:
		cols += ", scrap_incr, scrap_val, signal_quality, faults, check_number"
		args = append(args, value, counter, info.SignalQuality, faults, checkNumber)
	case sparkplug.KindStateCurrent:
		cols += ", state, signal_quality, faults, check_number"
		args = append(args, int(value), info.SignalQuality, faults, checkNumber)
	case sparkplug.KindUnitModeCurrent:
		cols += ", mode, sub_mode, signal_quality, faults, check_number"
		args = append(args, int(value), subMode, info.SignalQuality, faults, checkNumber)
	default:
		return nil
	}
	return &Query{
		SQL: fmt.Sprintf("INSERT INTO %s.equipment_values_raw (%s) VALUES (%s)",
			schema, cols, placeholders(len(args))),
		Args: args,
		Desc: fmt.Sprintf("bronze-append %s.equipment_values_raw (%s) eq=%d ts=%s",
			schema, kind.String(), info.IDEquipment, ts.Format(time.RFC3339Nano)),
	}
}

// BuildEventMintRaw is the Bronze append companion to BuildEventMint (ADR-0036 B1).
// When BRONZE_RAW_APPEND is on it appends the raw state event to the immutable
// equipment_events_raw with NO ON CONFLICT and ORIGINAL precision. Mirrors
// BuildEventMint's scope EXACTLY (KindStateCurrent, status_type=4; the caller gates
// on shadow SourceType) so Bronze receives the same events the merged mint would.
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
		return nil, fmt.Errorf("parse state value (name=%s): %w", m.Name, err)
	}
	ts := time.UnixMilli(m.Timestamp).UTC() // FULL precision — no Truncate.
	return &Query{
		SQL: fmt.Sprintf(
			"INSERT INTO %s.equipment_events_raw (id_equipment, ts_event, id_enterprise, status) VALUES ($1, $2, $3, $4)",
			schema),
		Args: []any{info.IDEquipment, ts, info.IDEnterprise, int(value)},
		Desc: fmt.Sprintf("bronze-append %s.equipment_events_raw eq=%d ts=%s",
			schema, info.IDEquipment, ts.Format(time.RFC3339Nano)),
	}, nil
}

// placeholders returns a comma-separated "$1, $2, …, $n" parameter list.
func placeholders(n int) string {
	var b strings.Builder
	for i := 1; i <= n; i++ {
		if i > 1 {
			b.WriteString(", ")
		}
		b.WriteByte('$')
		b.WriteString(strconv.Itoa(i))
	}
	return b.String()
}
