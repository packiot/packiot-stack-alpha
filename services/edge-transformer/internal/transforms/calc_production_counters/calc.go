// Package calc_production_counters is the Go port of Node-RED's
// `Calc Production Counters` function (id 1175dbcfce9b9ffa in
// subflows/SparkPlug_v1.10.39.1.json). See:
//   - docs/adr/reference/designs/phase-3-calc-production-counters-port-plan.md — design
//   - docs/adr/reference/designs/phase-3-calc-production-counters-state-machine.md — reference
//   - source.js — verbatim JS extract (line-for-line reference)
//
// The port implements the 11 phases from the state machine doc. Each phase
// is a private helper called sequentially from Calc(); phase failures
// short-circuit via `send_msg=false` matching JS semantics.
//
// Behavioral parity is the goal. When JS and "clean Go" would differ (e.g.
// how errors flow, how NaN reads coerce), JS wins. The comparator's 30-day
// zero-diff soak is the arbiter — do not "fix" JS quirks silently.

package calc_production_counters

import (
	"strings"
	"time"
)

// CounterKind enumerates the counter types the function routes to.
type CounterKind int

const (
	CounterKindUnknown CounterKind = iota
	CounterKindProcessed
	CounterKindConsumed
	CounterKindDefective
)

// String returns the metric-name substring as it appears in Sparkplug topics.
func (k CounterKind) String() string {
	switch k {
	case CounterKindProcessed:
		return "ProdProcessedCount"
	case CounterKindConsumed:
		return "ProdConsumedCount"
	case CounterKindDefective:
		return "ProdDefectiveCount"
	default:
		return "Unknown"
	}
}

// UnitMode mirrors the PackML unit-mode integer. The port only branches on
// SETUP (6) so callers can treat the enum coarsely.
type UnitMode int

const (
	UnitModeUnknown    UnitMode = 0
	UnitModeProduction UnitMode = 1
	UnitModeStarting   UnitMode = 2
	UnitModeExecute    UnitMode = 3
	UnitModeCompleting UnitMode = 4
	UnitModeStopping   UnitMode = 5
	UnitModeSetup      UnitMode = 6 // ← the one Calc actively skips
	UnitModeAborting   UnitMode = 7
)

// Message is the input to Calc.
type Message struct {
	// Topic is the full Sparkplug topic INCLUDING the ***<TRIG> suffix.
	// Example: "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG"
	Topic string

	// Payload is the counter value the PLC reported.
	Payload int64

	// Timestamp is the PLC's sample time. Missing → Calc uses time.Now().
	// (JS: `var d = new Date(); if (msg.timestamp) d = new Date(msg.timestamp);`)
	Timestamp time.Time

	// Tenant is the lowercased GroupID from the topic. Example: "cpack".
	Tenant string

	// CmdTrigger mirrors JS `msg.cmd_trigger` — a boolean gate the upstream
	// SparkPlug decoder sets to true when the message actually represents
	// a triggered production event vs. a heartbeat/mode update.
	CmdTrigger bool

	// SparkPlugTimezone passthrough — attached to emitted metrics unchanged.
	SparkPlugTimezone string

	// SparkPlugAddMetrics — key/value bag merged into every emitted metric.
	// Passthrough for downstream consumers.
	SparkPlugAddMetrics map[string]any

	// ── Counters-only OEE mode (Modbus counters-only client class) ─────────
	// A counters-only machine reports production counters (ProdProcessed /
	// Consumed / Defective) but has NO physical speed sensor, so no MachSpeed
	// metric ever seeds State. Phase 8's default glitch guard
	// `prodSpeed < 3*machSpeed` then evaluates to `prodSpeed < 0`, which is
	// false for every non-negative rate — so EVERY counter is rejected and
	// the machine produces zero OEE.
	//
	// When CountersOnly is true AND IdealRate > 0, Phase 8 replaces the
	// absent-speed guard with a CONFIGURED rated-speed guard
	// (`prodSpeed < countersOnlyGuardK * IdealRate`). This is a strictly
	// better sanity bound (it rejects counter glitches relative to the rated
	// speed the machine is designed for) and it stops rejecting valid counts.
	//
	// Both fields default to zero (false / 0). The caller (main.go) only sets
	// them when COUNTERS_ONLY_OEE_ENABLED is on AND the equipment is opted in
	// via config, so with the flag off behavior is byte-identical to before.
	//
	// IMPORTANT: this does NOT derive Performance from the counts. Performance
	// is computed downstream in the oeecloud-worker rollup as
	// net / (ideal_time * ideal_speed), where ideal_speed comes from the
	// CONFIGURED equipments.production_speed / production_orders.ideal_production_speed
	// — never from a speed derived from the same counts (which would be
	// circular and always ~100%). IdealRate here is used ONLY as the guard
	// bound; it should carry that same configured rated speed for consistency.
	CountersOnly bool
	IdealRate    float64
}

