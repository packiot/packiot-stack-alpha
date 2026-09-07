package writers

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

// Regression for the staging data-quality bug: equipment_values.speed for id 55
// (L5-PTH, ent 3, rated 147/min) carried astronomical derived speeds — up to
// 3,533,683/min — while the increment sanity clamp correctly zeroed the coupled
// COUNT. The decode ADR-0049 no-speed-guard fallback disables the rate guard for
// no-MachSpeed machines and delegates spike protection to THIS Silver clamp
// (calc.go:599-600); the clamp guarded the count column but not the derived
// speed. These tests drive the real Build() end-to-end and assert the speed arg
// written to equipment_values is voided (nil → COALESCE carries the prior good
// speed forward), never the 3.5M glitch.
//
// L5-PTH topic → TopicForRegister("CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/61/Unit")
// = "CPACK/SC/LINHAS/L5" (parts[4]=="Admin" → 4-segment line register row).
const (
	l5Topic      = "CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/61/Unit"
	l5Register   = "CPACK/SC/LINHAS/L5"
	l5RatedSpeed = 147
	// curspeed is arg index 8 in buildConsumed/buildProcessed's positional args
	// (0:ts 1:ent 2:site 3:area 4:eq 5:tp 6:value 7:counter 8:curspeed …).
	curspeedArgIdx = 8
)

func intptr(n int) *int { return &n }

// speedVoidWriter builds an EquipmentValues writer with the increment sanity
// clamp ENABLED (production defaults: K=4, minDt 60s, spikeFloor 1000) and a
// resolver pre-seeded so L5's Consumed topic resolves to id 55 @ 147/min —
// no database needed.
func speedVoidWriter(t *testing.T) *EquipmentValues {
	t.Helper()
	r := sparkplug.NewResolver(nil, time.Hour, time.Hour)
	r.SeedForTest(l5Register, &sparkplug.EquipmentInfo{
		IDEnterprise: 3, IDSite: 30, IDArea: 300, IDEquipment: 55,
		ProductionSpeed: intptr(l5RatedSpeed),
	})
	w := NewEquipmentValues(r, slog.New(slog.NewTextHandler(io.Discard, nil)))
	w.SetIncrementClamp(true, 4, 60, 1000)
	return w
}

// consumedMetric parses a real Sparkplug envelope so CurSpeed lands as the
// unexported *jsonFloat exactly as the wire delivers it.
func consumedMetric(t *testing.T, tsMs int64, incr, counter, curspeed float64) *sparkplug.Metric {
	t.Helper()
	body := []byte(fmt.Sprintf(
		`{"timestamp":%d,"metrics":[{"name":%q,"timestamp":%d,"value":%g,"counter":%g,"curspeed":%g}]}`,
		tsMs, l5Topic, tsMs, incr, counter, curspeed))
	p, err := sparkplug.Parse(body)
	if err != nil {
		t.Fatalf("parse envelope: %v", err)
	}
	if len(p.Metrics) != 1 {
		t.Fatalf("want 1 metric, got %d", len(p.Metrics))
	}
	return &p.Metrics[0]
}

// TestBuild_HugeSpeedVoided_RateBound: count is NOT clamped (a small, plausible
// increment), but the derived speed is the 3.5M glitch. The K·rate bound
// (4·147=588) must void it — the exact fail-open-first-sample case that the
// lockstep arm alone would miss.
func TestBuild_HugeSpeedVoided_RateBound(t *testing.T) {
	w := speedVoidWriter(t)
	// incr 50 (< bound, count passes), counter 1_000_000 (steady totalizer, not
	// delta-from-zero), curspeed 3_533_683 (the observed glitch).
	m := consumedMetric(t, 1_700_000_000_000, 50, 1_000_000, 3_533_683)
	q, clampEv, err := w.Build(context.Background(), m, "", "public")
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if clampEv != nil {
		t.Fatalf("count should NOT be clamped here (incr 50 ≪ bound): got clampEv %+v", clampEv)
	}
	// Voided ⟺ a nil *float64 (COALESCE(EXCLUDED.speed, existing) then carries
	// the prior good speed). A boxed nil pointer is not interface-nil, so assert
	// on the pointer, not the interface.
	if sp, ok := q.Args[curspeedArgIdx].(*float64); !ok || sp != nil {
		t.Fatalf("derived speed must be VOIDED (nil *float64), got %v (=3.5M glitch would corrupt equipment_values.speed)", q.Args[curspeedArgIdx])
	}
	// The count itself (arg 6) survives untouched — only the speed is voided.
	if got := q.Args[6]; got != float64(50) {
		t.Errorf("count must pass through unchanged, got %v want 50", got)
	}
}

