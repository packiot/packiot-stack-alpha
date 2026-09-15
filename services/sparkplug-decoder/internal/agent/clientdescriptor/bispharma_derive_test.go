package clientdescriptor

import (
	"strings"
	"testing"
)

// TestBispharmaTypeDerive_WiresLineScrap is the ADR-0058 P1.4 proof: the shipped
// bispharma example's plc.types[].derive (scrap = S1 - S6) — previously parsed but
// never executed (ADR-0050 §4) — now generates a derived ProdDefectiveCount on
// each LINE, with each sensor bound to its member's published NET count. It runs
// the SHIPPED descriptor through the real GenerateProfile path.
func TestBispharmaTypeDerive_WiresLineScrap(t *testing.T) {
	d, err := Load(bispharmaDescriptorPath(t)) // full Validate incl. §C
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	p, err := d.GenerateProfile()
	if err != nil {
		t.Fatalf("generate profile: %v", err)
	}

	// Collect the type-derived scrap rules (expr rules emitting ProdDefectiveCount).
	var scrap []int
	for i, r := range p.Derived {
		if r.Expr != nil && len(r.Emit) == 1 && strings.Contains(r.Emit[0], "ProdDefectiveCount") {
			scrap = append(scrap, i)
		}
	}
	if len(scrap) != 16 {
		t.Fatalf("want 16 line scrap rules (one per line), got %d", len(scrap))
	}

	// Pin L01 exactly: emit on the line, vars bound to the two members' NET counts.
	found := false
	for _, r := range p.Derived {
		if r.Expr == nil || len(r.Emit) != 1 || r.Emit[0] != "/LINHAS/L01/Admin/ProdDefectiveCount/100/Unit" {
			continue
		}
		found = true
		if r.Expr.Expr != "S1 - S6" {
			t.Errorf("expr = %q, want %q", r.Expr.Expr, "S1 - S6")
		}
		// S1 (S1INFEED, id 101) and S6 (S6OUTPUT, id 106) bind to their member NET leaves.
		if r.Expr.Vars["S1"] != "/LINHAS/L01/S1INFEED/Admin/ProdProcessedCount/101/Unit" {
			t.Errorf("S1 var = %q", r.Expr.Vars["S1"])
		}
		if r.Expr.Vars["S6"] != "/LINHAS/L01/S6OUTPUT/Admin/ProdProcessedCount/106/Unit" {
			t.Errorf("S6 var = %q", r.Expr.Vars["S6"])
		}
		if r.Type != "double" {
			t.Errorf("scrap count type = %q, want double (member NET template type)", r.Type)
		}
	}
	if !found {
		t.Fatalf("no L01 scrap rule emitting /LINHAS/L01/Admin/ProdDefectiveCount/100/Unit")
	}
}

// TestTypeDerive_NonMemberSensorErrors proves the P1.4 boundary: referencing a
// sensor that has an offset but no member equipment is a LOUD error pointing at
// the deferred reader-publishes path — never a silent half-wiring.
func TestTypeDerive_NonMemberSensorErrors(t *testing.T) {
	d, err := Load(bispharmaDescriptorPath(t))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	// S2 has a sensor_offset but no member on any line — flip the derive to use it.
	bt := d.PLC.Types["bispharma_s7"]
	bt.Derive = map[string]string{"scrap": "S1 - S2"}
	d.PLC.Types["bispharma_s7"] = bt

	_, err = d.GenerateProfile()
	if err == nil {
		t.Fatal("expected an error referencing the non-member sensor S2")
	}
	if !strings.Contains(err.Error(), "S2") || !strings.Contains(err.Error(), "P1.4b") {
		t.Fatalf("error should name S2 and the deferred reader-publishes path, got: %v", err)
	}
}