// countersOnlyGuardK is the multiplier for the counters-only glitch guard:
// a derived count-rate above K× the configured rated speed is treated as a
// counter glitch and rejected. K=3 mirrors the original `3*machSpeed` guard's
// 3× tolerance, so the guard's shape is unchanged — only its reference speed
// swaps from the (absent) measured MachSpeed to the configured rated speed.
const countersOnlyGuardK = 3.0

// StateMutation is a deferred state write emitted by Calc. Callers apply
// mutations AFTER inspecting Decision.SendDownstream. Two-phase apply lets
// tests inspect intended writes without needing a live State.
type StateMutation struct {
	// Kind categorises the mutation so tests can group + inspect.
	Kind string
	// Key is the State key to write.
	Key string
	// IntValue / FloatValue / TimeMs / BoolValue / StringsValue — exactly
	// one is populated per mutation, matched to the State setter that
	// should apply it.
	IntValue     int64
	FloatValue   float64
	TimeMs       int64
	BoolValue    bool
	StringsValue []string
	// Setter dispatches the mutation to the right State setter.
	Setter func(State) error
}

// Apply runs the mutation's setter against a live State.
func (m StateMutation) Apply(s State) error {
	if m.Setter == nil {
		return nil
	}
	return m.Setter(s)
}

// Decision is Calc's output.
type Decision struct {
	// SendDownstream: true → caller emits the message; false → drop silently.
	SendDownstream bool

	// EnrichedMsg holds the keys the JS attached to `msg` for downstream
	// consumers. Populated with the same key names for comparator parity.
	EnrichedMsg map[string]any

	// Metrics is the ordered list of metric objects the JS built into
	// `msg.metrics`. Downstream serialization matches JS order.
	Metrics []Metric

	// StateUpdates: mutations the caller should apply to State AFTER
	// evaluating SendDownstream. Empty when Calc didn't touch state.
	StateUpdates []StateMutation
}

// Metric is one entry of the emitted msg.metrics array. Shape mirrors the
// JS object shape verbatim so the comparator can diff at the RMQ boundary.
type Metric struct {
	Name      string  `json:"name"`
	Timestamp int64   `json:"timestamp"` // Unix ms
	Value     int64   `json:"value"`
	Type      string  `json:"type"` // always "int32"
	Counter   int64   `json:"counter"`
	Timezone  string  `json:"timezone,omitempty"`
	CurSpeed  float64 `json:"curspeed,omitempty"`
	// Extra carries msg.SparkPlug_add_metrics passthrough.
	Extra map[string]any `json:"-"`
	// LineAggregated marks a metric produced by Phase-9 member→line
	// AGGREGATION (runPhase9LineAggregation) — as opposed to the unit's or
	// line's OWN differenced counter emitted by Phase 8. The #276 cutover
	// envelope (buildCutoverMetrics) suppresses ONLY these: a Phase-9 line
	// emission double-counts against the pre-existing downstream line
	// derivation (the #456 two-writer bug). The line's OWN-stream Phase-8
	// counter must NOT be suppressed — dropping it left the line's raw
	// totalizer flowing straight into net_production_incr with
	// net_production_val NULL (the ~14,000× cagg-SUM inflation this field
	// fixes: ADR-0037 finding A). Origin-tagged, not name-based, because a
	// Phase-8 own-stream line counter and a Phase-9 aggregation share the
	// same line-level topic NAME and can only be told apart by which phase
	// emitted them. Internal routing only — never serialized.
	LineAggregated bool `json:"-"`
}

