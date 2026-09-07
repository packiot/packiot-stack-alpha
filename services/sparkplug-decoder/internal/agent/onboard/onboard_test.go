package onboard

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
)

// copyToTemp copies a testdata fixture into a fresh temp dir and returns the
// copy's path, so a test that MUTATES a descriptor (capture --apply) never
// touches the checked-in fixture.
func copyToTemp(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	dst := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(dst, raw, 0o644); err != nil {
		t.Fatalf("write temp fixture: %v", err)
	}
	return dst
}

// TestFlow_InferredTenant drives the orchestrator through describe → generate →
// capture(apply) → validate on the L6/L8 fixture (L8 inferred) and asserts the
// state machine + the gates behave: capture corrects the 3 mismatched L8 indices
// in place but the tenant stays NOT-cutover-ready (L8/TEXA dormant, GLUER
// orphan), so VALIDATE is RED and CUT OVER is refused.
func TestFlow_InferredTenant(t *testing.T) {
	desc := copyToTemp(t, "cpack.descriptor.yaml")
	outDir := filepath.Join(t.TempDir(), "gen")
	var buf bytes.Buffer
	l := &Loop{DescriptorPath: desc, OutDir: outDir, Out: &buf}

	// ① DESCRIBE — valid descriptor, 4 members inferred (L8).
	m, err := l.Describe(DescribeOptions{})
	if err != nil {
		t.Fatalf("describe: %v", err)
	}
	if m.Get(StageDescribe).Status != StatusDone {
		t.Fatalf("describe status = %s, want done", m.Get(StageDescribe).Status)
	}
	if m.InferredCount != 4 {
		t.Errorf("inferred count = %d, want 4 (L8 DXL/PTH/TCX/TEXA)", m.InferredCount)
	}

	// ② GENERATE — four artifacts land in outDir.
	if _, err := l.Generate(GenerateOptions{OutDir: outDir}); err != nil {
		t.Fatalf("generate: %v", err)
	}
	for _, name := range []string{"cpack-profile.yaml", "cpack-register.sql", "cpack-agent.yaml", "cpack-tee-node.json"} {
		if _, err := os.Stat(filepath.Join(outDir, name)); err != nil {
			t.Errorf("expected generated artifact %s: %v", name, err)
		}
	}

	// ③ CAPTURE (--apply) — reconcile against the live-tee fixtures. L8's real
	// indices (511/512/513) are captured; the descriptor is rewritten in place.
	m, rep, err := l.Capture(CaptureOptions{
		HealthzPath:  "testdata/healthz-cpack.json",
		AcceptedPath: "testdata/accepted-cpack.txt",
		Apply:        true,
	})
	if err != nil {
		t.Fatalf("capture: %v", err)
	}
	if rep.CutoverReady {
		t.Errorf("capture reported cutover-ready; want NOT ready (L8/TEXA missing, GLUER orphan)")
	}
	if m.Get(StageCapture).Status != StatusBlocked {
		t.Errorf("capture stage = %s, want blocked", m.Get(StageCapture).Status)
	}

	// The apply must have rewritten the 3 mismatched L8 indices to confirmed in
	// the descriptor file itself — the loop-closing effect.
	after, err := clientdescriptor.Load(desc)
	if err != nil {
		t.Fatalf("reload descriptor after apply: %v", err)
	}
	want := map[string]int{
		"CPACK/SC/LINHAS/L8/DXL": 511,
		"CPACK/SC/LINHAS/L8/PTH": 512,
		"CPACK/SC/LINHAS/L8/TCX": 513,
	}
	for _, e := range after.Equipment {
		w, ok := want[e.Topic]
		if !ok {
			continue
		}
		if e.CountIndex == nil || e.CountIndex.Value != w {
			t.Errorf("%s: index = %v, want %d", e.Topic, e.CountIndex, w)
		}
		if e.CountIndex.Confidence != clientdescriptor.ConfidenceConfirmed {
			t.Errorf("%s: confidence = %s, want confirmed", e.Topic, e.CountIndex.Confidence)
		}
	}
	// L8/TEXA had no observation → must remain inferred (we never confirm a guess).
	for _, e := range after.Equipment {
		if e.Topic == "CPACK/SC/LINHAS/L8/TEXA" {
			if e.CountIndex.Confidence != clientdescriptor.ConfidenceInferred {
				t.Errorf("L8/TEXA confidence = %s, want inferred (dormant, unobserved)", e.CountIndex.Confidence)
			}
		}
	}

	// ④ VALIDATE — RED: L8/TEXA is still inferred.
	_, res, err := l.Validate(ValidateOptions{})
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if res.Green {
		t.Errorf("validate green; want RED (L8/TEXA inferred)")
	}
	if res.AllConfirmed {
		t.Errorf("AllConfirmed true; want false")
	}

	// ⑤ CUT OVER — hard-refused on a red gate.
	if _, err := l.Cutover(); err == nil {
		t.Errorf("cutover succeeded on a red gate; want refusal")
	}
}

