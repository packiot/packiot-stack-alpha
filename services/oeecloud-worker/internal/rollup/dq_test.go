package rollup

import (
	"testing"
	"time"
)

func ptr(f float64) *float64 { return &f }

// rulesOf collects the rule set an event slice fired, for order-independent asserts.
func rulesOf(evs []DQEvent) map[DQRule]DQEvent {
	m := make(map[DQRule]DQEvent, len(evs))
	for _, e := range evs {
		m[e.Rule] = e
	}
	return m
}

// A grain with oee=8142 must emit exactly OEE_GT_1 (error, observed=8142) and
// nothing else — the served value is untouched; only the signal is recorded.
func TestDetectGrain_OEEOutlier(t *testing.T) {
	ts := time.Date(2026, 7, 22, 6, 0, 0, 0, time.UTC)
	got := DetectGrain(GrainMetrics{
		IDEnterprise: 3, IDEquipment: 81, Grain: "shift", BucketTS: ts,
		OEE: 8142, Gross: 100, Net: 100, IdealSpeed: ptr(58), IdealSpeedTracked: true,
	})
	byRule := rulesOf(got)
	e, ok := byRule[DQRuleOEEGt1]
	if !ok {
		t.Fatalf("expected OEE_GT_1, got rules %v", got)
	}
	if e.Severity != dqSevError {
		t.Errorf("OEE_GT_1 severity = %q, want error", e.Severity)
	}
	if e.ObservedValue == nil || *e.ObservedValue != 8142 {
		t.Errorf("OEE_GT_1 observed = %v, want 8142", e.ObservedValue)
	}
	if e.IDEnterprise != 3 || e.IDEquipment != 81 || e.Grain != "shift" || !e.BucketTS.Equal(ts) {
		t.Errorf("event identity not carried through: %+v", e)
	}
	// No spurious rules on an otherwise-clean row (net<=gross, ideal_speed set).
	if len(got) != 1 {
		t.Errorf("expected exactly 1 event, got %d: %v", len(got), got)
	}
}

// A producing grain (net>0) with ideal_speed=0 must emit IDEAL_SPEED_NULL_WHILE_PRODUCING (warn).
func TestDetectGrain_IdealSpeedZeroWhileProducing(t *testing.T) {
	for _, tc := range []struct {
		name       string
		idealSpeed *float64
	}{
		{"zero", ptr(0)},
		{"null", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := DetectGrain(GrainMetrics{
				IDEnterprise: 4, IDEquipment: 12, Grain: "shift",
				Gross: 500, Net: 480, IdealSpeed: tc.idealSpeed, IdealSpeedTracked: true,
			})
			byRule := rulesOf(got)
			e, ok := byRule[DQRuleIdealSpeedNullProducing]
			if !ok {
				t.Fatalf("expected IDEAL_SPEED_NULL_WHILE_PRODUCING, got %v", got)
			}
			if e.Severity != dqSevWarn {
				t.Errorf("severity = %q, want warn", e.Severity)
			}
			// Only that rule should fire (net<gross, oee=0, no negatives).
			if len(got) != 1 {
				t.Errorf("expected exactly 1 event, got %d: %v", len(got), got)
			}
		})
	}
}

// ideal_speed=0 but NOT producing (net=0) must NOT fire — idle equipment is clean.
func TestDetectGrain_IdealSpeedZeroNotProducing(t *testing.T) {
	got := DetectGrain(GrainMetrics{
		IDEnterprise: 4, IDEquipment: 12, Grain: "shift",
		Gross: 0, Net: 0, IdealSpeed: ptr(0), IdealSpeedTracked: true,
	})
	if len(got) != 0 {
		t.Errorf("idle grain (net=0) must be clean, got %v", got)
	}
}

