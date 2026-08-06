// Integration-flavored tests for the main.go wiring — verify the calcHooks
// pipeline behaves correctly when fed synthetic ResolvedMetrics that
// mirror what the MQTT handler would receive from a live decoder.
//
// These tests DON'T boot the full binary. They exercise the shadow-mode
// invocation path (calcHooks.runShadow) with realistic inputs so that if
// a downstream sparkplug/decoder change ever alters ResolvedMetric.Value
// shape, these tests catch the wiring regression BEFORE it hits staging.

package main

import (
	"context"
	"testing"
	"time"

	"log/slog"
	"os"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/shadowpub"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/transforms/calc_production_counters"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func newTestCalcHooks(t *testing.T) calcHooks {
	t.Helper()
	return calcHooks{
		state: calc_production_counters.NewMemState(),
		evals: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "test_calc_evaluations_total",
		}, []string{"tenant", "kind", "outcome"}),
		mutations: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "test_calc_state_mutations_total",
		}, []string{"tenant", "mutation_kind"}),
		errors: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "test_calc_errors_total",
		}, []string{"tenant", "reason"}),
		metricsEmitted: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "test_calc_metrics_emitted_total",
		}, []string{"tenant", "kind"}),
		stateSeeds: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "test_calc_state_seeds_total",
		}, []string{"tenant", "seed_kind"}),
	}
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, nil))
}

// TestIsCounterMetricName covers the substring detection.
func TestIsCounterMetricName(t *testing.T) {
	cases := []struct {
		name string
		want calc_production_counters.CounterKind
	}{
		{"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit", calc_production_counters.CounterKindConsumed},
		{"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/62/Unit", calc_production_counters.CounterKindProcessed},
		{"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdDefectiveCount/63/Unit", calc_production_counters.CounterKindDefective},
		{"CPACK/SC/LINHAS/L5/BREYER/Status/UnitModeCurrent", calc_production_counters.CounterKindUnknown},
		{"", calc_production_counters.CounterKindUnknown},
	}
	for _, tc := range cases {
		if got := isCounterMetricName(tc.name); got != tc.want {
			t.Errorf("isCounterMetricName(%q): got %v, want %v", tc.name, got, tc.want)
		}
	}
}

// TestRunShadowSkipsNonCounter — non-counter metrics don't touch state or metrics.
func TestRunShadowSkipsNonCounter(t *testing.T) {
	hooks := newTestCalcHooks(t)
	m := sparkplug.ResolvedMetric{
		Name:  "CPACK/SC/LINHAS/L5/BREYER/Status/UnitModeCurrent",
		Value: uint64(3),
	}
	hooks.runShadow(context.Background(), "cpack", m, time.Now(), testLogger())

	// No evaluation, no error, no mutation.
	if got := testutil.CollectAndCount(hooks.evals); got != 0 {
		t.Errorf("evals: got %d series, want 0 (non-counter should skip)", got)
	}
	if got := testutil.CollectAndCount(hooks.errors); got != 0 {
		t.Errorf("errors: got %d series, want 0", got)
	}
}