// TestBuild_HugeSpeedVoided_Lockstep: the dominant staging case — the count IS
// clamped (delta-from-zero spike: incr == counter ≥ spikeFloor), so the speed
// derived from the same rejected delta must be voided in lockstep.
func TestBuild_HugeSpeedVoided_Lockstep(t *testing.T) {
	w := speedVoidWriter(t)
	// incr == counter == 1_022_161 → delta-from-zero spike catch fires (first
	// sample, rate-independent) → count clamped to 0. curspeed 1_073_713 (an
	// observed id-55 value) must be voided alongside it.
	m := consumedMetric(t, 1_700_000_000_000, 1_022_161, 1_022_161, 1_073_713)
	q, clampEv, err := w.Build(context.Background(), m, "", "public")
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if clampEv == nil {
		t.Fatalf("delta-from-zero spike must clamp the count (expected clampEv)")
	}
	if got := q.Args[6]; got != float64(0) {
		t.Errorf("clamped count must be 0, got %v", got)
	}
	if sp, ok := q.Args[curspeedArgIdx].(*float64); !ok || sp != nil {
		t.Fatalf("speed coupled to a clamped count must be VOIDED (nil *float64), got %v", q.Args[curspeedArgIdx])
	}
}

// TestBuild_LegitSpeedPreserved: a healthy sample (small increment, a speed at
// the machine's rating) is written verbatim — the fix must not cap real speeds.
func TestBuild_LegitSpeedPreserved(t *testing.T) {
	w := speedVoidWriter(t)
	m := consumedMetric(t, 1_700_000_000_000, 42, 1_021_445, 120) // the 14:46:14 healthy row shape
	q, clampEv, err := w.Build(context.Background(), m, "", "public")
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if clampEv != nil {
		t.Fatalf("healthy sample must not clamp the count: %+v", clampEv)
	}
	got, ok := q.Args[curspeedArgIdx].(*float64)
	if !ok || got == nil || *got != 120 {
		t.Fatalf("legit speed 120 must be preserved, got %v", q.Args[curspeedArgIdx])
	}
}

// TestBuild_SpeedVoidFlagOffParity: with the clamp DISABLED the huge speed
// passes through untouched — flag-off is byte-for-byte the old behavior.
func TestBuild_SpeedVoidFlagOffParity(t *testing.T) {
	r := sparkplug.NewResolver(nil, time.Hour, time.Hour)
	r.SeedForTest(l5Register, &sparkplug.EquipmentInfo{
		IDEnterprise: 3, IDSite: 30, IDArea: 300, IDEquipment: 55, ProductionSpeed: intptr(l5RatedSpeed),
	})
	w := NewEquipmentValues(r, slog.New(slog.NewTextHandler(io.Discard, nil)))
	// no SetIncrementClamp → w.clamp stays nil
	m := consumedMetric(t, 1_700_000_000_000, 50, 1_000_000, 3_533_683)
	q, _, err := w.Build(context.Background(), m, "", "public")
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	got, ok := q.Args[curspeedArgIdx].(*float64)
	if !ok || got == nil || *got != 3_533_683 {
		t.Fatalf("flag-off must pass the raw speed through, got %v", q.Args[curspeedArgIdx])
	}
}
