package uns

import (
	"fmt"
	"strings"
	"testing"
)

func TestCurrentMetricsShape(t *testing.T) {
	for _, m := range []string{
		"tp_equipment = 1",                       // machines only (owner spec)
		"ON CONFLICT (id_equipment) DO UPDATE",   // one row per equipment
		"mode() WITHIN GROUP (ORDER BY v.state)", // hourly dominant state
		"interval '24 hours'",                    // stop-percentage window
		"ts_end IS NULL",                         // open-event probe
		"interval '15 days'",                     // prod's open-event guard
		"NULLIF(st.t_total, 0)",                  // zero-total guard
		"'running' ELSE 'lowSpeed'",              // prod status mapping, state 6
		"'changeOver' ELSE 'stopped'",            // prod status mapping, state 10
		"last_updated  = EXCLUDED.last_updated",
	} {
		if !strings.Contains(currentMetricsSQL, m) {
			t.Errorf("current-metrics SQL lost %q", m)
		}
	}
	// Standing directive: exclusions/scoping come from config or are
	// absent — never hardcoded enterprise/site/equipment ids (prod's
	// proc hardcodes an exclusion list; we deliberately do not).
	for _, banned := range []string{"(2,30,34", "not in (2", "id_enterprise IN ("} {
		if strings.Contains(currentMetricsSQL, banned) {
			t.Errorf("hardcoded id scoping %q — must not appear", banned)
		}
	}
	// production_record_shifts is NOT derived here (kept ratcheting via
	// the legacy engine until it retires) — it must stay entirely out of
	// the statement so ON CONFLICT leaves the table's value untouched.
	if strings.Contains(currentMetricsSQL, "production_record_shifts") {
		t.Error("production_record_shifts must not be written by this job")
	}
}

func TestCurrentMetricsSQLBuilds(t *testing.T) {
	for _, schemas := range [][2]string{
		{"shadow_go_port", "public"}, // F2
		{"public", "public"},         // F3 (packiot_shadow) / F1 shape
	} {
		out := fmt.Sprintf(currentMetricsSQL, schemas[0], schemas[1])
		if strings.Contains(out, "%!") || strings.Contains(out, "%[") {
			t.Errorf("Sprintf left verb residue for %v", schemas)
		}
		if !strings.Contains(out, schemas[0]+".uns_equipment_current_metrics") {
			t.Errorf("target table not schema-qualified to EvSchema %q", schemas[0])
		}
	}
}