// TestRunShadowHappyPath — a Consumed increment produces outcome=send + mutations.
func TestRunShadowHappyPath(t *testing.T) {
	hooks := newTestCalcHooks(t)
	// Seed state with prior counter values so the increment is positive.
	base := "CPACK/SC/LINHAS/L5/BREYER"
	_ = hooks.state.SetInt(base+"/Admin/ProdConsumedCount/61/Unit", 90)
	_ = hooks.state.SetInt(base+"/Admin/ProdProcessedCount/61/Unit", 85)
	_ = hooks.state.SetInt(base+"/Admin/ProdDefectiveCount/61/Unit", 5)
	_ = hooks.state.SetFloat(base+"/Status/MachSpeed", 100.0)

	m := sparkplug.ResolvedMetric{
		Name:  base + "/Admin/ProdConsumedCount/61/Unit",
		Value: uint64(95), // +5
	}
	hooks.runShadow(context.Background(), "cpack", m, time.Now(), testLogger())

	// Exactly one evaluation, outcome=send.
	if got := testutil.ToFloat64(hooks.evals.WithLabelValues("cpack", "ProdConsumedCount", "send")); got != 1 {
		t.Errorf("evals[send]: got %v, want 1", got)
	}
	// At least one state mutation (counter.consumed).
	if got := testutil.ToFloat64(hooks.mutations.WithLabelValues("cpack", "counter.consumed")); got != 1 {
		t.Errorf("mutations[counter.consumed]: got %v, want 1", got)
	}
	// No errors.
	if got := testutil.CollectAndCount(hooks.errors); got != 0 {
		t.Errorf("errors: got %d series, want 0", got)
	}

	// Second tick with same state should ALSO fire (state now shows 95→100).
	// Update the seed to represent the mutation being applied.
	v, _ := hooks.state.Int(base + "/Admin/ProdConsumedCount/61/Unit")
	if v != 95 {
		t.Errorf("after runShadow: state should have Consumed=95, got %d", v)
	}
}

// TestRunShadowBooleanValueFlagsError — bool as counter payload is a
// config-error signal we want to catch loud.
func TestRunShadowBooleanValueFlagsError(t *testing.T) {
	hooks := newTestCalcHooks(t)
	m := sparkplug.ResolvedMetric{
		Name:  "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit",
		Value: true, // bool — nonsensical for a counter
	}
	hooks.runShadow(context.Background(), "cpack", m, time.Now(), testLogger())

	if got := testutil.ToFloat64(hooks.errors.WithLabelValues("cpack", "bool_as_counter")); got != 1 {
		t.Errorf("errors[bool_as_counter]: got %v, want 1", got)
	}
	// No evaluation was completed.
	if got := testutil.CollectAndCount(hooks.evals); got != 0 {
		t.Errorf("evals: got %d series, want 0 (bool should skip evaluation)", got)
	}
}

// TestRunShadowFloatTruncates — JS parseInt semantics for float counter values.
func TestRunShadowFloatTruncates(t *testing.T) {
	hooks := newTestCalcHooks(t)
	base := "CPACK/SC/LINHAS/L5/BREYER"
	_ = hooks.state.SetInt(base+"/Admin/ProdConsumedCount/61/Unit", 90)
	_ = hooks.state.SetFloat(base+"/Status/MachSpeed", 100.0)

	m := sparkplug.ResolvedMetric{
		Name:  base + "/Admin/ProdConsumedCount/61/Unit",
		Value: float64(95.7), // truncates to 95
	}
	hooks.runShadow(context.Background(), "cpack", m, time.Now(), testLogger())

	if got := testutil.ToFloat64(hooks.evals.WithLabelValues("cpack", "ProdConsumedCount", "send")); got != 1 {
		t.Errorf("evals[send]: got %v, want 1 (float should truncate not error)", got)
	}
	v, _ := hooks.state.Int(base + "/Admin/ProdConsumedCount/61/Unit")
	if v != 95 {
		t.Errorf("state after truncate: got Consumed=%d, want 95", v)
	}
}

