// Package calc_production_counters is the Go port of Node-RED's
// `Calc Production Counters` function (id 1175dbcfce9b9ffa in
// subflows/SparkPlug_v1.10.39.1.json). See
// docs/phase-3-calc-production-counters-port-plan.md for the design +
// comparator validation strategy.
//
// STATUS (2026-07-01, ADR-0010 Phase 3 scaffold):
// This is the package skeleton — types + interfaces match the plan
// exactly, but Calc() itself returns ErrNotImplemented. The actual
// port lands in a follow-up PR once the source.js fixture corpus is
// captured from staging.
//
// The scaffold exists NOW so:
//   1. The public API is locked in before implementation starts
//      (comparator harness can be built against this stable shape).
//   2. Downstream code (main.go wiring, tests, comparator) can start
//      compiling + reviewing without waiting for the port.
//   3. Reviewers can catch API-level issues BEFORE 998 LOC of JS-to-Go
//      translation lands.
package calc_production_counters

import (
	"errors"
	"time"
)

// ErrNotImplemented is returned by Calc until the actual port lands.
// Callers can errors.Is check for this to distinguish "scaffold running"
// from "real error."
var ErrNotImplemented = errors.New("calc_production_counters: not yet ported")

// CounterKind enumerates the counter types the function routes to. Matches
// the `***<TRIG>` suffix parsing in the JS source.
type CounterKind int

const (
	CounterKindUnknown CounterKind = iota
	CounterKindProcessed
	CounterKindConsumed
	CounterKindScrapped
	CounterKindTrigger
)

// String returns the trigger suffix as it appears in Sparkplug topics.
func (k CounterKind) String() string {
	switch k {
	case CounterKindProcessed:
		return "OUT"
	case CounterKindConsumed:
		return "IN"
	case CounterKindScrapped:
		return "SCRAPED"
	case CounterKindTrigger:
		return "TRIG"
	default:
		return "UNKNOWN"
	}
}

// UnitMode mirrors the mode integer stored in global.modes[i].type.
// PackML has 8 canonical states; the JS function only cares about SETUP
// (skips processing) so callers can treat the enum coarsely.
type UnitMode int

const (
	UnitModeUnknown  UnitMode = 0
	UnitModeIdle     UnitMode = 1
	UnitModeStarting UnitMode = 2
	UnitModeExecute  UnitMode = 3
	UnitModeCompleting UnitMode = 4
	UnitModeStopping UnitMode = 5
	UnitModeSetup    UnitMode = 6 // ← the one Calc actively skips
	UnitModeAborting UnitMode = 7
)

// Message is the input to Calc — the relevant fields of the normalized
// payload with type=plc.value that reach the calc function's node in
// the current Node-RED flow.
type Message struct {
	// Topic is the full Sparkplug topic including the ***<TRIG> suffix.
	// Example: "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***IN"
	Topic string

	// Payload is the counter value the PLC reported.
	Payload int64

	// Timestamp is the PLC's sample time. NOT the ingestion time (the
	// pre-2026-06 hardcoded-2022 bug came from confusing these).
	Timestamp time.Time

	// Tenant is the lowercased GroupID from the topic, used for keying
	// State lookups. Example: "cpack".
	Tenant string
}

// Config is the per-unit packml_config projection Calc reads. Extracted
// from flow.get("packml_config") in the JS source.
type Config struct {
	// UnitTopic is the 5-segment topic prefix (before the ***<TRIG>
	// suffix). Used as the primary lookup key.
	UnitTopic string

	// TriggerFlags controls which counter kinds this unit emits triggers
	// for. Empty map == no filtering.
	TriggerFlags map[CounterKind]bool
}

// State is the read/write projection of the Node-RED global.* and flow.*
// state Calc depends on. In-memory + Redis implementations both satisfy
// this interface; see state.go for the in-memory reference.
//
// Callers wire the concrete implementation into Calc via a closure.
type State interface {
	// Modes returns the current UnitMode for the given 5-segment unit topic.
	// The is_set boolean is true when the mode was explicitly set (vs.
	// defaulting to Unknown).
	Modes(unitTopic string) (mode UnitMode, isSet bool)

	// PackMLConfig returns the per-unit configuration. Returns
	// ErrNotConfigured when the unit isn't in flow.packml_config yet.
	PackMLConfig(unitTopic string) (Config, error)

	// CounterCumulative returns the last-known cumulative count for this
	// (unit, kind) pair. Used to compute increments (the JS function's
	// "delta from previous") without re-reading equipment_values.
	CounterCumulative(unitTopic string, kind CounterKind) (int64, error)

	// SetCounterCumulative persists a new cumulative value. Called after
	// Calc emits a StateMutation.
	SetCounterCumulative(unitTopic string, kind CounterKind, v int64) error
}

// ErrNotConfigured is returned by State.PackMLConfig when the unit
// hasn't been provisioned yet (CS Admin hasn't run for it).
var ErrNotConfigured = errors.New("calc_production_counters: unit not in packml_config")

// StateMutation is a deferred state write. Calc emits mutations in its
// Decision; the caller applies them AFTER inspecting SendDownstream.
// Two-phase apply lets tests inspect intended writes without needing a
// live State.
type StateMutation struct {
	UnitTopic string
	Kind      CounterKind
	NewValue  int64
}

// Decision is the caller-facing output of Calc. Mirrors the JS function's
// `msg.payload = send_msg; msg.send_msg = send_msg; return msg | drop`
// contract.
type Decision struct {
	// SendDownstream: true → caller emits the message; false → caller
	// drops it silently (matches Node-RED's return-nothing semantics).
	SendDownstream bool

	// EnrichedMsg carries fields the JS function attached to msg for
	// downstream consumers. Concrete keys will be documented in the
	// port PR based on the observed Node-RED output shape.
	EnrichedMsg map[string]any

	// StateUpdates: mutations the caller should apply to State AFTER
	// evaluating SendDownstream. Empty when Calc didn't touch state.
	StateUpdates []StateMutation
}

// Calc is the port target — implements the same logic as the JS
// `Calc Production Counters` function.
//
// SCAFFOLD: returns ErrNotImplemented until the port lands. Callers
// should errors.Is check for ErrNotImplemented and fall back to the
// Node-RED path (comparator side-by-side).
func Calc(msg Message, state State) (Decision, error) {
	return Decision{}, ErrNotImplemented
}
