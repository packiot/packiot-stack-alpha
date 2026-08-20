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
	clamp := silverClampSQL("ev", "equipment_runtime_shift")
	detect := silverDetectSQL("ev", "equipment_runtime_shift", "ref", "shift")

	// The clamp lowers net to gross (folded with the non-negative clamp), and does
	// so via one SET clause — never two SET clauses for net (which is a SQL error).
	if !strings.Contains(clamp, "net = GREATEST(LEAST(r.net, r.gross), 0)") {
		t.Errorf("clamp missing net≤gross fold `net = GREATEST(LEAST(r.net, r.gross), 0)`:\n%s", clamp)
	}
	if strings.Contains(clamp, "net = GREATEST(r.net, 0)") {
		t.Errorf("clamp still has the plain non-negative net clamp — the fold must REPLACE it, not add a second SET:\n%s", clamp)
	}

	// GROSS must NOT be lowered — it is the comparator identity column. Only its
	// non-negative clamp is allowed.
	if !strings.Contains(clamp, "gross = GREATEST(r.gross, 0)") {
		t.Errorf("clamp lost the gross non-negative clamp:\n%s", clamp)
	}
	if strings.Contains(clamp, "gross = GREATEST(LEAST") || strings.Contains(clamp, "gross = LEAST") {
		t.Errorf("clamp must NEVER lower gross (comparator column):\n%s", clamp)
	}

	// net>gross is in the WHERE (so a net-only violation is selected) and is the
	// idempotency key: after net=gross it is false and the row is not re-selected.
	if !strings.Contains(clamp, "r.net > r.gross") {
		t.Errorf("clamp WHERE lost the net>gross selector:\n%s", clamp)
	}

	// The detector emits the dedicated NET_GT_GROSS rule (never silent), carrying
	// the pre-clamp net (r.net) as observed_value.
	if !strings.Contains(detect, string(DQRuleInvariantClampedNetGtGross)) {
		t.Errorf("detect SQL missing INVARIANT_CLAMPED_NET_GT_GROSS rule:\n%s", detect)
	}
	if !strings.Contains(detect, "r.net > r.gross") {
		t.Errorf("detect SQL missing the net>gross predicate:\n%s", detect)
	}
}