// TestRunShadowReturnsDeltaMetrics — the #276 cutover contract: runShadow now
// RETURNS the Calc-emitted metrics so the caller can build the F3 envelope
// from delta+cumulative counters. A +5 consumed tick must return a metric with
// Value=5 (delta) and Counter=95 (cumulative) — NOT the raw cumulative 95 as
// the value (that's the bug the cutover corrects).
func TestRunShadowReturnsDeltaMetrics(t *testing.T) {
	hooks := newTestCalcHooks(t)
	base := "CPACK/SC/LINHAS/L5/BREYER"
	_ = hooks.state.SetInt(base+"/Admin/ProdConsumedCount/61/Unit", 90)
	_ = hooks.state.SetInt(base+"/Admin/ProdProcessedCount/61/Unit", 85)
	_ = hooks.state.SetInt(base+"/Admin/ProdDefectiveCount/61/Unit", 5)
	_ = hooks.state.SetFloat(base+"/Status/MachSpeed", 100.0)

	m := sparkplug.ResolvedMetric{
		Name:  base + "/Admin/ProdConsumedCount/61/Unit",
		Value: uint64(95), // +5 delta over the seeded 90
	}
	got := hooks.runShadow(context.Background(), "cpack", m, time.Now(), testLogger())

	var consumed *calc_production_counters.Metric
	for i := range got {
		if got[i].Name == base+"/Admin/ProdConsumedCount/61/Unit" {
			consumed = &got[i]
		}
	}
	if consumed == nil {
		t.Fatalf("runShadow returned no consumed metric; got %+v", got)
	}
	if consumed.Value != 5 {
		t.Errorf("consumed Value (delta): got %d, want 5", consumed.Value)
	}
	if consumed.Counter != 95 {
		t.Errorf("consumed Counter (cumulative): got %d, want 95", consumed.Counter)
	}
}

// TestRunShadowNonCounterReturnsNil — seeding metrics (MachSpeed etc.) and
// non-counter topics contribute nothing to the cutover envelope's Calc set;
// they ride through as pass-through instead.
func TestRunShadowNonCounterReturnsNil(t *testing.T) {
	hooks := newTestCalcHooks(t)
	base := "CPACK/SC/LINHAS/L5/BREYER"
	m := sparkplug.ResolvedMetric{Name: base + "/Status/MachSpeed", Value: float64(120)}
	if got := hooks.runShadow(context.Background(), "cpack", m, time.Now(), testLogger()); got != nil {
		t.Errorf("seed metric should return nil metrics, got %+v", got)
	}
}

// TestBuildCutoverMetrics — the F3 assembly: Calc delta+cumulative counters
// come first (mapped to Value/Counter), raw cumulative counters are DROPPED,
// and non-counter resolved metrics pass through verbatim.
func TestBuildCutoverMetrics(t *testing.T) {
	base := "CPACK/SC/LINHAS/L5/BREYER"
	consumedTopic := base + "/Admin/ProdConsumedCount/61/Unit"

	calcMetrics := []calc_production_counters.Metric{
		{Name: consumedTopic, Value: 5, Counter: 95, CurSpeed: 42.5, Timestamp: 1000},
	}
	resolved := []sparkplug.ResolvedMetric{
		// Raw cumulative counter — must be DROPPED (Calc delta replaces it).
		{Name: consumedTopic, Value: uint64(95), Timestamp: 1000},
		// Non-counter — must pass through verbatim.
		{Name: base + "/Status/MachSpeed", Value: float64(120), Timestamp: 1000},
		{Name: base + "/Status/UnitModeCurrent", Value: int64(3), Timestamp: 1000},
	}

	out := buildCutoverMetrics(calcMetrics, resolved)

	if len(out) != 3 {
		t.Fatalf("expected 3 metrics (1 calc + 2 passthrough), got %d: %+v", len(out), out)
	}
	// [0] = Calc consumed: delta value, cumulative counter, curspeed present.
	if out[0].Name != consumedTopic {
		t.Errorf("out[0].Name: got %q, want %q", out[0].Name, consumedTopic)
	}
	if out[0].Value != int64(5) {
		t.Errorf("out[0].Value (delta): got %v (%T), want int64(5)", out[0].Value, out[0].Value)
	}
	if out[0].Counter == nil || *out[0].Counter != 95 {
		t.Errorf("out[0].Counter (cumulative): got %v, want 95", out[0].Counter)
	}
	if out[0].CurSpeed == nil || *out[0].CurSpeed != 42.5 {
		t.Errorf("out[0].CurSpeed: got %v, want 42.5", out[0].CurSpeed)
	}
	// The raw cumulative counter must NOT appear again as a bare passthrough.
	for i := 1; i < len(out); i++ {
		if out[i].Name == consumedTopic {
			t.Errorf("raw cumulative counter leaked into passthrough at out[%d]", i)
		}
		if out[i].Counter != nil {
			t.Errorf("passthrough metric %q should have nil Counter, got %v", out[i].Name, *out[i].Counter)
		}
	}
}

