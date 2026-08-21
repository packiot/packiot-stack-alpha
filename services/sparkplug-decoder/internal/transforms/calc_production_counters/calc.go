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
	"math"
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

	// ── No-speed guard fallback (ADR-0049, count-loss guard) ───────────────
	// Phase 8's glitch guard is `prodSpeed < 3*machSpeed`. For a machine that
	// reports NO MachSpeed sensor stream, machSpeed is 0, so the bound is 0 and
	// EVERY counter is rejected (prodSpeed<0 is false for any non-negative
	// rate) — the machine emits nothing and its OEE is zero. CountersOnly
	// rescues this by swapping the bound to 3*IdealRate, but ONLY for a machine
	// whose unit topic carries a configured rated speed (COUNTERS_ONLY_IDEAL_RATES
	// or the COUNTERS_ONLY_FROM_DB rate map). A no-speed machine that is ALSO
	// absent from that rate map (e.g. CPACK L8/L10/FLEXO/SLEEVE/CELULA, which
	// only ever flowed because the now-retired mirror-worker-go synthesized
	// their equipment_values) falls through with bound 0 and freezes.
	//
	// When true AND machSpeed==0 AND counters-only mode did NOT already supply a
	// rated-speed bound (IdealRate absent), the rate guard is DISABLED
	// (glitchBound = +Inf) so the counts are not dropped for lack of any speed
	// reference to sanity-check against. This does NOT reintroduce the first-boot
	// totalizer spike (ADR-0045 P1's first-observation seed + ADR-0048 reset-heal
	// zero the delta-from-zero and post-reset spikes BEFORE the guard) and leaves
	// mid-stream glitch protection to the downstream Silver INCREMENT_SANITY_CLAMP
	// (ADR-0037) + the absurd-value guard in the writer. It is the strictly-better
	// choice than dropping 100% of a producing machine's counts.
	//
	// Default false → byte-identical: the else-branch is never taken, glitchBound
	// stays 3*machSpeed exactly as before. A machine that DOES report MachSpeed,
	// or one already covered by counters-only, is unaffected even with the flag
	// on (both keep their real bound). Caller flips it via CALC_NO_SPEED_GUARD_FALLBACK.
	NoSpeedGuardFallback bool

	// ── Reset/rebirth heal (count-spike guard, ADR-0048) ───────────────────
	// The counter increment is a DELTA differenced from the per-topic baseline
	// in State. A genuine totalizer RESET (cur < prev, and not a 16-bit wrap)
	// means the prior baseline no longer describes this stream — a PLC restart,
	// an agent rebirth, or a publisher/source switch to a different totalizer
	// origin. Legacy handleCounterDrop then reseats prev to 0, so the increment
	// becomes cur − 0 = the WHOLE new absolute totalizer: the reset-spike (the
	// same delta-from-zero pathology the first-observation seed already kills,
	// but on a baseline that was PRESENT rather than absent). A source switch to
	// an ~830k totalizer mints an ~830k phantom in one bucket, clamping OEE to a
	// fake 1.0.
	//
	// When true, a genuine reset is HEALED exactly like a first observation:
	// SEED the baseline to cur and emit NOTHING for this sample (increment 0),
	// so the NEXT sample differences correctly. Idempotent, no magic constant —
	// the guard is structural ("no valid baseline ⇒ reseed, never difference
	// from zero"), not a threshold. It drops at most one sample's worth of
	// post-reset counts (negligible; the pre-reset tail was already lost to the
	// reset itself). Default false → byte-identical legacy decode (emit cur),
	// so the golden comparator and existing reset tests are untouched; the
	// caller flips it via CALC_RESET_HEAL_ENABLED.
	ResetHeal bool

	// ── Counter-role override (ADR-0047 P0 #1) ─────────────────────────────
	// packml_register.id_{infeed,outfeed,reject}counter already exist as
	// columns but are unread by Calc — every counter's role (gross/net/scrap)
	// is inferred PURELY from a ProdProcessedCount/ProdConsumedCount/
	// ProdDefectiveCount substring in the topic (parseTopicFull). A client
	// whose PLC counter isn't named that way (e.g. bispharma's "counter168",
	// a CPACK split-instrumentation machine whose gross feed lives on a
	// DIFFERENT machine than its net feed — see docs/clients/
	// bispharma-oee-mapping-fix.md, docs/clients/cpack-counter-semantics-
	// audit.md) is silently dropped (ErrMalformedTopic) or mis-attributed.
	//
	// When RoleKind is not CounterKindUnknown AND RoleUnitTopic is set, Calc
	// uses this pair INSTEAD OF parsing Topic for the unit + kind — the
	// caller (main.go's internal/counterroles.Resolver, DB-backed, TTL-
	// cached) has already resolved, from packml_register, which
	// equipment/line this metric's counts belong to (RoleUnitTopic) and
	// which role it plays (RoleKind: Consumed=infeed/gross,
	// Processed=outfeed/net, Defective=reject/scrap). The per-role sibling
	// state keys are then synthesized as RoleUnitTopic+"/Admin/Prod{Processed,
	// Consumed,Defective}Count" (the same line-own-stream shape Phase 9 already
	// emits — line_aggregation.go) rather than via topic string substitution,
	// because an override topic has no Prod*Count substring to substitute.
	// Phase 9 member→line CSV aggregation is skipped for an override message
	// — DB-role mapping and Parameter30700-CSV-position mapping are
	// alternative mechanisms for the same problem (per
	// bispharma-oee-mapping-fix.md §"Why re-role instead of Phase-9
	// aggregate?"), not layered ones.
	//
	// Zero value (CounterKindUnknown, "") ⇒ byte-identical to today's
	// substring-parse path. Both fields default to zero unless the caller
	// found a populated DB role for this equipment, so a tenant whose
	// packml_register counter-role columns are all NULL (everyone today) is
	// completely unaffected — the ADR-0047 backward-compatibility contract.
	RoleUnitTopic string
	RoleKind      CounterKind
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

	// ADR-0047 P0 #1: a populated DB counter-role override replaces the
	// topic-substring derivation entirely. See Message.RoleKind doc.
	roleOverride := msg.RoleKind != CounterKindUnknown && msg.RoleUnitTopic != ""

	var unitTopic string
	var kind CounterKind
	var flags TriggerFlags
	if roleOverride {
		unitTopic = msg.RoleUnitTopic
		kind = msg.RoleKind
		if sepIdx := strings.Index(msg.Topic, "***"); sepIdx >= 0 {
			flags = parseTriggerFlags(msg.Topic[sepIdx+3:])
		}
	} else {
		var err error
		unitTopic, kind, flags, err = parseTopicFull(msg.Topic)
		if err != nil {
			// Malformed topic — drop silently to match JS behavior (JS uses
			// `topic.split("***")[0]` which never throws; a bad topic just
			// produces empty derived vars and falls through to Phase 11 without
			// emitting metrics).
			return dec, nil
		}
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
	// topic.replace() for this). A role-override topic has no Prod*Count
	// substring for replaceCounterName to substitute, so its siblings are
	// synthesized directly off the resolved unitTopic instead (see
	// Message.RoleKind doc).
	var topicProcessed, topicConsumed, topicDefective string
	if roleOverride {
		topicProcessed = unitTopic + "/Admin/" + CounterKindProcessed.String()
		topicConsumed = unitTopic + "/Admin/" + CounterKindConsumed.String()
		topicDefective = unitTopic + "/Admin/" + CounterKindDefective.String()
	} else {
		topicProcessed = replaceCounterName(baseTopic, kind, CounterKindProcessed)
		topicConsumed = replaceCounterName(baseTopic, kind, CounterKindConsumed)
		topicDefective = replaceCounterName(baseTopic, kind, CounterKindDefective)
	}

	// Read priors from state (JS: parseInt(global.get(topic)); missing→NaN).
	// Missing key → 0 matches JS parseInt(undefined) → NaN, but we treat
	// NaN as 0 for arithmetic (the JS does the same via isNaN guards).
	//
	// We ALSO capture the found bool for each stream: a MISSING baseline
	// (found==false) is not the same as a genuine baseline of 0. It means this
	// is the first sample of the stream since process start / a decoder-agent
	// restart / a State reset — there is no prior absolute to difference
	// against. See the first-observation guard immediately below.
	prevProcessed, foundProcessed := state.Int(topicProcessed)
	prevConsumed, foundConsumed := state.Int(topicConsumed)
	prevDefective, foundDefective := state.Int(topicDefective)

	// ── ADR-0045 P1: first-observation baseline seed ───────────────────────
	// The counter increment is a DELTA differenced from the per-topic baseline
	// held in State. When THIS metric's own baseline is absent, differencing
	// cur−0 would dump the entire absolute totalizer into the increment column
	// — the first-boot production SPIKE (incr == val, ~66% of summed CPACK
	// production) that recurs on every reconnect/restart because memState is
	// process-local and starts empty.
	//
	// The fix: on a genuinely-absent baseline, SEED it to the current absolute
	// and emit NOTHING for this sample (increment 0). The seed persists via
	// dec.StateUpdates (the caller applies them regardless of SendDownstream),
	// so the NEXT sample differences correctly against a real baseline. This
	// makes reconnects/restarts safe without a durable store: every stream is
	// re-seeded on its first post-restart sample instead of spiking. It is
	// distinct from the reset branch below (baseline PRESENT but > cur, a
	// genuine rollback/rollover) — only an ABSENT baseline is seeded-and-zeroed,
	// so steady-state decode is byte-for-byte unchanged.
	var firstObs bool
	var firstObsKey string
	switch kind {
	case CounterKindProcessed:
		firstObs, firstObsKey = !foundProcessed, topicProcessed
	case CounterKindConsumed:
		firstObs, firstObsKey = !foundConsumed, topicConsumed
	case CounterKindDefective:
		firstObs, firstObsKey = !foundDefective, topicDefective
	}
	if firstObs {
		seedVal := msg.Payload
		if seedVal < 0 {
			seedVal = 0
		}
		keyCopy, valCopy := firstObsKey, seedVal
		dec.StateUpdates = append(dec.StateUpdates, StateMutation{
			Kind: "counter.seed_baseline", Key: keyCopy, IntValue: valCopy,
			Setter: func(s State) error { return s.SetInt(keyCopy, valCopy) },
		})
		dec.EnrichedMsg["skipped_reason"] = "first_observation_seed"
		dec.EnrichedMsg["seeded_baseline"] = seedVal
		// SendDownstream stays false: no delta-from-zero spike is emitted.
		return dec, nil
	}

	// Current-counter value from msg.payload; the others start at their
	// last-known values (JS: `ProdConsumedCount = ProdConsumedCount_Last`).
	var curProcessed, curConsumed, curDefective int64
	curProcessed = prevProcessed
	curConsumed = prevConsumed
	curDefective = prevDefective

	sendMsg := false
	resetLineScrap := false
	activeReset := false // did THIS message's own counter genuinely reset?

	switch kind {
	case CounterKindProcessed:
		curProcessed = msg.Payload
		if prevProcessed < curProcessed {
			sendMsg = true
		}
		if prevProcessed > curProcessed {
			var isReset bool
			prevProcessed, isReset = handleCounterDrop(prevProcessed, curProcessed)
			resetLineScrap = isReset
			activeReset = isReset
			sendMsg = true
		}
	case CounterKindConsumed:
		curConsumed = msg.Payload
		if prevConsumed < curConsumed {
			sendMsg = true
		}
		if prevConsumed > curConsumed {
			var isReset bool
			prevConsumed, isReset = handleCounterDrop(prevConsumed, curConsumed)
			resetLineScrap = isReset
			activeReset = isReset
			sendMsg = true
		}
	case CounterKindDefective:
		curDefective = msg.Payload
		if prevDefective < curDefective {
			sendMsg = true
		}
		if prevDefective > curDefective {
			// JS: Defective reset does NOT set reset_line_scrap_counter
			// (only Processed + Consumed do). Preserve.
			var isReset bool
			prevDefective, isReset = handleCounterDrop(prevDefective, curDefective)
			activeReset = isReset
			sendMsg = true
		}
	default:
		// Unknown kind — drop silently.
		return dec, nil
	}

	// ── ADR-0048: reset/rebirth heal (count-spike guard) ────────────────────
	// A genuine reset (not a 16-bit wrap) leaves prev reseated to 0 above, so
	// the increment below would be cur−0 = the whole new absolute totalizer —
	// the reset-spike. Treat it exactly like a first observation: re-seed the
	// baseline to cur and emit nothing, so the NEXT sample differences against a
	// valid baseline. firstObsKey already holds this kind's baseline topic.
	// Structural, idempotent, no magic constant. See Message.ResetHeal.
	if msg.ResetHeal && activeReset {
		seedVal := msg.Payload
		if seedVal < 0 {
			seedVal = 0
		}
		keyCopy, valCopy := firstObsKey, seedVal
		dec.StateUpdates = append(dec.StateUpdates, StateMutation{
			Kind: "counter.reset_seed_baseline", Key: keyCopy, IntValue: valCopy,
			Setter: func(s State) error { return s.SetInt(keyCopy, valCopy) },
		})
		dec.EnrichedMsg["skipped_reason"] = "counter_reset_seed"
		dec.EnrichedMsg["seeded_baseline"] = seedVal
		// SendDownstream stays false: no delta-from-zero reset spike is emitted.
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
	} else if msg.NoSpeedGuardFallback && machSpeed == 0 {
		// ADR-0049: no MachSpeed sensor AND no configured ideal rate → the
		// 3*machSpeed bound is 0 and rejects every count (the 08-13 L8/L10
		// freeze after mirror-worker-go retired). With no speed reference to
		// bound against, DISABLE the rate guard rather than drop production.
		// Spike protection is upstream (first-obs seed / reset-heal) and
		// downstream (Silver INCREMENT_SANITY_CLAMP + absurd-value guard).
		glitchBound = math.MaxFloat64
		dec.EnrichedMsg["no_speed_guard_fallback"] = true
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
	//
	// Skipped for a role-override message: DB-role mapping (RoleKind) and
	// Parameter30700-CSV-position mapping are ALTERNATIVE mechanisms for
	// attributing a member counter to its line, not layered ones (see
	// Message.RoleKind doc). Running Phase 9 here would also re-split
	// msg.Topic assuming the STANDARD 8+-segment per-metric shape
	// (topicArray[7] as machine index), which a role-mapped topic's own
	// naming (e.g. "counter168") has no reason to satisfy.
	if !roleOverride {
		runPhase9LineAggregation(
			&dec, state, msg, unitTopic, timestampMs,
			procIncr, consIncr, curProcessed, curConsumed,
			prodConsumedSet, prodProcessedSet,
			prodSpeed, flags.StateSpeedThis, resetLineScrap,
		)
	}
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

// uint16Rollover is the wrap modulus of a 16-bit PLC counter (e.g. L6-TEXA);
// uint16RolloverBand is how close to that boundary the prior reading must sit
// (and how small the new reading must be) for a downward step to be read as a
// legitimate wrap rather than a reset. The band is deliberately generous on
// the low side (new value) and tight on the high side (prev near the ceiling)
// so only a true wrap qualifies.
const (
	uint16Rollover     = 65536
	uint16RolloverBand = 4096
)

// isUint16Rollover reports whether a downward counter step (cur < prev) is a
// 16-bit wrap: the prior reading sat just below the 65536 ceiling and the new
// reading is small. This distinguishes a benign wrap (legitimate production
// that crossed the boundary) from a genuine totalizer reset.
func isUint16Rollover(prev, cur int64) bool {
	return prev >= uint16Rollover-uint16RolloverBand &&
		prev < uint16Rollover &&
		cur >= 0 && cur < uint16RolloverBand
}

// handleCounterDrop decides the new baseline when a counter reading went DOWN
// (cur < prev). Returns (newPrev, isReset):
//
//   - 16-bit rollover: the counter wrapped the 65536 boundary, so the TRUE
//     increment spans it. We return prev−65536 as the baseline so that
//     cur−newPrev == (65536−prev)+cur (the real wrap delta), and isReset=false
//     (a wrap is not a reset — line-scrap accumulators must not be cleared).
//   - genuine reset/rollback: the totalizer restarted; baseline drops to 0 and
//     the post-reset delta is cur. isReset=true.
//
// This is the point that separates the legitimate 16-bit wrap (L6-TEXA rolls at
// 65,536) from a whole-totalizer artifact — neither of which is the first-boot
// spike, which is caught earlier by the first-observation seed.
func handleCounterDrop(prev, cur int64) (newPrev int64, isReset bool) {
	if isUint16Rollover(prev, cur) {
		return prev - uint16Rollover, false
	}
	return 0, true
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
