// Phase 9 line-aggregation tests. Cover the 5 canonical scenarios from
// state-machine doc §6 (11 line-first, 11 line-last, sector::line double
// pass, reset propagation, debounce).

package calc_production_counters

import (
	"testing"
	"time"
)

// helper: seed prior state for a line with 3 machines (61=first, 62=mid, 63=last).
func seedLineTopology(t *testing.T, s State, area, line string) {
	t.Helper()
	// Parameter30700 on the line topic — CSV of machine indices.
	// Format: "61,62,63" — first=61 last=63.
	key := "CPACK/SC/" + area + "/" + line + "/Status/Parameter30700"
	if err := s.SetStrings(key, []string{"61", "62", "63"}); err != nil {
		t.Fatalf("seed Parameter30700: %v", err)
	}
}

// helper: seed MachSpeed high so glitch guard doesn't fire.
func seedMachSpeed(t *testing.T, s State, unitTopic string, v float64) {
	t.Helper()
	if err := s.SetFloat(unitTopic+"/Status/MachSpeed", v); err != nil {
		t.Fatalf("seed MachSpeed: %v", err)
	}
}

// TestPhase9FirstMachineEmitsLineConsumed: a Consumed tick on the FIRST
// machine of a line should emit BOTH the unit metric AND a line-level
// Consumed metric on the LINE topic.
func TestPhase9FirstMachineEmitsLineConsumed(t *testing.T) {
	s := NewMemState()
	unitTopic := "CPACK/SC/LINHAS/L5/BREYER"
	seedLineTopology(t, s, "LINHAS", "L5")
	seedMachSpeed(t, s, unitTopic, 1000.0)
	// G2: seed a prior (0) so this tick is a genuine increment, not a
	// first-observation baseline seed (which would early-return with delta 0).
	_ = s.SetInt(unitTopic+"/Admin/ProdConsumedCount/61/Unit", 0)

	msg := Message{
		Topic:      unitTopic + "/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    50,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if !dec.SendDownstream {
		t.Fatalf("SendDownstream: got false, want true")
	}

	// Look for the LINE-level Consumed metric: "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount"
	lineConsumedName := "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount"
	found := false
	for _, m := range dec.Metrics {
		if m.Name == lineConsumedName {
			found = true
			if m.Value != 50 {
				t.Errorf("line Consumed value: got %d, want 50", m.Value)
			}
			break
		}
	}
	if !found {
		t.Errorf("no line-level Consumed metric emitted; metrics: %+v", metricNames(dec.Metrics))
	}
}

