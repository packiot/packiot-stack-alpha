package deriver

import (
	"testing"
	"time"

	calc "github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/transforms/calc_production_counters"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

func timeMs(ms int64) time.Time { return time.UnixMilli(ms) }

// ── helpers ─────────────────────────────────────────────────────────────────

func integralProfile(source string, conv, clampMin, maxRate float64, emit ...string) *tenantprofile.Profile {
	return &tenantprofile.Profile{
		TenantPrefix: "T",
		Derived: []tenantprofile.DerivedRule{{
			Segment: "/L5/FLEXO",
			Emit:    emit,
			Type:    "double",
			Integral: &tenantprofile.IntegralSource{
				Source: source, Conversion: conv, ClampMin: clampMin, MaxRate: maxRate,
			},
		}},
	}
}

func sumProfile(emit string, addends ...string) *tenantprofile.Profile {
	return &tenantprofile.Profile{
		TenantPrefix: "T",
		Derived: []tenantprofile.DerivedRule{{
			Segment: "/L5/PTH",
			Emit:    []string{emit},
			Type:    "double",
			Sum:     &tenantprofile.SumSource{Addends: addends},
		}},
	}
}

func speed(metric string, v float64, ts int64) rawtag.RawTag {
	return rawtag.RawTag{Metric: metric, Value: v, TsMillis: ts, Quality: true}
}

// findEmit returns the value emitted for a given suffix in a synth slice (last
// occurrence), and whether it was present.
func findEmit(synth []rawtag.RawTag, suffix string) (float64, bool) {
	var v float64
	found := false
	for _, t := range synth {
		if t.Metric == suffix {
			v = t.Value.(float64)
			found = true
		}
	}
	return v, found
}

// ── Integral ────────────────────────────────────────────────────────────────

// TestIntegralConstantSpeed: at a constant rate, accum == speed·conv·Σdt.
func TestIntegralConstantSpeed(t *testing.T) {
	const src = "/L5/FLEXO/Status/CurMachSpeed"
	const emit = "/L5/FLEXO/Admin/ProdConsumedCount/61/Unit"
	// 600 units/min * (1/60) = 10 units/s.
	d := New(integralProfile(src, 1.0/60.0, 0, 0, emit))

	// Seed sample (t=0s): establishes t0 and emits an EXPLICIT absolute 0 baseline
	// (ADR-0045 P1 handshake — the cloud Calc seeds its first-observation baseline
	// to this 0 so the first real window is not dropped as a spike).
	synth, _ := d.Process([]rawtag.RawTag{speed(src, 600, 0)})
	if v, ok := findEmit(synth, emit); !ok || v != 0 {
		t.Fatalf("seed sample must emit absolute 0, got %v ok=%v", v, ok)
	}
	// After 10s at 10 u/s → 100 units.
	synth, _ = d.Process([]rawtag.RawTag{speed(src, 600, 10_000)})
	if v, ok := findEmit(synth, emit); !ok || v != 100 {
		t.Fatalf("after 10s: got %v ok=%v, want 100", v, ok)
	}
	// After another 5s → +50 → 150.
	synth, _ = d.Process([]rawtag.RawTag{speed(src, 600, 15_000)})
	if v, ok := findEmit(synth, emit); !ok || v != 150 {
		t.Fatalf("after 15s: got %v ok=%v, want 150", v, ok)
	}
}

// TestIntegralEmitsAllLeaves: a FLEXO lists BOTH Consumed and Processed (gross=net).
func TestIntegralEmitsAllLeaves(t *testing.T) {
	const src = "/L5/FLEXO/Status/CurMachSpeed"
	gross := "/L5/FLEXO/Admin/ProdConsumedCount/61/Unit"
	net := "/L5/FLEXO/Admin/ProdProcessedCount/61/Unit"
	d := New(integralProfile(src, 1.0, 0, 0, gross, net))
	d.Process([]rawtag.RawTag{speed(src, 5, 0)}) // seed
	synth, _ := d.Process([]rawtag.RawTag{speed(src, 5, 1000)})
	g, gok := findEmit(synth, gross)
	n, nok := findEmit(synth, net)
	if !gok || !nok || g != n || g != 5 {
		t.Fatalf("both leaves must carry the same value 5: gross=%v(%v) net=%v(%v)", g, gok, n, nok)
	}
}

// TestIntegralClampMin: a negative source rate is floored to clampMin (0),
// keeping the accumulator monotonic.
func TestIntegralClampMin(t *testing.T) {
	const src = "/L5/FLEXO/Status/CurMachSpeed"
	const emit = "/L5/FLEXO/Admin/ProdConsumedCount/61/Unit"
	d := New(integralProfile(src, 1.0, 0, 0, emit))
	d.Process([]rawtag.RawTag{speed(src, 10, 0)}) // seed
	// +10 over 1s.
	synth, _ := d.Process([]rawtag.RawTag{speed(src, 10, 1000)})
	v1, _ := findEmit(synth, emit)
	// Negative rate → clamped to 0 → accum unchanged.
	synth, _ = d.Process([]rawtag.RawTag{speed(src, -999, 2000)})
	v2, _ := findEmit(synth, emit)
	if v1 != 10 || v2 != 10 {
		t.Fatalf("clamp: got v1=%v v2=%v, want 10 then 10 (monotonic, no decrease)", v1, v2)
	}
}

// TestIntegralSpikeSkip: a sample whose rate exceeds max_rate is skipped whole —
// it does not accumulate and does not advance lastTs.
func TestIntegralSpikeSkip(t *testing.T) {
	const src = "/L5/FLEXO/Status/CurMachSpeed"
	const emit = "/L5/FLEXO/Admin/ProdConsumedCount/61/Unit"
	// maxRate = 100 units/s.
	d := New(integralProfile(src, 1.0, 0, 100, emit))
	d.Process([]rawtag.RawTag{speed(src, 10, 0)}) // seed
	// +10 over 1s.
	synth, _ := d.Process([]rawtag.RawTag{speed(src, 10, 1000)})
	if v, _ := findEmit(synth, emit); v != 10 {
		t.Fatalf("pre-spike: got %v want 10", v)
	}
	// Spike: rate 5000 > 100 → skipped, no emit.
	synth, _ = d.Process([]rawtag.RawTag{speed(src, 5000, 2000)})
	if len(synth) != 0 {
		t.Fatalf("spike sample must emit nothing, got %d", len(synth))
	}
	// Next good sample: lastTs was NOT advanced by the spike (still 1000), so dt=2s
	// at 10 u/s → +20 → 30.
	synth, _ = d.Process([]rawtag.RawTag{speed(src, 10, 3000)})
	if v, _ := findEmit(synth, emit); v != 30 {
		t.Fatalf("post-spike: got %v want 30 (lastTs unadvanced by spike)", v)
	}
}

// TestIntegralRestartNoDoubleCount is the load-bearing correctness test: the
// in-memory accumulator resets on restart, and driving the emitted absolute-
// totalizer series through the cloud Calc yields increments that SUM to the real
// production — the restart is a clean reset (incr=cur), never a double-count.
func TestIntegralRestartNoDoubleCount(t *testing.T) {
	const src = "/L5/FLEXO/Status/CurMachSpeed"
	const emit = "/CPACK/SC/L5/FLEXO/Admin/ProdConsumedCount/61/Unit"

	// captureSeries drives one deriver from its seed tick onward, appending every
	// emitted absolute-totalizer value (INCLUDING the seed's explicit 0 baseline)
	// to series — exactly what the SparkPlug session publishes to the cloud.
	capture := func(d *Deriver, samples ...rawtag.RawTag) []int64 {
		var out []int64
		for _, s := range samples {
			synth, _ := d.Process([]rawtag.RawTag{s})
			if v, ok := findEmit(synth, emit); ok {
				out = append(out, int64(v))
			}
		}
		return out
	}

	// Build the pre-restart series: seed emits 0, then 10 u/s for 30s → 100,200,300.
	d1 := New(integralProfile(src, 1.0, 0, 0, emit))
	series := capture(d1,
		speed(src, 10, 0),      // seed → 0 (absolute baseline handshake)
		speed(src, 10, 10_000), // 100
		speed(src, 10, 20_000), // 200
		speed(src, 10, 30_000), // 300
	)
	// Restart: fresh deriver, accum back to 0. Seed emits 0 again, then 50, 150.
	d2 := New(integralProfile(src, 1.0, 0, 0, emit))
	series = append(series, capture(d2,
		speed(src, 10, 100_000), // seed → 0 (re-boot baseline handshake)
		speed(src, 10, 110_000), // 50
		speed(src, 10, 115_000), // 150
	)...)
	// series = [0, 100, 200, 300, 0, 50, 150]. Real production = 300 + 150 = 450;
	// each leading 0 is the seed baseline Calc absorbs (first-obs seed, then reset).

	// Drive the absolute-totalizer series through Calc as a Consumed counter.
	// CountersOnly mode with a high rated speed sidesteps the speed glitch guard
	// (this is exactly the counters-only class the integral serves).
	state := calc.NewMemState()
	var totalIncr int64
	tsMs := int64(1_700_000_000_000)
	for _, counter := range series {
		msg := calc.Message{
			Topic:        emit + "***TRIG",
			Payload:      counter,
			CmdTrigger:   true,
			Timestamp:    timeMs(tsMs),
			CountersOnly: true,
			IdealRate:    1e9,
		}
		dec, err := calc.Calc(msg, state)
		if err != nil {
			t.Fatalf("Calc: %v", err)
		}
		for _, m := range dec.Metrics {
			if m.Name == emit {
				if m.Value < 0 {
					t.Fatalf("negative increment %d at counter %d — reset mishandled (double-count risk)", m.Value, counter)
				}
				totalIncr += m.Value
			}
		}
		for _, mut := range dec.StateUpdates {
			if err := mut.Apply(state); err != nil {
				t.Fatalf("apply state: %v", err)
			}
		}
		tsMs += 10_000
	}
	if totalIncr != 450 {
		t.Fatalf("summed increments = %d, want 450 (300 pre-restart + 150 post-restart, no double-count)", totalIncr)
	}
}

// ── Sum ─────────────────────────────────────────────────────────────────────

// TestSumBothInBatch: both addends in one envelope → emits their sum; addends
// are consumed (dropped from the passthrough).
func TestSumBothInBatch(t *testing.T) {
	a := "/L5/PTH/Status/CountA"
	b := "/L5/PTH/Status/CountB"
	emit := "/L5/PTH/Admin/ProdConsumedCount/70/Unit"
	d := New(sumProfile(emit, a, b))
	synth, consumed := d.Process([]rawtag.RawTag{
		{Metric: a, Value: 100.0, TsMillis: 1000, Quality: true},
		{Metric: b, Value: 200.0, TsMillis: 1000, Quality: true},
	})
	if v, ok := findEmit(synth, emit); !ok || v != 300 {
		t.Fatalf("sum: got %v ok=%v, want 300", v, ok)
	}
	if !consumed[a] || !consumed[b] {
		t.Fatalf("both addends must be consumed: %v", consumed)
	}
}

// TestSumNoPartialEmit: an addend arriving alone must NOT emit a partial sum
// (a partial sum looks like a totalizer DROP to Calc). Emit only once every
// addend has been seen.
func TestSumNoPartialEmit(t *testing.T) {
	a := "/L5/PTH/Status/CountA"
	b := "/L5/PTH/Status/CountB"
	emit := "/L5/PTH/Admin/ProdConsumedCount/70/Unit"
	d := New(sumProfile(emit, a, b))

	// Only A arrives → no emit (B never seen).
	synth, consumed := d.Process([]rawtag.RawTag{{Metric: a, Value: 100.0, TsMillis: 1000, Quality: true}})
	if len(synth) != 0 {
		t.Fatalf("partial sum must not emit, got %d", len(synth))
	}
	if !consumed[a] {
		t.Fatalf("addend A must still be consumed even before warmup")
	}
	// Now B arrives (separate batch) → warmed up → emit 100+50=150.
	synth, _ = d.Process([]rawtag.RawTag{{Metric: b, Value: 50.0, TsMillis: 2000, Quality: true}})
	if v, ok := findEmit(synth, emit); !ok || v != 150 {
		t.Fatalf("post-warmup: got %v ok=%v, want 150", v, ok)
	}
}

// TestSumPostWarmupContinuity: after both addends are seen, each subsequent
// update to either addend re-emits the new sum (a live totalizer).
func TestSumPostWarmupContinuity(t *testing.T) {
	a := "/L5/PTH/Status/CountA"
	b := "/L5/PTH/Status/CountB"
	emit := "/L5/PTH/Admin/ProdConsumedCount/70/Unit"
	d := New(sumProfile(emit, a, b))
	d.Process([]rawtag.RawTag{
		{Metric: a, Value: 100.0, TsMillis: 1000, Quality: true},
		{Metric: b, Value: 200.0, TsMillis: 1000, Quality: true},
	})
	// A advances to 150 → sum = 150+200 = 350.
	synth, _ := d.Process([]rawtag.RawTag{{Metric: a, Value: 150.0, TsMillis: 2000, Quality: true}})
	if v, ok := findEmit(synth, emit); !ok || v != 350 {
		t.Fatalf("continuity: got %v ok=%v, want 350", v, ok)
	}
}

// TestEmptyDeriverNoop: a profile with no derived rules is a pure no-op.
func TestEmptyDeriverNoop(t *testing.T) {
	d := New(&tenantprofile.Profile{TenantPrefix: "T"})
	if !d.Empty() {
		t.Fatalf("expected empty deriver")
	}
	synth, consumed := d.Process([]rawtag.RawTag{{Metric: "/x", Value: 1.0, TsMillis: 1}})
	if synth != nil || consumed != nil {
		t.Fatalf("empty deriver must return (nil,nil), got synth=%v consumed=%v", synth, consumed)
	}
}