// Calc runs the 11-phase decision tree against msg + state and returns
// a Decision the caller applies.
//
// The port implements phases 1-8 + 10-11. Phase 9 (line/sector aggregation)
// is deferred to a follow-up PR — its topology needs line-config fixtures
// the capture binary can't easily produce.
func Calc(msg Message, state State) (Decision, error) {
	dec := Decision{
		EnrichedMsg: map[string]any{},
	}

	// ── Phase 1: parse timestamp + SETUP-mode guard ────────────────────────
	ts := msg.Timestamp
	if ts.IsZero() {
		ts = time.Now()
	}
	timestampMs := ts.UnixMilli()

	// Strip the ***SUFFIX to get the base topic (used for all state keys).
	baseTopic := stripTriggerSuffix(msg.Topic)

	unitTopic, kind, flags, err := parseTopicFull(msg.Topic)
	if err != nil {
		// Malformed topic — drop silently to match JS behavior (JS uses
		// `topic.split("***")[0]` which never throws; a bad topic just
		// produces empty derived vars and falls through to Phase 11 without
		// emitting metrics).
		return dec, nil
	}

	// SETUP-mode short-circuit. The JS reads the "modes" global and only
	// sets unit_mode=6 if node.type==6 (Node-RED-specific config check).
	// The port matches by checking UnitMode(unitTopic) == SETUP.
	if m, ok := state.UnitMode(unitTopic); ok && m == UnitModeSetup {
		// Drop silently — SETUP mode means don't count production.
		dec.EnrichedMsg["skipped_reason"] = "unit_mode_setup"
		return dec, nil
	}

	// ── Phase 2: trigger dispatch + read prior counter values ──────────────
	if !msg.CmdTrigger {
		// JS: the entire counter body is wrapped in `if (msg.cmd_trigger)`.
		// Non-trigger messages fall through without emitting.
		dec.EnrichedMsg["skipped_reason"] = "no_cmd_trigger"
		return dec, nil
	}

	// Derive the sibling topics for the other two counters (JS uses
	// topic.replace() for this).
	topicProcessed := replaceCounterName(baseTopic, kind, CounterKindProcessed)
	topicConsumed := replaceCounterName(baseTopic, kind, CounterKindConsumed)
	topicDefective := replaceCounterName(baseTopic, kind, CounterKindDefective)

	// Read priors from state (JS: parseInt(global.get(topic)); missing→NaN).
	// Missing key → 0 matches JS parseInt(undefined) → NaN, but we treat
	// NaN as 0 for arithmetic (the JS does the same via isNaN guards).
	prevProcessed, _ := state.Int(topicProcessed)
	prevConsumed, _ := state.Int(topicConsumed)
	prevDefective, _ := state.Int(topicDefective)

	// Current-counter value from msg.payload; the others start at their
	// last-known values (JS: `ProdConsumedCount = ProdConsumedCount_Last`).
	var curProcessed, curConsumed, curDefective int64
	curProcessed = prevProcessed
	curConsumed = prevConsumed
	curDefective = prevDefective

	sendMsg := false
	resetLineScrap := false

	switch kind {
	case CounterKindProcessed:
		curProcessed = msg.Payload
		if prevProcessed < curProcessed {
			sendMsg = true
		}
		if prevProcessed > curProcessed {
			prevProcessed = 0
			resetLineScrap = true
			sendMsg = true
		}
	case CounterKindConsumed:
		curConsumed = msg.Payload
		if prevConsumed < curConsumed {
			sendMsg = true
		}
		if prevConsumed > curConsumed {
			prevConsumed = 0
			resetLineScrap = true
			sendMsg = true
		}
	case CounterKindDefective:
		curDefective = msg.Payload
		if prevDefective < curDefective {
			sendMsg = true
		}
		if prevDefective > curDefective {
			prevDefective = 0
			// JS: Defective reset does NOT set reset_line_scrap_counter
			// (only Processed + Consumed do). Preserve.
			sendMsg = true
		}
	default:
		// Unknown kind — drop silently.
		return dec, nil
	}

	// Compute pre-correction increments (Phase 3 output).
	procIncr := curProcessed - prevProcessed
	consIncr := curConsumed - prevConsumed
	defIncr := curDefective - prevDefective

	// Attach debug fields — JS mutates msg.* directly. The comparator will
	// diff these key-by-key.
	dec.EnrichedMsg["ProdConsumedCount"] = curConsumed
	dec.EnrichedMsg["ProdConsumedCount_Last"] = prevConsumed
	dec.EnrichedMsg["ProdConsumedIncremet"] = consIncr
	dec.EnrichedMsg["ProdProcessedCount"] = curProcessed
	dec.EnrichedMsg["ProdProcessedCount_Last"] = prevProcessed
	dec.EnrichedMsg["ProdProcessedIncremet"] = procIncr
	dec.EnrichedMsg["ProdDefectiveCount"] = curDefective
	dec.EnrichedMsg["ProdDefectiveCount_Last"] = prevDefective
	dec.EnrichedMsg["ProdDefectiveIncremet"] = defIncr

	// ── Phase 4: TRIG suffix corrections (only when sendMsg==true) ─────────
	if sendMsg && flags.TrigBase {
		curProcessed, curConsumed, curDefective = applyTrigCorrections(
			curProcessed, curConsumed, curDefective,
			prevProcessed, prevConsumed, prevDefective,
			flags, state, baseTopic, topicConsumed, topicDefective,
		)
		// Recompute increments with corrected values.
		procIncr = curProcessed - prevProcessed
		consIncr = curConsumed - prevConsumed
		defIncr = curDefective - prevDefective
	}

	// ── Phase 5: persist new counter values ────────────────────────────────
	if sendMsg {
		// JS: negative → write 0 instead (v1.10.2 defensive).
		writeNonNegative := func(topic string, v int64, kind string) {
			if v < 0 {
				v = 0
			}
			topicCopy, vCopy := topic, v
			dec.StateUpdates = append(dec.StateUpdates, StateMutation{
				Kind: kind, Key: topicCopy, IntValue: vCopy,
				Setter: func(s State) error { return s.SetInt(topicCopy, vCopy) },
			})
		}
		writeNonNegative(topicProcessed, curProcessed, "counter.processed")
		writeNonNegative(topicConsumed, curConsumed, "counter.consumed")
		writeNonNegative(topicDefective, curDefective, "counter.defective")

		// Custom counter for Parameter*30770*=true units (JS §Phase 5 tail).
		p30770Key := unitTopic + "/Status/Parameter*30770*"
		if enabled, _ := state.Bool(p30770Key); enabled {
			p30772Key := unitTopic + "/Status/Parameter*30772*"
			prior, _ := state.Int(p30772Key)
			newVal := prior + consIncr
			p30772KeyCopy := p30772Key
			newValCopy := newVal
			dec.StateUpdates = append(dec.StateUpdates, StateMutation{
				Kind: "counter.custom_30772", Key: p30772KeyCopy, IntValue: newValCopy,
				Setter: func(s State) error { return s.SetInt(p30772KeyCopy, newValCopy) },
			})
		}
	}

	// ── Phase 6: compute ProdSpeed ─────────────────────────────────────────
	prodSpeed := computeSpeed(state, unitTopic, timestampMs, consIncr, &dec)

	// Apply counter multiplier (Parameter*30710*).
	multKey := unitTopic + "/Status/Parameter*30710*"
	if mult, ok := state.Int(multKey); ok && mult > 0 {
		consIncr *= mult
		procIncr *= mult
		defIncr *= mult
		prodSpeed *= float64(mult)
	}

	// ── Phase 7: read threshold config ─────────────────────────────────────
	machSpeed, _ := state.Float(unitTopic + "/Status/MachSpeed")
	thresholdQuant, _ := state.Float(unitTopic + "/Status/Parameter*30750*")
	thresholdMode, _ := state.Int(unitTopic + "/Status/Parameter30758")

	dec.EnrichedMsg["machspeed"] = machSpeed

	// ── Phase 8 glitch-guard bound ─────────────────────────────────────────
	// The default guard rejects a metric whose derived rate exceeds 3× the
	// measured machine speed (a counter glitch / rollover artifact). For a
	// counters-only machine machSpeed is absent (0), which would reject every
	// count. In counters-only mode we swap the reference to the CONFIGURED
	// rated speed. The bound is identical to `3*machSpeed` whenever the mode
	// is off, so flag-off behavior is byte-for-byte unchanged.
	glitchBound := 3 * machSpeed
	countersOnly := msg.CountersOnly && msg.IdealRate > 0 && machSpeed == 0
	if countersOnly {
		glitchBound = countersOnlyGuardK * msg.IdealRate
		dec.EnrichedMsg["counters_only_mode"] = true
		dec.EnrichedMsg["ideal_rate"] = msg.IdealRate
	}

	// ── Phase 8: emit unit metrics ─────────────────────────────────────────
	// JS resets sendMsg to false and each metric emission that succeeds
	// sets it back to true.
	sendMsg = false
	statusTopicName := ""
	status := 0
	prodConsumedSet := false
	prodProcessedSet := false

	// Consumed metric — also owns threshold logic in the base case.
	if consIncr > 0 && curConsumed >= 0 && prodSpeed < glitchBound {
		metric := Metric{
			Timestamp: timestampMs,
			Name:      topicConsumed,
			Value:     consIncr,
			Type:      "int32",
			Counter:   curConsumed,
			Timezone:  msg.SparkPlugTimezone,
			Extra:     msg.SparkPlugAddMetrics,
		}
		if !flags.StateSpeedThis {
			metric.CurSpeed = round1(prodSpeed)
		}
		dec.Metrics = append(dec.Metrics, metric)

		// Threshold logic (only if NOT STATESPEED_THIS variant).
		if !flags.StateSpeedThis {
			thresholdVal := machSpeed * thresholdQuant / 100.0
			// Mode 4: rolling 2.5-min average threshold.
			if thresholdMode == 4 {
				thresholdVal = rollingAvgThreshold(state, unitTopic, curConsumed, timestampMs)
			}
			if prodSpeed >= thresholdVal {
				status = 6
				statusTopicName = topicConsumed
			}
		}
		sendMsg = true
		prodConsumedSet = true
	}

	// Processed metric.
	if procIncr > 0 && curProcessed >= 0 && prodSpeed < glitchBound {
		metric := Metric{
			Timestamp: timestampMs,
			Name:      topicProcessed,
			Value:     procIncr,
			Type:      "int32",
			Counter:   curProcessed,
			Timezone:  msg.SparkPlugTimezone,
			Extra:     msg.SparkPlugAddMetrics,
		}
		if flags.StateSpeedThis {
			metric.CurSpeed = round2(prodSpeed)
		}
		dec.Metrics = append(dec.Metrics, metric)

		// STATESPEED_THIS variant: threshold logic moves here from Consumed.
		if flags.StateSpeedThis {
			thresholdVal := machSpeed * thresholdQuant / 100.0
			if thresholdMode == 4 {
				thresholdVal = rollingAvgThreshold(state, unitTopic, curConsumed, timestampMs)
			}
			if prodSpeed >= thresholdVal {
				status = 6
				statusTopicName = topicProcessed
			}
		}
		sendMsg = true
		prodProcessedSet = true
	}

	// Defective metric. NB: JS also checks defIncr < 3*machspeed here (not
	// prodSpeed). Preserve that: when counters-only mode is off, glitchBound
	// is exactly 3*machSpeed so parity holds. In counters-only mode the same
	// rated-speed bound applies so scrap counters aren't universally rejected
	// when machSpeed is absent.
	if defIncr > 0 && curDefective >= 0 && float64(defIncr) < glitchBound {
		metric := Metric{
			Timestamp: timestampMs,
			Name:      topicDefective,
			Value:     defIncr,
			Type:      "int32",
			Counter:   curDefective,
			Timezone:  msg.SparkPlugTimezone,
			Extra:     msg.SparkPlugAddMetrics,
		}
		dec.Metrics = append(dec.Metrics, metric)
		sendMsg = true
	}

	// ── Phase 9: line/sector aggregation ──────────────────────────────────
	// If the unit is part of a LINE (Parameter30700 CSV set on the LINE
	// topic), and the unit's machine index is first-in-CSV or last-in-CSV,
	// this bumps LINE-level Consumed / Processed / Defective aggregates.
	// Also handles SECTOR::LINE units with a double pass.
	//
	// State-machine doc §1 Phase 9 + source.js lines 605-800.
	runPhase9LineAggregation(
		&dec, state, msg, unitTopic, timestampMs,
		procIncr, consIncr, curProcessed, curConsumed,
		prodConsumedSet, prodProcessedSet,
		prodSpeed, flags.StateSpeedThis, resetLineScrap,
	)
	if len(dec.Metrics) > 0 {
		sendMsg = true
	}

	// ── Phase 10: status metric ───────────────────────────────────────────
	if status == 6 && statusTopicName != "" {
		p30763Key := lineTopicOf(unitTopic) + "/Status/Parameter*30763*"
		autoStatusDisabled, _ := state.Bool(p30763Key)
		if !autoStatusDisabled {
			statusMetric := statusMetricFor(statusTopicName, status, timestampMs, msg)
			dec.Metrics = append(dec.Metrics, statusMetric)
			registerStatusTopic(state, statusMetric.Name, &dec)
		}
	}

	// ── Phase 11: return ──────────────────────────────────────────────────
	dec.SendDownstream = sendMsg
	return dec, nil
}