// TestPhase9LastMachineEmitsLineProcessed: a Processed tick on the LAST
// machine should emit LINE Processed.
func TestPhase9LastMachineEmitsLineProcessed(t *testing.T) {
	s := NewMemState()
	unitTopic := "CPACK/SC/LINHAS/L5/PTH"
	seedLineTopology(t, s, "LINHAS", "L5")
	seedMachSpeed(t, s, unitTopic, 1000.0)
	// G2: seed a prior (0) so this tick is a genuine increment, not a
	// first-observation baseline seed (which would early-return with delta 0).
	_ = s.SetInt(unitTopic+"/Admin/ProdProcessedCount/63/Unit", 0)

	msg := Message{
		Topic:      unitTopic + "/Admin/ProdProcessedCount/63/Unit***TRIG",
		Payload:    40,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	lineProcessedName := "CPACK/SC/LINHAS/L5/Admin/ProdProcessedCount"
	found := false
	for _, m := range dec.Metrics {
		if m.Name == lineProcessedName {
			found = true
			if m.Value != 40 {
				t.Errorf("line Processed value: got %d, want 40", m.Value)
			}
			break
		}
	}
	if !found {
		t.Errorf("no line-level Processed metric emitted; metrics: %+v", metricNames(dec.Metrics))
	}
}

// TestPhase9MiddleMachineDoesNotEmitLine: a Consumed tick on a MIDDLE
// machine (not first, not last) should NOT contribute to line-level.
func TestPhase9MiddleMachineDoesNotEmitLine(t *testing.T) {
	s := NewMemState()
	unitTopic := "CPACK/SC/LINHAS/L5/MID"
	seedLineTopology(t, s, "LINHAS", "L5")
	seedMachSpeed(t, s, unitTopic, 1000.0)

	msg := Message{
		Topic:      unitTopic + "/Admin/ProdConsumedCount/62/Unit***TRIG",
		Payload:    30,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	for _, m := range dec.Metrics {
		if m.Name == "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount" {
			t.Errorf("middle machine emitted line-Consumed unexpectedly: %+v", m)
		}
	}
}

// TestPhase9NoParameter30700NoLineEmission: without Parameter30700 seed,
// no line metrics fire even for first/last machine index.
func TestPhase9NoParameter30700NoLineEmission(t *testing.T) {
	s := NewMemState()
	unitTopic := "CPACK/SC/LINHAS/L5/BREYER"
	seedMachSpeed(t, s, unitTopic, 1000.0)
	// No seedLineTopology — Parameter30700 unset.

	msg := Message{
		Topic:      unitTopic + "/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    100,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	for _, m := range dec.Metrics {
		if m.Name == "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount" {
			t.Errorf("no-param30700: emitted line-Consumed unexpectedly: %+v", m)
		}
	}
}

// TestPhase9SectorLineDoublePass: unit with "SEC01::LINE_A" line segment
// should aggregate at BOTH the sector-line topic AND the parent line
// topic (when both have Parameter30700 set).
func TestPhase9SectorLineDoublePass(t *testing.T) {
	s := NewMemState()
	unitTopic := "CPACK/SC/LINHAS/SEC01::LINE_A/BREYER"
	// Seed both the sector-line ("SEC01::LINE_A") and the parent ("LINE_A").
	seedLineTopology(t, s, "LINHAS", "SEC01::LINE_A")
	seedLineTopology(t, s, "LINHAS", "LINE_A")
	seedMachSpeed(t, s, unitTopic, 1000.0)
	// G2: seed a prior (0) so this tick is a genuine increment, not a
	// first-observation baseline seed (which would early-return with delta 0).
	_ = s.SetInt(unitTopic+"/Admin/ProdConsumedCount/61/Unit", 0)

	msg := Message{
		Topic:      unitTopic + "/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    75,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}

	sectorMetric := "CPACK/SC/LINHAS/SEC01::LINE_A/Admin/ProdConsumedCount"
	parentMetric := "CPACK/SC/LINHAS/LINE_A/Admin/ProdConsumedCount"
	sectorFound, parentFound := false, false
	for _, m := range dec.Metrics {
		if m.Name == sectorMetric {
			sectorFound = true
		}
		if m.Name == parentMetric {
			parentFound = true
		}
	}
	if !sectorFound {
		t.Errorf("no sector-line metric emitted: %+v", metricNames(dec.Metrics))
	}
	if !parentFound {
		t.Errorf("no parent-line metric emitted: %+v", metricNames(dec.Metrics))
	}
}

// TestPhase9LineDefectiveAccumulates: line Defective = sum of first-machine
// Consumed inputs minus last-machine Processed outputs. Verify state key
// grows on Consumed tick.
func TestPhase9LineDefectiveAccumulatesOnConsumed(t *testing.T) {
	s := NewMemState()
	unitTopic := "CPACK/SC/LINHAS/L5/BREYER"
	seedLineTopology(t, s, "LINHAS", "L5")
	seedMachSpeed(t, s, unitTopic, 1000.0)
	// G2: seed a prior (0) so this tick is a genuine increment, not a
	// first-observation baseline seed (which would early-return with delta 0).
	_ = s.SetInt(unitTopic+"/Admin/ProdConsumedCount/61/Unit", 0)

	msg := Message{
		Topic:      unitTopic + "/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    100,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	// Find the line-Defective state mutation.
	lineDefKey := "CPACK/SC/LINHAS/L5/Admin/ProdDefectiveCount"
	var lineDefUpdate *StateMutation
	for i := range dec.StateUpdates {
		if dec.StateUpdates[i].Key == lineDefKey && dec.StateUpdates[i].Kind == "line.defective.add_consumed" {
			lineDefUpdate = &dec.StateUpdates[i]
			break
		}
	}
	if lineDefUpdate == nil {
		t.Fatalf("no line.defective.add_consumed mutation; got updates: %+v", mutationKinds(dec.StateUpdates))
	}
	if lineDefUpdate.IntValue != 100 {
		t.Errorf("line Defective bump: got %d, want 100 (was 0, +100)", lineDefUpdate.IntValue)
	}
}

// TestPhase9LineDefectiveDecreasesOnProcessed: last-machine Processed
// subtracts from line Defective.
func TestPhase9LineDefectiveDecreasesOnProcessed(t *testing.T) {
	s := NewMemState()
	unitTopic := "CPACK/SC/LINHAS/L5/PTH"
	seedLineTopology(t, s, "LINHAS", "L5")
	seedMachSpeed(t, s, unitTopic, 1000.0)
	// G2: seed a prior (0) so this tick is a genuine increment, not a
	// first-observation baseline seed (which would early-return with delta 0).
	_ = s.SetInt(unitTopic+"/Admin/ProdProcessedCount/63/Unit", 0)
	// Seed prior line Defective = 200.
	lineDefKey := "CPACK/SC/LINHAS/L5/Admin/ProdDefectiveCount"
	_ = s.SetInt(lineDefKey, 200)

	msg := Message{
		Topic:      unitTopic + "/Admin/ProdProcessedCount/63/Unit***TRIG",
		Payload:    50,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	var lineDefUpdate *StateMutation
	for i := range dec.StateUpdates {
		if dec.StateUpdates[i].Key == lineDefKey && dec.StateUpdates[i].Kind == "line.defective.sub_processed" {
			lineDefUpdate = &dec.StateUpdates[i]
			break
		}
	}
	if lineDefUpdate == nil {
		t.Fatalf("no line.defective.sub_processed mutation; got: %+v", mutationKinds(dec.StateUpdates))
	}
	if lineDefUpdate.IntValue != 150 {
		t.Errorf("line Defective sub: got %d, want 150 (was 200, -50)", lineDefUpdate.IntValue)
	}
}

// TestPhase9ResetPropagates: when Phase 2's reset fires (new < last), the
// line-level Defective + Defective___PREVIOUS get zeroed too.
func TestPhase9ResetPropagates(t *testing.T) {
	s := NewMemState()
	unitTopic := "CPACK/SC/LINHAS/L5/BREYER"
	seedLineTopology(t, s, "LINHAS", "L5")
	seedMachSpeed(t, s, unitTopic, 1000.0)
	// Prior state: unit Consumed=5000 (rollback simulation)
	_ = s.SetInt(unitTopic+"/Admin/ProdConsumedCount/61/Unit", 5000)

	msg := Message{
		Topic:      unitTopic + "/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    10, // Way less than 5000 → reset path
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}

	// Look for the two reset mutations.
	sawDefReset := false
	sawPrevReset := false
	for _, u := range dec.StateUpdates {
		if u.Kind == "line.defective.reset" {
			sawDefReset = true
		}
		if u.Kind == "line.defective.previous.reset" {
			sawPrevReset = true
		}
	}
	if !sawDefReset {
		t.Errorf("no line.defective.reset mutation on rollback: %+v", mutationKinds(dec.StateUpdates))
	}
	if !sawPrevReset {
		t.Errorf("no line.defective.previous.reset mutation: %+v", mutationKinds(dec.StateUpdates))
	}
}

// TestPhase9DebounceSuppressesFirstEmission: the first line-Defective
// emission should NOT fire — the 20-ms debounce window seeds the TS on
// first observation.
func TestPhase9DebounceSuppressesFirstEmission(t *testing.T) {
	s := NewMemState()
	unitTopic := "CPACK/SC/LINHAS/L5/BREYER"
	seedLineTopology(t, s, "LINHAS", "L5")
	seedMachSpeed(t, s, unitTopic, 1000.0)
	// G2: seed a prior (0) so this tick is a genuine increment, not a
	// first-observation baseline seed (which would early-return with delta 0).
	_ = s.SetInt(unitTopic+"/Admin/ProdConsumedCount/61/Unit", 0)

	msg := Message{
		Topic:      unitTopic + "/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    100,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}

	// Line ProdDefectiveCount metric should NOT be emitted on first tick.
	lineDefName := "CPACK/SC/LINHAS/L5/Admin/ProdDefectiveCount"
	for _, m := range dec.Metrics {
		if m.Name == lineDefName {
			t.Errorf("first tick should NOT emit line Defective (debounce seeds TS first): %+v", m)
		}
	}
	// But should record the ts_first mutation.
	sawTsFirst := false
	for _, u := range dec.StateUpdates {
		if u.Kind == "line.defective.ts_first" {
			sawTsFirst = true
		}
	}
	if !sawTsFirst {
		t.Errorf("no line.defective.ts_first mutation: %+v", mutationKinds(dec.StateUpdates))
	}
}

// TestLineOwnStreamIsDifferencedNotAggregated is the ADR-0037(A) guard: a
// tp=3 line that feeds its OWN bare-topic cumulative totalizer (CPACK #16
// own-stream lines, Unit segment present but no member Parameter30700) must be
// DIFFERENCED by Phase 3/8 — the emitted metric carries Value=delta (single
// digits, NOT the raw cumulative) and Counter=cumulative (monotonic) — and it
// must NOT be tagged LineAggregated (it is the line's own stream, not a
// member→line aggregate). This is what lets buildCutoverMetrics keep it, so the
// worker writes net_production_incr=delta + net_production_val=cumulative
// instead of a raw totalizer with a NULL val.
func TestLineOwnStreamIsDifferencedNotAggregated(t *testing.T) {
	s := NewMemState()
	// Own-stream line topic: Admin at index 4 (→ line, no Unit segment). The
	// line publishes MachSpeed on its 4-segment line topic (where the sim puts
	// it), and parseTopicFull now collapses the unitTopic to that 4-seg form,
	// so the Phase-8 glitch guard (prodSpeed < 3*machspeed) can find it.
	lineTopic := "CPACK/SC/LINHAS/L8"
	seedMachSpeed(t, s, lineTopic, 120.0)
	consumed := lineTopic + "/Admin/ProdConsumedCount/51/Unit"

	// Tick 1: cumulative totalizer 1000. First observation rebaselines from 0,
	// so the delta equals the whole reading — seed it, then measure tick 2.
	if _, err := Calc(Message{Topic: consumed + "***TRIG", Payload: 1000, CmdTrigger: true,
		Timestamp: time.UnixMilli(1700000000000)}, s); err != nil {
		t.Fatalf("Calc tick1: %v", err)
	}
	// (apply tick-1 state so tick-2 has a prior)
	dec1, _ := Calc(Message{Topic: consumed + "***TRIG", Payload: 1000, CmdTrigger: true,
		Timestamp: time.UnixMilli(1700000000000)}, s)
	for _, m := range dec1.StateUpdates {
		_ = m.Apply(s)
	}

	// Tick 2: cumulative totalizer 1007 → the line produced 7 units.
	dec, err := Calc(Message{Topic: consumed + "***TRIG", Payload: 1007, CmdTrigger: true,
		Timestamp: time.UnixMilli(1700000060000)}, s)
	if err != nil {
		t.Fatalf("Calc tick2: %v", err)
	}
	var got *Metric
	for i := range dec.Metrics {
		if dec.Metrics[i].Name == consumed {
			got = &dec.Metrics[i]
		}
	}
	if got == nil {
		t.Fatalf("no own-stream Consumed metric emitted: %+v", metricNames(dec.Metrics))
	}
	if got.Value != 7 {
		t.Errorf("own-stream Value: got %d, want 7 (delta, not the 1007 raw totalizer)", got.Value)
	}
	if got.Counter != 1007 {
		t.Errorf("own-stream Counter: got %d, want 1007 (cumulative, → net_production_val)", got.Counter)
	}
	if got.LineAggregated {
		t.Errorf("own-stream line counter wrongly tagged LineAggregated — cutover would drop it")
	}
}

// ── helpers ────────────────────────────────────────────────────────────────

func metricNames(ms []Metric) []string {
	out := make([]string, len(ms))
	for i, m := range ms {
		out[i] = m.Name
	}
	return out
}

func mutationKinds(ms []StateMutation) []string {
	out := make([]string, len(ms))
	for i, m := range ms {
		out[i] = m.Kind + "@" + m.Key
	}
	return out
}