// A day/week/month grain has NO ideal_speed column (IdealSpeedTracked=false):
// even producing (net>0) with ideal_speed nil, the IDEAL_SPEED rule must NOT
// fire — those grains derive OEE from summed ideal_production, not ideal_speed.
func TestDetectGrain_IdealSpeedNotTrackedNeverFires(t *testing.T) {
	got := DetectGrain(GrainMetrics{
		IDEnterprise: 3, IDEquipment: 81, Grain: "day",
		Gross: 1000, Net: 950, IdealSpeed: nil, IdealSpeedTracked: false,
	})
	if len(got) != 0 {
		t.Errorf("untracked-ideal-speed grain must not fire the ideal-speed rule, got %v", got)
	}
}

// net>gross must emit NET_GT_GROSS (error), observed=overshoot.
func TestDetectGrain_NetGtGross(t *testing.T) {
	got := DetectGrain(GrainMetrics{
		IDEnterprise: 3, IDEquipment: 7, Grain: "hour",
		Gross: 100, Net: 130, IdealSpeed: ptr(60),
	})
	byRule := rulesOf(got)
	e, ok := byRule[DQRuleNetGtGross]
	if !ok {
		t.Fatalf("expected NET_GT_GROSS, got %v", got)
	}
	if e.Severity != dqSevError {
		t.Errorf("severity = %q, want error", e.Severity)
	}
	if e.ObservedValue == nil || *e.ObservedValue != 30 {
		t.Errorf("observed = %v, want 30", e.ObservedValue)
	}
}

// A negative duration must emit NEGATIVE_METRIC (error), observed=most-negative.
func TestDetectGrain_NegativeMetric(t *testing.T) {
	got := DetectGrain(GrainMetrics{
		IDEnterprise: 3, IDEquipment: 7, Grain: "day",
		Gross: 100, Net: 90, IdealSpeed: ptr(60),
		RunningTime: -3600, Downtime: -50,
	})
	byRule := rulesOf(got)
	e, ok := byRule[DQRuleNegativeMetric]
	if !ok {
		t.Fatalf("expected NEGATIVE_METRIC, got %v", got)
	}
	if e.ObservedValue == nil || *e.ObservedValue != -3600 {
		t.Errorf("observed = %v, want -3600 (most negative)", e.ObservedValue)
	}
}

// A clean grain must emit NO events.
func TestDetectGrain_Clean(t *testing.T) {
	got := DetectGrain(GrainMetrics{
		IDEnterprise: 3, IDEquipment: 81, Grain: "shift",
		OEE: 0.82, OeeA: 0.9, OeeP: 0.95, OeeQ: 0.96,
		Gross: 1000, Net: 960, IdealSpeed: ptr(58),
		AvailableTime: 25200, RunningTime: 22000, StoppedTime: 3200,
		PlannedDowntime: 600, Downtime: 3200, ChangeoverTime: 300,
	})
	if len(got) != 0 {
		t.Errorf("clean grain must emit no events, got %v", got)
	}
}

// A maximally-corrupt row fires several rules at once (all independent).
func TestDetectGrain_MultipleRules(t *testing.T) {
	got := DetectGrain(GrainMetrics{
		IDEnterprise: 3, IDEquipment: 81, Grain: "shift",
		OEE:   8142,          // OEE_GT_1
		Gross: 100, Net: 200, // NET_GT_GROSS (net>gross) + producing
		IdealSpeed: ptr(0), IdealSpeedTracked: true, // IDEAL_SPEED_NULL_WHILE_PRODUCING
		RunningTime: -10, // NEGATIVE_METRIC
	})
	byRule := rulesOf(got)
	for _, want := range []DQRule{
		DQRuleOEEGt1, DQRuleNetGtGross, DQRuleNegativeMetric, DQRuleIdealSpeedNullProducing,
	} {
		if _, ok := byRule[want]; !ok {
			t.Errorf("expected %s to fire, got rules %v", want, got)
		}
	}
	// The reserved cross-level rule is NOT emitted per-row.
	if _, ok := byRule[DQRuleMetricMissingAllLevels]; ok {
		t.Errorf("METRIC_MISSING_ALL_LEVELS must not fire per grain-row")
	}
}