// stripTriggerSuffix returns everything before "***" in the topic, matching
// JS `msg.topic.split("***")[0]`.
func stripTriggerSuffix(topic string) string {
	idx := strings.Index(topic, "***")
	if idx < 0 {
		return topic
	}
	return topic[:idx]
}

// replaceCounterName swaps the metric-name segment in a base topic. Given
// a Processed topic and target=Consumed, returns the Consumed topic.
func replaceCounterName(baseTopic string, from, to CounterKind) string {
	if from == to {
		return baseTopic
	}
	fromStr := from.String()
	toStr := to.String()
	return strings.Replace(baseTopic, fromStr, toStr, 1)
}

// lineTopicOf extracts the line topic (first 4 segments) from a unit topic
// (5 segments). Handles the "SECTOR::LINE" naming convention by returning
// the first "::"-separated part.
func lineTopicOf(unitTopic string) string {
	parts := strings.Split(unitTopic, "/")
	if len(parts) < 4 {
		return unitTopic
	}
	line := parts[3]
	if idx := strings.Index(line, "::"); idx >= 0 {
		line = line[:idx]
	}
	parts = parts[:4]
	parts[3] = line
	return strings.Join(parts, "/")
}

// round1 rounds to 1 decimal place (matches JS `parseFloat(x).toFixed(1)`).
func round1(v float64) float64 {
	return float64(int64(v*10+0.5)) / 10.0
}

// round2 rounds to 2 decimal places.
func round2(v float64) float64 {
	return float64(int64(v*100+0.5)) / 100.0
}
