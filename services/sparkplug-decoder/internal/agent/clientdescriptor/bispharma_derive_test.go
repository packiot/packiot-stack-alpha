package clientdescriptor

import (
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
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

// TestTypeDerive_NonMemberSensorPublishes is the ADR-0058 P1.4b proof: a derive
// that references a sensor with an offset but NO member equipment (S2) is wired by
// having the reader PUBLISH it — a synthetic S7 read under the line, an agent
// allowlist entry (so §C passes), and the deriver CONSUMING it (never republished).
func TestTypeDerive_NonMemberSensorPublishes(t *testing.T) {
	d, err := Load(bispharmaDescriptorPath(t))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	// defective = S1 (member S1INFEED) − S2 (offset 4, NO member) → reader-publishes S2.
	bt := d.PLC.Types["bispharma_s7"]
	bt.Derive = map[string]string{"defective": "S1 - S2"}
	d.PLC.Types["bispharma_s7"] = bt

	p, err := d.GenerateProfile()
	if err != nil {
		t.Fatalf("P1.4b should accept a non-member sensor, got: %v", err)
	}

	// The L01 rule: S1 → member NET, S2 → synthetic /Derive/S2, S2 marked consumed.
	var got *tenantprofile.DerivedRule
	for i := range p.Derived {
		r := &p.Derived[i]
		if r.Expr != nil && len(r.Emit) == 1 && r.Emit[0] == "/LINHAS/L01/Admin/ProdDefectiveCount/100/Unit" {
			got = r
		}
	}
	if got == nil {
		t.Fatal("no L01 defective rule")
	}
	if got.Expr.Vars["S1"] != "/LINHAS/L01/S1INFEED/Admin/ProdProcessedCount/101/Unit" {
		t.Errorf("S1 var = %q (want the member NET count)", got.Expr.Vars["S1"])
	}
	if got.Expr.Vars["S2"] != "/LINHAS/L01/Derive/S2" {
		t.Errorf("S2 var = %q (want the synthetic derive-input suffix)", got.Expr.Vars["S2"])
	}
	if len(got.Expr.Consume) != 1 || got.Expr.Consume[0] != "S2" {
		t.Errorf("consume = %v, want [S2] (the reader-published sensor is folded in, not republished)", got.Expr.Consume)
	}

	// The reader s7 tag map gains a PHYSICAL read of S2 (offset 4, DB 1) under L01.
	s7, err := d.effectiveS7TagMap()
	if err != nil {
		t.Fatalf("effectiveS7TagMap: %v", err)
	}
	foundReader := false
	for _, m := range s7 {
		if m.PackMLTopic != "BISPHARMA/SP/LINHAS/L01" {
			continue
		}
		for _, tg := range m.Tags {
			if tg.Metric == "/Derive/S2" {
				foundReader = true
				if tg.Offset != 4 || tg.DB != 1 {
					t.Errorf("S2 reader tag offset/db = %d/%d, want 4/1", tg.Offset, tg.DB)
				}
			}
		}
	}
	if !foundReader {
		t.Error("no reader tag reading /Derive/S2 under L01")
	}

	// The agent allowlist gains the derive-input suffix (so §C passes + agent accepts).
	ag, err := d.GenerateAgentConfig()
	if err != nil {
		t.Fatalf("GenerateAgentConfig: %v", err)
	}
	foundAllow := false
	for _, e := range ag.RawTagMap {
		if e.MetricSuffix == "/LINHAS/L01/Derive/S2" {
			foundAllow = true
		}
	}
	if !foundAllow {
		t.Error("agent raw_tag_map missing /LINHAS/L01/Derive/S2 (§C would drop the reader tag)")
	}

	// §C holds end-to-end: GenerateClientYAML runs checkClientAgentConsistency.
	if _, err := d.GenerateClientYAML(); err != nil {
		t.Fatalf("§C consistency must hold with the reader-published sensor: %v", err)
	}
}