// TestIsLineLevelMetricName pins the line-vs-unit discriminator against real
// topic shapes. Mirrors the resolver's canonical rule (parts[4] ∈
// {admin,status,command} → line). Case-insensitive.
func TestIsLineLevelMetricName(t *testing.T) {
	cases := []struct {
		name string
		want bool
	}{
		// LINE-level (unit-less): the Phase-9 emissions we must suppress.
		{"CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount", true},
		{"CPACK/SC/LINHAS/L5/Admin/ProdProcessedCount", true},
		{"CPACK/SC/LINHAS/L5/Admin/ProdDefectiveCount", true},
		{"CPACK/SC/LINHAS/L5/Status/StateCurrent", true},
		{"CPACK/SC/LINHAS/L5/Command/Something", true},
		// Case-insensitive (PLC topic casing varies).
		{"CPACK/SC/LINHAS/L5/admin/ProdConsumedCount", true},
		// MACHINE (Unit) topics: parts[4] is the unit name — must NOT match.
		{"CPACK/SC/LINHAS/L5/TEXA/Admin/ProdConsumedCount/65/Unit", false},
		{"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/61/Unit", false},
		{"CPACK/SC/LINHAS/L5/BREYER/Status/StateCurrent", false},
		// Too short to classify (4-segment line base) → not a metric topic.
		{"CPACK/SC/LINHAS/L5", false},
		{"", false},
	}
	for _, c := range cases {
		if got := isLineLevelMetricName(c.name); got != c.want {
			t.Errorf("isLineLevelMetricName(%q) = %v, want %v", c.name, got, c.want)
		}
	}
}

