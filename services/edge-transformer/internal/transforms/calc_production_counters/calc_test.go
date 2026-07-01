package calc_production_counters

import (
	"errors"
	"testing"
	"time"
)

// ── State interface + reference impl ────────────────────────────────────────

func TestMemStateSatisfiesInterface(t *testing.T) {
	var _ State = NewMemState()
}

func TestMemStateIntRoundTrip(t *testing.T) {
	s := NewMemState()
	if v, ok := s.Int("k"); v != 0 || ok {
		t.Errorf("empty: got v=%d ok=%v, want (0, false)", v, ok)
	}
	if err := s.SetInt("k", 42); err != nil {
		t.Fatalf("SetInt: %v", err)
	}
	if v, ok := s.Int("k"); v != 42 || !ok {
		t.Errorf("after set: got v=%d ok=%v, want (42, true)", v, ok)
	}
}

func TestMemStateUnitModeRoundTrip(t *testing.T) {
	s := NewMemState()
	if _, ok := s.UnitMode("u"); ok {
		t.Errorf("empty: expected not-found")
	}
	if err := s.SetUnitMode("u", UnitModeSetup); err != nil {
		t.Fatalf("SetUnitMode: %v", err)
	}
	m, ok := s.UnitMode("u")
	if !ok || m != UnitModeSetup {
		t.Errorf("after set: got m=%v ok=%v, want (Setup, true)", m, ok)
	}
}

// ── Topic parsing ──────────────────────────────────────────────────────────

func TestParseTopicFullBase(t *testing.T) {
	cases := []struct {
		name     string
		in       string
		wantUnit string
		wantKind CounterKind
		wantFlag TriggerFlags
	}{
		{
			name:     "processed TRIG base",
			in:       "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/62/Unit***TRIG",
			wantUnit: "CPACK/SC/LINHAS/L5/BREYER",
			wantKind: CounterKindProcessed,
			wantFlag: TriggerFlags{TrigBase: true},
		},
		{
			name:     "consumed TRIG_CS",
			in:       "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG_CS",
			wantUnit: "CPACK/SC/LINHAS/L5/BREYER",
			wantKind: CounterKindConsumed,
			wantFlag: TriggerFlags{TrigBase: true, TrigCS: true},
		},
		{
			name:     "consumed TRIG_CI",
			in:       "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG_CI",
			wantUnit: "CPACK/SC/LINHAS/L5/BREYER",
			wantKind: CounterKindConsumed,
			wantFlag: TriggerFlags{TrigBase: true, TrigCI: true},
		},
		{
			name:     "consumed TRIG_C=I mirror",
			in:       "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG_C=I",
			wantUnit: "CPACK/SC/LINHAS/L5/BREYER",
			wantKind: CounterKindConsumed,
			wantFlag: TriggerFlags{TrigBase: true, TrigCEqualsI: true},
		},
		{
			name:     "processed TRIG_C=O mirror",
			in:       "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/62/Unit***TRIG_C=O",
			wantUnit: "CPACK/SC/LINHAS/L5/BREYER",
			wantKind: CounterKindProcessed,
			wantFlag: TriggerFlags{TrigBase: true, TrigCEqualsO: true},
		},
		{
			name:     "consumed TRIG_CO reconstruction",
			in:       "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG_CO",
			wantUnit: "CPACK/SC/LINHAS/L5/BREYER",
			wantKind: CounterKindConsumed,
			wantFlag: TriggerFlags{TrigBase: true, TrigCO: true},
		},
		{
			name:     "STATESPEED_THIS variant",
			in:       "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/62/Unit***STATESPEED_THIS",
			wantUnit: "CPACK/SC/LINHAS/L5/BREYER",
			wantKind: CounterKindProcessed,
			wantFlag: TriggerFlags{StateSpeedThis: true},
		},
		{
			name:     "defective TRIG",
			in:       "CPACK/SC/LINHAS/L5/PTH/Admin/ProdDefectiveCount/63/Unit***TRIG",
			wantUnit: "CPACK/SC/LINHAS/L5/PTH",
			wantKind: CounterKindDefective,
			wantFlag: TriggerFlags{TrigBase: true},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			unit, kind, flags, err := parseTopicFull(tc.in)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if unit != tc.wantUnit {
				t.Errorf("unit: got %q, want %q", unit, tc.wantUnit)
			}
			if kind != tc.wantKind {
				t.Errorf("kind: got %v, want %v", kind, tc.wantKind)
			}
			if flags != tc.wantFlag {
				t.Errorf("flags: got %+v, want %+v", flags, tc.wantFlag)
			}
		})
	}
}

