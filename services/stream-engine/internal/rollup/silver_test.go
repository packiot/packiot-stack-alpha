package rollup

import (
	"strings"
	"testing"
)

// Always-on (no DB) shape guards for the net≤gross Silver invariant added to
// RunSilverClamp. The behavioural end-to-end proof lives in the golden test
// (silver_clamp_golden_test.go); these pin the SQL contract so a refactor can't
// silently drop the clamp or start lowering gross.
func TestSilverNetLeGrossClampShape(t *testing.T) {
	clamp := silverClampSQL("gold", "equipment_oee_shift")
	detect := silverDetectSQL("ev", "equipment_oee_shift", "ref", "shift", "gold")

	// #251 de-shim: the grain the detect/clamp READ lives in gold; data_quality_event
	// stays in the ev/public plane. Lock the split so a refactor can't re-merge them
	// onto the (now-dropped) public shim.
	if !strings.Contains(detect, "gold.equipment_oee_shift") {
		t.Errorf("detect must READ the grain from GoldSchema (gold.equipment_oee_shift):\n%s", detect)
	}
	if !strings.Contains(detect, "ev.data_quality_event") {
		t.Errorf("detect must WRITE data_quality_event on the ev plane (ev.data_quality_event):\n%s", detect)
	}
	if !strings.Contains(clamp, "gold.equipment_oee_shift") {
		t.Errorf("clamp must target the grain in GoldSchema (gold.equipment_oee_shift):\n%s", clamp)
	}

	// Since 2026-09-29 ("no clamps distorting data") the clamp NEVER lowers net to
	// gross: within an hour net>gross is units in transit, over a shift a meter that
	// disagrees — facts, recorded by RunDQScan's detect-only NET_GT_GROSS. net keeps
	// only its non-negative floor.
	if strings.Contains(clamp, "LEAST(r.net, r.gross)") {
		t.Errorf("clamp must not lower net to gross:\n%s", clamp)
	}
	if !strings.Contains(clamp, "net = GREATEST(r.net, 0)") {
		t.Errorf("clamp lost the net non-negative floor:\n%s", clamp)
	}
	if strings.Contains(clamp, "r.net > r.gross") || strings.Contains(detect, "r.net > r.gross") {
		t.Errorf("net>gross must not select rows for clamping:\n%s", clamp)
	}
	// GROSS must NOT be lowered either — only its non-negative floor.
	if !strings.Contains(clamp, "gross = GREATEST(r.gross, 0)") {
		t.Errorf("clamp lost the gross non-negative clamp:\n%s", clamp)
	}
	if strings.Contains(clamp, "gross = GREATEST(LEAST") || strings.Contains(clamp, "gross = LEAST") {
		t.Errorf("clamp must NEVER lower gross (comparator column):\n%s", clamp)
	}
	// scrap is SIGNED (negative = transit): it must not be floored.
	if strings.Contains(clamp, "scrap = GREATEST(r.scrap, 0)") || strings.Contains(clamp, "r.scrap < 0") {
		t.Errorf("scrap must not be floored at 0:\n%s", clamp)
	}
	// Factors keep only the LOWER bound (P>1 = ideal speed too low; hourly Q>1 =
	// transit) — no LEAST(...,1) anywhere in the factor clamp.
	if strings.Contains(clamp, ", 1)") {
		t.Errorf("factor clamp must not cap at 1:\n%s", clamp)
	}
}
