package capture

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/clientdescriptor"
)

const (
	fxDescriptor = "testdata/cpack.descriptor.yaml"
	fxHealthz    = "testdata/healthz-cpack.json"
	fxAccepted   = "testdata/accepted-cpack.txt"
)

func load(t *testing.T, withAccepted bool) (*clientdescriptor.Descriptor, []string, *Healthz) {
	t.Helper()
	d, err := LoadDescriptor(fxDescriptor)
	if err != nil {
		t.Fatalf("LoadDescriptor: %v", err)
	}
	h, err := LoadHealthzFile(fxHealthz)
	if err != nil {
		t.Fatalf("LoadHealthzFile: %v", err)
	}
	var acc []string
	if withAccepted {
		acc, err = LoadAcceptedFile(fxAccepted)
		if err != nil {
			t.Fatalf("LoadAcceptedFile: %v", err)
		}
	}
	return d, acc, h
}

// byKey indexes members of a report for assertion.
func byKey(rep *Report) map[string]MemberResult {
	m := map[string]MemberResult{}
	for _, r := range rep.Members {
		m[r.Key] = r
	}
	return m
}

func TestReconcile_FullTopology(t *testing.T) {
	d, acc, h := load(t, true)
	rep, err := Reconcile(d, acc, h, Options{})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	m := byKey(rep)

	// L6: all five confirmed via the accepted set.
	for _, k := range []string{"L6/BREYER", "L6/POLYTYPE", "L6/PTH", "L6/RMH", "L6/TEXA"} {
		if got := m[k].State; got != StateConfirmed {
			t.Errorf("%s: state=%s want CONFIRMED", k, got)
		}
		if m[k].Channel != ChannelAccepted {
			t.Errorf("%s: channel=%s want accepted", k, m[k].Channel)
		}
		if m[k].Captured != nil {
			t.Errorf("%s: already-confirmed member should not emit a fragment row", k)
		}
	}

	// L8 DXL/PTH/TCX: MISMATCH — the tee sends a different (real) index than the
	// inferred guess; the real index is captured as confirmed.
	wantMismatch := map[string]int{"L8/DXL": 511, "L8/PTH": 512, "L8/TCX": 513}
	for k, realIdx := range wantMismatch {
		r := m[k]
		if r.State != StateMismatch {
			t.Errorf("%s: state=%s want MISMATCH", k, r.State)
		}
		if r.Observed == nil || *r.Observed != realIdx {
			t.Errorf("%s: observed=%v want %d", k, r.Observed, realIdx)
		}
		if r.Channel != ChannelUnmapped {
			t.Errorf("%s: channel=%s want unmapped", k, r.Channel)
		}
		if r.Captured == nil || r.Captured.CountIndex == nil ||
			r.Captured.CountIndex.Value != realIdx || r.Captured.CountIndex.Confidence != ConfidenceConfirmed {
			t.Errorf("%s: captured=%+v want value=%d confirmed", k, r.Captured, realIdx)
		}
	}

	// L8/TEXA: dormant — observed nowhere → MISSING, blocks cutover.
	if r := m["L8/TEXA"]; r.State != StateMissing {
		t.Errorf("L8/TEXA: state=%s want MISSING", r.State)
	}
	if m["L8/TEXA"].Captured != nil {
		t.Errorf("L8/TEXA: MISSING member must stay inferred (no fragment row)")
	}

	// GLUER: an orphan count topic (no descriptor member) → UNMAPPED.
	if len(rep.Orphans) != 1 {
		t.Fatalf("orphans=%d want 1: %+v", len(rep.Orphans), rep.Orphans)
	}
	if rep.Orphans[0].Key != "L8/GLUER" || rep.Orphans[0].Index != 514 {
		t.Errorf("orphan=%+v want L8/GLUER index 514", rep.Orphans[0])
	}

	// Counts + cutover gate.
	if rep.Counts[StateConfirmed] != 5 || rep.Counts[StateMismatch] != 3 ||
		rep.Counts[StateMissing] != 1 || rep.Counts[StateUnmapped] != 1 {
		t.Errorf("counts=%v", rep.Counts)
	}
	if rep.CutoverReady {
		t.Errorf("full topology must NOT be cutover-ready (L8 unresolved)")
	}

	// The non-count L6/BREYER/Status/CurMachSpeed unmapped noise must not create
	// a spurious member observation or orphan.
	if _, ok := m["L6/BREYER"]; !ok {
		t.Fatalf("L6/BREYER missing from report")
	}
	if m["L6/BREYER"].State != StateConfirmed {
		t.Errorf("L6/BREYER contaminated by Status noise: %+v", m["L6/BREYER"])
	}
}

func TestReconcile_ScopeL6_ReadyAndFocused(t *testing.T) {
	d, acc, h := load(t, true)
	rep, err := Reconcile(d, acc, h, Options{Only: "L6"})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if len(rep.Members) != 5 {
		t.Fatalf("scope L6: members=%d want 5", len(rep.Members))
	}
	for _, r := range rep.Members {
		if r.State != StateConfirmed {
			t.Errorf("%s: %s want CONFIRMED", r.Key, r.State)
		}
	}
	// The L8/GLUER orphan is out of scope and must not leak into an L6 run.
	if len(rep.Orphans) != 0 {
		t.Errorf("scope L6: orphans=%+v want none (GLUER is L8)", rep.Orphans)
	}
	if !rep.CutoverReady {
		t.Errorf("scope L6 should be cutover-READY, blocking=%v", rep.Blocking)
	}
	if rep.Fragment() != "" {
		t.Errorf("scope L6: nothing changed, fragment should be empty:\n%s", rep.Fragment())
	}
}

