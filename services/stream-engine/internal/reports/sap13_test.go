package reports

import (
	"strings"
	"testing"
)

// Port-fidelity guard for the sap13 verbatim embed (same discipline as
// speed33_test.go): the business rules captured from prod must survive
// any future edit, and the three surgical transforms must stay intact.
func TestSap13PortFidelity(t *testing.T) {
	mustContain := []string{
		// pool contract (issue #223 — back4-api targets the same key)
		"INSERT INTO customer_reports.sap_data_sync",
		"ON CONFLICT (customer_id, linie, tag, shicht, auftrag_key)",
		"__CUSTOMER_ID__ AS customer_id",
		// frozen business rules from the prod capture
		"Europe/Zurich",
		"SELECT DISTINCT ON (linie, tag, shicht, auftrag_key)",
		"COALESCE(auftrag, 0) AS auftrag_key",
		"sum_labels as gutmenge",
		"interval '5 day'",
	}
	for _, s := range mustContain {
		if !strings.Contains(sap13Body, s) {
			t.Errorf("sap13 body lost a frozen rule/transform: %q", s)
		}
	}

	// The WRITE target must be the pool — never the legacy table. The
	// legacy name may appear only in comments/reads (frozen names).
	if strings.Contains(sap13Body, "INSERT INTO sap_report_data_sync_customer_13") {
		t.Error("sap13 body writes the legacy table — pool swap regressed")
	}

	// New-code rule: no hardcoded tenant in the projection — the
	// placeholder must be substituted at run time from config.
	if !strings.Contains(sap13Body, "__CUSTOMER_ID__") {
		t.Error("customer_id placeholder missing — tenant got hardcoded")
	}
}

// ADR-0039 R5 CONTRACT Step 1 (task #12): guard the jsonb<->dimension dual-read
// swap for the downtime-reason vocabulary CTE.
func TestSap13ReasonsFromDimSwap(t *testing.T) {
	// 1) The jsonb match-target must be an EXACT, UNIQUE substring of the body.
	//    If sap13_body.sql drifts from sap13_reasons_jsonb.sql the swap would
	//    silently no-op — the run-time guard turns that into a hard error, and
	//    this test catches it before deploy.
	if n := strings.Count(sap13Body, sap13ReasonsJSONB); n != 1 {
		t.Fatalf("sap13_reasons_jsonb.sql must match the body exactly once, found %d occurrences (body/jsonb-block drift)", n)
	}

	// 2) The default (jsonb) path still reads the inline jsonb column.
	if !strings.Contains(sap13ReasonsJSONB, "equipments.downtime_reasons") {
		t.Error("jsonb reasons block no longer reads equipments.downtime_reasons")
	}

	// 3) The dimension block reads the R5 normalized source and NOT the jsonb.
	for _, s := range []string{"downtime_reason", "equipment_downtime_reason", "reason_level = 1"} {
		if !strings.Contains(sap13ReasonsDim, s) {
			t.Errorf("dimension reasons block missing %q", s)
		}
	}
	if strings.Contains(sap13ReasonsDim, "equipments.downtime_reasons") {
		t.Error("dimension reasons block still reads the jsonb column")
	}

	// 4) Both blocks must preserve the downstream contract: a downtime_codes
	//    CTE projecting (position, description) — every later CTE binds `dc`.
	for name, blk := range map[string]string{"jsonb": sap13ReasonsJSONB, "dim": sap13ReasonsDim} {
		if !strings.Contains(blk, "downtime_codes AS (") {
			t.Errorf("%s block dropped the downtime_codes CTE (downstream dc join breaks)", name)
		}
		if !strings.Contains(blk, "description") || !strings.Contains(blk, `"position"`) {
			t.Errorf("%s block dropped the (position, description) output columns", name)
		}
	}

	// 5) swapReasonsToDim actually swaps: result carries the dim source and no
	//    longer carries the jsonb source, and the rest of the body is intact.
	body := strings.ReplaceAll(sap13Body, "__CUSTOMER_ID__", "13")
	got, err := swapReasonsToDim(body)
	if err != nil {
		t.Fatalf("swapReasonsToDim returned error on a valid body: %v", err)
	}
	if strings.Contains(got, sap13ReasonsJSONB) {
		t.Error("swap left the jsonb reasons block in place")
	}
	if !strings.Contains(got, "equipment_downtime_reason j") {
		t.Error("swap did not insert the dimension reasons block")
	}
	if !strings.Contains(got, "INSERT INTO customer_reports.sap_data_sync") {
		t.Error("swap corrupted the surrounding body")
	}

	// 6) The guard FAILS LOUD when the expected block is absent (drift), rather
	//    than silently returning the jsonb path.
	if _, err := swapReasonsToDim("SELECT 1 -- no reasons block here"); err == nil {
		t.Error("swapReasonsToDim must error when the jsonb block is missing")
	}
}
