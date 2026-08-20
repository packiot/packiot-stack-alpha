package uns

import (
	"fmt"
	"strings"
	"testing"
)

func TestCurrentMetricsShape(t *testing.T) {
	for _, m := range []string{
		"tp_equipment IN (1, 3)",                 // machines + lines (live table + prod)
		"ON CONFLICT (id_equipment) DO UPDATE",   // one row per equipment
		"mode() WITHIN GROUP (ORDER BY v.state)", // hourly dominant state
		"interval '24 hours'",                    // stop-percentage window
		"ts_end IS NULL",                         // open-event probe
		"interval '15 days'",                     // prod's open-event guard
		"NULLIF(st.c_total, 0)",                  // zero-count guard (count-based, prod parity)
		"count(*) FILTER (WHERE change_over)",    // percentages count-based 0–1, not duration·100
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

// TestLineLeadMachineInheritance guards the tp=3 line live-state
// derivation: lines resolve their signal source to lead_machine and
// probe values/events off sig_id, while the write is still keyed by
// the entity (id_equipment). Machines (sig_id = id_equipment) are
// unaffected — the change is additive.
func TestLineLeadMachineInheritance(t *testing.T) {
	for _, m := range []string{
		// sig_id derivation — line inherits lead_machine, else self.
		"e.tp_equipment = 3 AND e.lead_machine IS NOT NULL",
		"THEN e.lead_machine ELSE e.id_equipment END AS sig_id",
		// value/history/event probes key off the signal source.
		"WHERE v.id_equipment = m.sig_id",
		"JOIN machines m ON m.sig_id = ee.id_equipment",
		// events remain keyed by the entity so the write stays per-line.
		"SELECT DISTINCT ON (m.id_equipment)",
		// classification config falls back to the entity's own.
		"COALESCE(sig.production_speed, e.production_speed)",
	} {
		if !strings.Contains(currentMetricsSQL, m) {
			t.Errorf("line lead-machine derivation lost %q", m)
		}
	}
	// still writes one row per equipment (unchanged upsert key).
	if !strings.Contains(currentMetricsSQL, "ON CONFLICT (id_equipment) DO UPDATE") {
		t.Error("upsert must stay keyed by id_equipment")
	}
}

func TestCurrentMetricsSQLBuilds(t *testing.T) {
	for _, schemas := range [][2]string{
		{"shadow_go_port", "public"}, // F2
		{"public", "public"},         // F3 (packiot_analytics) / F1 shape
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