func TestReconcile_ScopeL8_FragmentCaptured(t *testing.T) {
	d, acc, h := load(t, true)
	rep, err := Reconcile(d, acc, h, Options{Only: "L8"})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if rep.CutoverReady {
		t.Errorf("scope L8 must not be ready")
	}
	frag := rep.Fragment()
	// The three MISMATCH members get corrected rows in flow style; MISSING TEXA
	// does not appear (stays inferred).
	for _, want := range []string{
		"topic: CPACK/SC/LINHAS/L8/DXL, id_equipment: 73, tp_equipment: 1, id_unit: 73, count_index: {value: 511, confidence: confirmed}",
		"topic: CPACK/SC/LINHAS/L8/PTH, id_equipment: 74, tp_equipment: 1, id_unit: 74, count_index: {value: 512, confidence: confirmed}",
		"topic: CPACK/SC/LINHAS/L8/TCX, id_equipment: 75, tp_equipment: 1, id_unit: 75, count_index: {value: 513, confidence: confirmed}",
	} {
		if !strings.Contains(frag, want) {
			t.Errorf("fragment missing row:\n  want substring: %s\n  got:\n%s", want, frag)
		}
	}
	if strings.Contains(frag, "L8/TEXA") {
		t.Errorf("fragment must not include MISSING L8/TEXA:\n%s", frag)
	}
}

// Without the accepted set, correct-but-inferred members cannot be positively
// confirmed — but MISMATCHes (wrong indices surfacing as unmapped) still are.
func TestReconcile_NoAccepted_MismatchStillCaptured(t *testing.T) {
	d, _, h := load(t, false)
	rep, err := Reconcile(d, nil, h, Options{Only: "L8"})
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	m := byKey(rep)
	if m["L8/DXL"].State != StateMismatch || *m["L8/DXL"].Observed != 511 {
		t.Errorf("L8/DXL without accepted: %+v want MISMATCH 511", m["L8/DXL"])
	}
	// L6 confirmed members with NO observation retain their prior confirmation.
	repL6, _ := Reconcile(d, nil, h, Options{Only: "L6"})
	for _, r := range repL6.Members {
		if r.State != StateConfirmed {
			t.Errorf("L6 %s without accepted: %s want CONFIRMED (retained)", r.Key, r.State)
		}
		if !strings.Contains(r.Note, "retain") {
			t.Errorf("L6 %s note=%q want retained-confirmation", r.Key, r.Note)
		}
	}
	if !repL6.CutoverReady {
		t.Errorf("L6 retained-confirmation should stay cutover-READY")
	}
}

func TestCountTemplatesAndExtract(t *testing.T) {
	d, _, _ := load(t, false)
	tmpls := countTemplates(d.MetricTemplates.Member)
	if len(tmpls) != 3 { // Consumed/Processed/Defective
		t.Fatalf("templates=%d want 3", len(tmpls))
	}
	seg, idx, ok := extractIndex("/L6/BREYER/Admin/ProdProcessedCount/91/Unit", tmpls)
	if !ok || seg != "/L6/BREYER" || idx != 91 {
		t.Errorf("extractIndex=(%q,%d,%v) want (/L6/BREYER,91,true)", seg, idx, ok)
	}
	// A non-count suffix must not match.
	if _, _, ok := extractIndex("/L6/BREYER/Status/MachSpeed", tmpls); ok {
		t.Errorf("Status suffix should not match a count template")
	}
}

func TestTrailingKey(t *testing.T) {
	cases := map[string]string{
		"CPACK/SC/LINHAS/L6/BREYER":      "L6/BREYER",
		"/L6/BREYER":                     "L6/BREYER",
		"CPACK/SC/CELULA1/CER400/CER400": "CER400/CER400",
	}
	for in, want := range cases {
		if got := trailingKey(in); got != want {
			t.Errorf("trailingKey(%q)=%q want %q", in, got, want)
		}
	}
}

func TestReconcile_NoIndexedLeaf_Errors(t *testing.T) {
	d := &clientdescriptor.Descriptor{
		Tenant:    "X",
		Canonical: clientdescriptor.Canonical{Prefix: "X"},
		Equipment: []clientdescriptor.Equipment{{Topic: "X/L1/M", IDEquipment: 1, TPEquipment: 1}},
	}
	if _, err := Reconcile(d, nil, &Healthz{}, Options{}); err == nil {
		t.Errorf("expected error when descriptor has no {idx} member leaf")
	}
}

func TestLoadDescriptor_Path(t *testing.T) {
	if _, err := LoadDescriptor(filepath.Join("testdata", "does-not-exist.yaml")); err == nil {
		t.Errorf("expected error for missing descriptor")
	}
}