func TestParseTopicRejectsBad(t *testing.T) {
	bad := []string{
		"",
		"missing_suffix",
		"no/counter/name/here/AT/ALL/Admin/UNKNOWNCount/0/Unit***TRIG",
	}
	for _, in := range bad {
		if _, _, _, err := parseTopicFull(in); !errors.Is(err, ErrMalformedTopic) {
			t.Errorf("input %q: want ErrMalformedTopic, got %v", in, err)
		}
	}
}

// ── Phase 1: SETUP mode guard ─────────────────────────────────────────────

func TestCalcSetupModeSkips(t *testing.T) {
	s := NewMemState()
	s.SetUnitMode("CPACK/SC/LINHAS/L5/BREYER", UnitModeSetup)

	msg := Message{
		Topic:      "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    100,
		CmdTrigger: true,
		Timestamp:  time.Unix(1700000000, 0),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if dec.SendDownstream {
		t.Errorf("SendDownstream: got true, want false (SETUP mode should drop)")
	}
	if got := dec.EnrichedMsg["skipped_reason"]; got != "unit_mode_setup" {
		t.Errorf("skipped_reason: got %v, want unit_mode_setup", got)
	}
}

func TestCalcNoCmdTriggerSkips(t *testing.T) {
	s := NewMemState()
	msg := Message{
		Topic:      "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    100,
		CmdTrigger: false,
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if dec.SendDownstream {
		t.Errorf("SendDownstream: got true, want false (no cmd_trigger should drop)")
	}
	if got := dec.EnrichedMsg["skipped_reason"]; got != "no_cmd_trigger" {
		t.Errorf("skipped_reason: got %v, want no_cmd_trigger", got)
	}
}

// ── Phase 2: happy-path counter increment ─────────────────────────────────

func TestCalcConsumedIncrementHappy(t *testing.T) {
	s := NewMemState()
	// Prior state: consumed=90, processed=85, defective=5, machspeed=100.
	base := "CPACK/SC/LINHAS/L5/BREYER"
	s.SetInt(base+"/Admin/ProdConsumedCount/61/Unit", 90)
	s.SetInt(base+"/Admin/ProdProcessedCount/61/Unit", 85)
	s.SetInt(base+"/Admin/ProdDefectiveCount/61/Unit", 5)
	s.SetFloat(base+"/Status/MachSpeed", 100.0)

	msg := Message{
		Topic:      base + "/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    95, // +5 increment
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
	// Expect one metric: ProdConsumedCount with value=5, counter=95.
	if len(dec.Metrics) == 0 {
		t.Fatalf("no metrics emitted")
	}
	// Find the Consumed metric (may be more if speed logic also fires).
	var consumed *Metric
	for i := range dec.Metrics {
		if dec.Metrics[i].Name == base+"/Admin/ProdConsumedCount/61/Unit" {
			consumed = &dec.Metrics[i]
			break
		}
	}
	if consumed == nil {
		t.Fatalf("no Consumed metric emitted, got %d metrics: %+v", len(dec.Metrics), dec.Metrics)
	}
	if consumed.Value != 5 {
		t.Errorf("Consumed.Value: got %d, want 5", consumed.Value)
	}
	if consumed.Counter != 95 {
		t.Errorf("Consumed.Counter: got %d, want 95", consumed.Counter)
	}
	if consumed.Type != "int32" {
		t.Errorf("Consumed.Type: got %q, want int32", consumed.Type)
	}
	// State updates must include the SetInt(95) for Consumed.
	if !hasCounterUpdate(dec.StateUpdates, base+"/Admin/ProdConsumedCount/61/Unit", 95) {
		t.Errorf("state updates missing Consumed=95: %+v", dec.StateUpdates)
	}
}

func TestCalcProcessedIncrementHappy(t *testing.T) {
	s := NewMemState()
	base := "CPACK/SC/LINHAS/L5/POLYTYPE"
	s.SetInt(base+"/Admin/ProdConsumedCount/62/Unit", 200)
	s.SetInt(base+"/Admin/ProdProcessedCount/62/Unit", 180)
	s.SetInt(base+"/Admin/ProdDefectiveCount/62/Unit", 20)
	s.SetFloat(base+"/Status/MachSpeed", 500.0)

	msg := Message{
		Topic:      base + "/Admin/ProdProcessedCount/62/Unit***TRIG",
		Payload:    190, // +10
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000010000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if !dec.SendDownstream {
		t.Fatalf("SendDownstream: got false, want true")
	}
	var processed *Metric
	for i := range dec.Metrics {
		if dec.Metrics[i].Name == base+"/Admin/ProdProcessedCount/62/Unit" {
			processed = &dec.Metrics[i]
			break
		}
	}
	if processed == nil {
		t.Fatalf("no Processed metric emitted, got %d metrics: %+v", len(dec.Metrics), dec.Metrics)
	}
	if processed.Value != 10 || processed.Counter != 190 {
		t.Errorf("Processed metric: value=%d counter=%d, want 10/190", processed.Value, processed.Counter)
	}
}

func TestCalcDefectiveIncrementHappy(t *testing.T) {
	s := NewMemState()
	base := "CPACK/SC/LINHAS/L5/PTH"
	s.SetInt(base+"/Admin/ProdConsumedCount/63/Unit", 500)
	s.SetInt(base+"/Admin/ProdProcessedCount/63/Unit", 490)
	s.SetInt(base+"/Admin/ProdDefectiveCount/63/Unit", 10)
	s.SetFloat(base+"/Status/MachSpeed", 1000.0)

	msg := Message{
		Topic:      base + "/Admin/ProdDefectiveCount/63/Unit***TRIG",
		Payload:    12,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000020000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if !dec.SendDownstream {
		t.Fatalf("SendDownstream: got false, want true")
	}
	var defective *Metric
	for i := range dec.Metrics {
		if dec.Metrics[i].Name == base+"/Admin/ProdDefectiveCount/63/Unit" {
			defective = &dec.Metrics[i]
			break
		}
	}
	if defective == nil {
		t.Fatalf("no Defective metric emitted, got %d metrics: %+v", len(dec.Metrics), dec.Metrics)
	}
	if defective.Value != 2 || defective.Counter != 12 {
		t.Errorf("Defective metric: value=%d counter=%d, want 2/12", defective.Value, defective.Counter)
	}
}

// ── Phase 2: reset (new < last) branch ────────────────────────────────────

func TestCalcResetOnCounterRollback(t *testing.T) {
	s := NewMemState()
	base := "CPACK/SC/LINHAS/L5/BREYER"
	s.SetInt(base+"/Admin/ProdConsumedCount/61/Unit", 5000)
	s.SetInt(base+"/Admin/ProdProcessedCount/61/Unit", 4800)
	s.SetInt(base+"/Admin/ProdDefectiveCount/61/Unit", 200)
	s.SetFloat(base+"/Status/MachSpeed", 100.0)

	msg := Message{
		Topic:      base + "/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    10, // MUCH less than 5000 → PLC restart, reset path.
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	if !dec.SendDownstream {
		t.Fatalf("reset should send")
	}
	// After reset, prev=0, cur=10 → increment=10.
	var consumed *Metric
	for i := range dec.Metrics {
		if dec.Metrics[i].Name == base+"/Admin/ProdConsumedCount/61/Unit" {
			consumed = &dec.Metrics[i]
			break
		}
	}
	if consumed == nil {
		t.Fatalf("no Consumed metric on reset")
	}
	if consumed.Value != 10 {
		t.Errorf("reset Consumed.Value: got %d, want 10", consumed.Value)
	}
	if consumed.Counter != 10 {
		t.Errorf("reset Consumed.Counter: got %d, want 10", consumed.Counter)
	}
}

// ── Phase 8: glitch guard (speed > 3x machspeed) drops ────────────────────

func TestCalcSpeedGlitchGuardDrops(t *testing.T) {
	s := NewMemState()
	base := "CPACK/SC/LINHAS/L5/BREYER"
	// Prior tick 60 seconds ago @ counter=0.
	s.SetInt(base+"/Admin/ProdConsumedCount/61/Unit", 0)
	s.SetTimeMs(base+"/Status/CurMachSpeed___TS", 1700000000000)
	s.SetFloat(base+"/Status/MachSpeed", 100.0) // nominal 100/min

	msg := Message{
		Topic:      base + "/Admin/ProdConsumedCount/61/Unit***TRIG",
		Payload:    1000, // 1000 in 1 second → 60000/min → > 3*100
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000001000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	// The Consumed metric should NOT fire because speed > 3*machspeed.
	for _, m := range dec.Metrics {
		if m.Name == base+"/Admin/ProdConsumedCount/61/Unit" {
			t.Errorf("glitch guard failed — Consumed metric emitted: %+v", m)
		}
	}
	// Send might still be true if another metric fires — that's fine.
}

// ── TRIG_CS suffix: Defective = Consumed - Processed ──────────────────────

func TestCalcTrigCSForcesDefective(t *testing.T) {
	s := NewMemState()
	base := "CPACK/SC/LINHAS/L5/BREYER"
	s.SetInt(base+"/Admin/ProdConsumedCount/61/Unit", 100)
	s.SetInt(base+"/Admin/ProdProcessedCount/61/Unit", 90)
	s.SetInt(base+"/Admin/ProdDefectiveCount/61/Unit", 5)
	s.SetFloat(base+"/Status/MachSpeed", 1000.0)

	// Send a Consumed=110 with TRIG_CS → Defective should be forced to Consumed-Processed = 110-90 = 20.
	msg := Message{
		Topic:      base + "/Admin/ProdConsumedCount/61/Unit***TRIG_CS",
		Payload:    110,
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	// Defective should be persisted as 20 (or 15 which is 20 - 5 prior increment).
	if !hasCounterUpdate(dec.StateUpdates, base+"/Admin/ProdDefectiveCount/61/Unit", 20) {
		t.Errorf("TRIG_CS: Defective persist should be 20 (110-90), got updates: %+v", dec.StateUpdates)
	}
}

// ── TRIG_C=I mirror: Consumed := Processed ────────────────────────────────

func TestCalcTrigCEqualsIMirror(t *testing.T) {
	s := NewMemState()
	base := "CPACK/SC/LINHAS/L5/BREYER"
	s.SetInt(base+"/Admin/ProdConsumedCount/61/Unit", 100)
	s.SetInt(base+"/Admin/ProdProcessedCount/61/Unit", 150)
	s.SetFloat(base+"/Status/MachSpeed", 1000.0)

	msg := Message{
		Topic:      base + "/Admin/ProdConsumedCount/61/Unit***TRIG_C=I",
		Payload:    120, // ignored — Consumed forced to Processed=150.
		CmdTrigger: true,
		Timestamp:  time.UnixMilli(1700000000000),
	}
	dec, err := Calc(msg, s)
	if err != nil {
		t.Fatalf("Calc: %v", err)
	}
	// After TRIG_C=I: Consumed = Processed = 150, Defective = 0.
	if !hasCounterUpdate(dec.StateUpdates, base+"/Admin/ProdConsumedCount/61/Unit", 150) {
		t.Errorf("TRIG_C=I: Consumed persist should be 150, got: %+v", dec.StateUpdates)
	}
	if !hasCounterUpdate(dec.StateUpdates, base+"/Admin/ProdDefectiveCount/61/Unit", 0) {
		t.Errorf("TRIG_C=I: Defective persist should be 0, got: %+v", dec.StateUpdates)
	}
}

// ── Auxiliary ─────────────────────────────────────────────────────────────

func hasCounterUpdate(mutations []StateMutation, key string, want int64) bool {
	for _, m := range mutations {
		if m.Key == key && m.IntValue == want {
			return true
		}
	}
	return false
}