// TestFlow_ReadyTenant drives an all-confirmed descriptor to a GREEN validate and
// a printed cutover checklist, and asserts the manifest reaches flow-complete.
func TestFlow_ReadyTenant(t *testing.T) {
	desc := copyToTemp(t, "cpack-ready.descriptor.yaml")
	outDir := filepath.Join(t.TempDir(), "gen")
	var buf bytes.Buffer
	l := &Loop{DescriptorPath: desc, OutDir: outDir, Out: &buf}

	if _, err := l.Describe(DescribeOptions{}); err != nil {
		t.Fatalf("describe: %v", err)
	}
	if _, err := l.Generate(GenerateOptions{OutDir: outDir}); err != nil {
		t.Fatalf("generate: %v", err)
	}

	// VALIDATE without observations → the two static gates (all-confirmed +
	// cutover-config-builds) carry the green. (The Mode-A parity gate is optional;
	// it is exercised separately, and against the full-plant healthz an L6-only
	// descriptor would correctly flag the L8 traffic as orphans.)
	_, res, err := l.Validate(ValidateOptions{})
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if !res.AllConfirmed || !res.CutoverBuilds {
		t.Fatalf("validate gates: allConfirmed=%v cutoverBuilds=%v, want both true", res.AllConfirmed, res.CutoverBuilds)
	}
	if res.ParityChecked {
		t.Errorf("parity checked without observations supplied")
	}
	if !res.Green {
		t.Fatalf("validate not green; parityReady=%v", res.ParityReady)
	}

	// ⑤ CUT OVER — the checklist prints, executes nothing, and closes the flow.
	buf.Reset()
	m, err := l.Cutover()
	if err != nil {
		t.Fatalf("cutover: %v", err)
	}
	out := buf.String()
	for _, want := range []string{"CUT OVER", "AGENT_TAGMAP_FROM_REGISTER", "cpack-register.sql", "ROLL BACK"} {
		if !strings.Contains(out, want) {
			t.Errorf("cutover checklist missing %q", want)
		}
	}
	if m.NextStage() != "" {
		t.Errorf("flow not complete after cutover; next=%s", m.NextStage())
	}
	if m.Get(StageCutover).Status != StatusDone {
		t.Errorf("cutover stage = %s, want done", m.Get(StageCutover).Status)
	}
}

// TestDescribe_ScaffoldThenValidate proves DESCRIBE --init writes a template that
// (a) fails validation while equipment is empty, and (b) validates once real
// equipment is present — the guide-rail that an empty descriptor is not onboardable.
func TestDescribe_ScaffoldThenValidate(t *testing.T) {
	dir := t.TempDir()
	desc := filepath.Join(dir, "acme.descriptor.yaml")
	var buf bytes.Buffer
	l := &Loop{DescriptorPath: desc, Out: &buf}

	// Scaffold — the file is written but is intentionally incomplete (empty
	// equipment), so Describe returns the validation error and leaves the stage
	// not-done.
	_, err := l.Describe(DescribeOptions{Scaffold: true, Tenant: "ACME", EnterpriseID: 7, Prefix: "ACME/PLANT"})
	if err == nil {
		t.Fatalf("describe on an empty scaffold should fail validation")
	}
	if _, statErr := os.Stat(desc); statErr != nil {
		t.Fatalf("scaffold file not written: %v", statErr)
	}
	body, _ := os.ReadFile(desc)
	if !strings.Contains(string(body), "tenant: ACME") || !strings.Contains(string(body), "enterprise_id: 7") {
		t.Errorf("scaffold did not seed tenant/enterprise")
	}

	// Fill in one line + one member and re-describe → valid.
	filled := strings.Replace(string(body), "equipment: []",
		"equipment:\n"+
			"  - {topic: ACME/PLANT/L1, id_equipment: 1, tp_equipment: 3}\n"+
			"  - {topic: ACME/PLANT/L1/M1, id_equipment: 2, tp_equipment: 1, id_unit: 2, count_index: {value: 5, confidence: confirmed}}\n",
		1)
	if err := os.WriteFile(desc, []byte(filled), 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := l.Describe(DescribeOptions{})
	if err != nil {
		t.Fatalf("describe on filled descriptor: %v", err)
	}
	if m.Get(StageDescribe).Status != StatusDone {
		t.Errorf("describe status = %s, want done", m.Get(StageDescribe).Status)
	}
	if m.Tenant != "ACME" || m.EnterpriseID != 7 {
		t.Errorf("manifest tenant/enterprise = %s/%d, want ACME/7", m.Tenant, m.EnterpriseID)
	}
	// Manifest persisted next to the descriptor.
	if _, err := os.Stat(DefaultManifestPath(desc, "ACME")); err != nil {
		t.Errorf("manifest not persisted: %v", err)
	}
}

// TestCutover_RefusesWithoutValidate proves the belt-and-braces gate: even an
// all-confirmed descriptor is refused cutover until VALIDATE has run green,
// closing the "stale manifest opens the gate" hole.
func TestCutover_RefusesWithoutValidate(t *testing.T) {
	desc := copyToTemp(t, "cpack-ready.descriptor.yaml")
	var buf bytes.Buffer
	l := &Loop{DescriptorPath: desc, Out: &buf}

	// Confirmed descriptor, but VALIDATE never run → cutover must refuse.
	if _, err := l.Cutover(); err == nil {
		t.Fatalf("cutover succeeded without a green VALIDATE; want refusal")
	} else if !strings.Contains(err.Error(), "VALIDATE") {
		t.Errorf("refusal reason = %q, want it to cite VALIDATE", err.Error())
	}

	// Now validate green, then cutover opens.
	if _, res, err := l.Validate(ValidateOptions{}); err != nil || !res.Green {
		t.Fatalf("validate: err=%v green=%v", err, res.Green)
	}
	if _, err := l.Cutover(); err != nil {
		t.Errorf("cutover refused after green validate: %v", err)
	}
}