// TestBuildCutoverMetricsSuppressesLineCounters is the #276 / ADR-0037(A)
// parity guard: a Calc Phase-9 member→line AGGREGATION counter (tagged
// LineAggregated) must be DROPPED from the cutover envelope (it double-counts
// against the downstream line derivation — the id-47 oee>1.0 bug), while
// per-machine (Unit) counters AND the line's OWN-stream Phase-8 counter
// (line-level NAME but NOT LineAggregated) survive so the line is differenced
// (Value=delta, Counter=cumulative) instead of writing a raw totalizer.
func TestBuildCutoverMetricsSuppressesLineCounters(t *testing.T) {
	base := "CPACK/SC/LINHAS/L5/BREYER"
	machConsumed := base + "/Admin/ProdConsumedCount/61/Unit"
	machProcessed := base + "/Admin/ProdProcessedCount/61/Unit"
	machStatus := base + "/Status/StateCurrent"
	aggConsumed := "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount"   // Phase-9 aggregate → DROP
	aggProcessed := "CPACK/SC/LINHAS/L5/Admin/ProdProcessedCount" // Phase-9 aggregate → DROP
	// The line's OWN-stream Phase-8 counter: line-level topic, but NOT a
	// Phase-9 aggregate → must SURVIVE and keep its cumulative Counter.
	ownConsumed := "CPACK/SC/LINHAS/L8/Admin/ProdConsumedCount/51/Unit"

	calcMetrics := []calc_production_counters.Metric{
		{Name: machConsumed, Value: 5, Counter: 95, Timestamp: 1000},
		{Name: aggConsumed, Value: 5, Counter: 95, Timestamp: 1000, LineAggregated: true}, // suppressed
		{Name: machProcessed, Value: 4, Counter: 80, Timestamp: 1000},
		{Name: aggProcessed, Value: 4, Counter: 80, Timestamp: 1000, LineAggregated: true}, // suppressed
		{Name: machStatus, Value: 6, Counter: 6, Timestamp: 1000},                          // machine status → keep
		{Name: ownConsumed, Value: 7, Counter: 700, Timestamp: 1000},                       // own-stream line → keep
	}

	out := buildCutoverMetrics(calcMetrics, nil)

	got := map[string]*shadowpub.Metric{}
	for i := range out {
		got[out[i].Name] = &out[i]
	}
	// Phase-9 aggregate emissions must be gone.
	if got[aggConsumed] != nil {
		t.Errorf("Phase-9 aggregate Consumed leaked into cutover envelope: %q", aggConsumed)
	}
	if got[aggProcessed] != nil {
		t.Errorf("Phase-9 aggregate Processed leaked into cutover envelope: %q", aggProcessed)
	}
	// Machine counters + machine status + the line OWN-stream counter survive.
	for _, want := range []string{machConsumed, machProcessed, machStatus, ownConsumed} {
		if got[want] == nil {
			t.Errorf("metric %q wrongly dropped from cutover envelope", want)
		}
	}
	// The own-stream line counter must carry its cumulative Counter (→ populates
	// net_production_val) and its delta Value (→ net_production_incr) — this is
	// the fix for the raw-totalizer / NULL-val inflation (ADR-0037 A).
	if m := got[ownConsumed]; m != nil {
		if m.Value != int64(7) {
			t.Errorf("own-stream line Value (delta): got %v, want 7", m.Value)
		}
		if m.Counter == nil || *m.Counter != 700 {
			t.Errorf("own-stream line Counter (cumulative): got %v, want 700", m.Counter)
		}
	}
	if len(out) != 4 {
		t.Fatalf("expected 4 surviving metrics (2 machine counters + status + own-stream line), got %d: %+v",
			len(out), out)
	}
}

// TestEmittedSourceTypes locks the fan-out fork gating that the G1 fix hinges
// on. The "go"/shadow_go_port comparator leg is emitted by default (back-compat
// with the pre-fix unconditional []string{"go"}), but SHADOW_EMIT_GO=false must
// drop it on a single-flow production stack that has no shadow_go_port schema —
// otherwise its missing-relation write nacks the whole message and aborts the
// production write in the same pass. Ordering is load-bearing (go, refactored,
// then "") because the worker processes each leg in order.
func TestEmittedSourceTypes(t *testing.T) {
	cases := []struct {
		name           string
		emitGo         bool
		emitRefactored bool
		emitProduction bool
		want           []string
	}{
		{"default: go only (back-compat, emitGo=true)", true, false, false, []string{"go"}},
		{"emitGo=false drops go entirely (single-flow prod)", false, false, false, []string{}},
		{"emitGo=false but refactored on → refactored only, no go", false, true, false, []string{"refactored"}},
		{"go + refactored (staging dual-emit)", true, true, false, []string{"go", "refactored"}},
		{"triple emit (go, refactored, production)", true, true, true, []string{"go", "refactored", ""}},
		{"single-flow prod: production only", false, false, true, []string{""}},
		{"emitGo=false with refactored + production", false, true, true, []string{"refactored", ""}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := emittedSourceTypes(tc.emitGo, tc.emitRefactored, tc.emitProduction)
			if len(got) != len(tc.want) {
				t.Fatalf("emittedSourceTypes(%v,%v,%v) = %#v, want %#v",
					tc.emitGo, tc.emitRefactored, tc.emitProduction, got, tc.want)
			}
			for i := range tc.want {
				if got[i] != tc.want[i] {
					t.Fatalf("emittedSourceTypes(%v,%v,%v)[%d] = %q, want %q (full: %#v)",
						tc.emitGo, tc.emitRefactored, tc.emitProduction, i, got[i], tc.want[i], got)
				}
			}
		})
	}
}
