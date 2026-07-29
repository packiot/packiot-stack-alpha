package rollup

import (
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
)

// Provisional ideal-speed inference — always-on, no-DB guards. The estimator is
// a single UPSERT, so these assert the guardrails are actually present in the
// statement (a regression that dropped any of them would silently fabricate
// speeds or clobber client nameplates).
func TestInferSpeedShape(t *testing.T) {
	sql := inferSpeedSQL
	for _, m := range []string{
		"percentile_cont(%[4]s) WITHIN GROUP (ORDER BY m.gross_production_incr)", // p95, NOT max
		"m.gross_production_incr > 0",                                            // productive minutes only
		"r.productive_minutes >= %[6]d",                                          // guardrail 1: min minutes
		"r.p95 >= %[7]s",                                                         // guardrail 2: floor
		"production_speed_source = 'inferred'",                                   // only-fill-provisional predicate
		"e.production_speed IS NULL OR e.production_speed_source = 'inferred'",   // guardrail 3
		"e.tp_equipment = 3",                                                     // guardrail 4: line only
		"round(r.p95)::int",                                                      // integer result
		"m.id_equipment = ANY(%[2]s)",                                           // opted-in gate
		"ca_agg_equipment_values_1min",                                          // 1-min cagg source
	} {
		if !strings.Contains(sql, m) {
			t.Errorf("inferSpeed statement lost guardrail/clause %q", m)
		}
	}
	// It must NEVER use max() (the whole point of p95 is to shed spikes), and
	// must NEVER overwrite a client-confirmed nameplate.
	if strings.Contains(sql, "max(m.gross_production_incr)") {
		t.Error("inferSpeed must use percentile_cont p95, never max (max enshrines counter-reset spikes)")
	}
	if strings.Contains(sql, "'client'") {
		t.Error("inferSpeed must NOT write or match 'client' — a confirmed nameplate is untouchable")
	}
	// The single write target is equipments; it must not touch runtime grains.
	if strings.Contains(sql, "equipment_runtime") {
		t.Error("inferSpeed must write ONLY equipments.production_speed, never a runtime grain")
	}
}

// engaged() gates on the master flag AND a non-empty opt-in list.
func TestInferSpeedEngaged(t *testing.T) {
	cases := []struct {
		name string
		cfg  ProvisionalSpeed
		want bool
	}{
		{"off", ProvisionalSpeed{Enabled: false, Equipments: []int{101}}, false},
		{"on-but-empty", ProvisionalSpeed{Enabled: true, Equipments: nil}, false},
		{"on-with-ids", ProvisionalSpeed{Enabled: true, Equipments: []int{101, 102}}, true},
	}
	for _, c := range cases {
		if got := c.cfg.engaged(); got != c.want {
			t.Errorf("%s: engaged() = %v, want %v", c.name, got, c.want)
		}
	}
}

// fmtFloat renders bare SQL numeric literals — no exponent, no trailing zeros.
func TestFmtFloat(t *testing.T) {
	for in, want := range map[float64]string{0.95: "0.95", 1.0: "1", 1.5: "1.5", 0.5: "0.5"} {
		if got := fmtFloat(in); got != want {
			t.Errorf("fmtFloat(%v) = %q, want %q", in, got, want)
		}
	}
}

// fmtInferSpeed binds EvSchema for the cagg source and RefSchema for the write
// target — they differ on F2 (shadow_go_port / public) so a swap would read the
// wrong flow or write the wrong reference plane.
func TestInferSpeedSchemaBinding(t *testing.T) {
	d := flows.Dest{Name: "shadow_go_port", EvSchema: "shadow_go_port", RefSchema: "public"}
	cfg := ProvisionalSpeed{Enabled: true, Equipments: []int{670, 671}, WindowHours: 72, MinMinutes: 240, Percentile: 0.95, Floor: 1.0}
	stmt := fmtInferSpeed(d, cfg)
	for _, m := range []string{
		"FROM shadow_go_port.ca_agg_equipment_values_1min m", // read the flow cagg
		"UPDATE public.equipments e SET",                     // write the reference plane
		"ANY('{670,671}'::bigint[])",                         // opted-in ids inlined
		"make_interval(hours => 72)",                         // window
		"percentile_cont(0.95)",                              // percentile
		"r.productive_minutes >= 240",                        // min minutes
		"r.p95 >= 1",                                         // floor
	} {
		if !strings.Contains(stmt, m) {
			t.Errorf("formatted stmt missing %q\n---\n%s", m, stmt)
		}
	}
}
