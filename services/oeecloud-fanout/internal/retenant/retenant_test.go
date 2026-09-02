package retenant

import (
	"encoding/json"
	"strings"
	"testing"
)

var cpackToSbx = Config{SourceGroup: "CPACK", TargetGroup: "SBXCPACK"}

// decode is a tiny helper that parses an envelope back into a generic map for
// assertions.
func decode(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatalf("re-decode: %v\nbody=%s", err, body)
	}
	return m
}

func metricNames(t *testing.T, env map[string]any) []string {
	t.Helper()
	raw, ok := env["metrics"].([]any)
	if !ok {
		t.Fatalf("no metrics array in %v", env)
	}
	var out []string
	for _, m := range raw {
		out = append(out, m.(map[string]any)["name"].(string))
	}
	return out
}

func TestRetenant_RewritesGroupPrefix(t *testing.T) {
	body := []byte(`{
		"timestamp": 1782161858551,
		"gateway": "edge-transformer:outbox",
		"source_type": "refactored",
		"metrics": [
			{"name":"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit","timestamp":1782161858551,"value":12,"counter":830123},
			{"name":"CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent","timestamp":1782161858551,"value":6}
		]
	}`)

	out, ours, err := Retenant(body, cpackToSbx)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if !ours {
		t.Fatal("expected ours=true for a CPACK envelope")
	}
	names := metricNames(t, decode(t, out))
	want := []string{
		"SBXCPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit",
		"SBXCPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent",
	}
	for i, w := range want {
		if names[i] != w {
			t.Errorf("metric[%d] name = %q, want %q", i, names[i], w)
		}
	}
	// No CPACK/ prefix must survive anywhere in the output.
	if strings.Contains(string(out), `"CPACK/`) {
		t.Errorf("output still contains a CPACK/ topic: %s", out)
	}
}

func TestRetenant_PreservesValuesTimestampsAndSourceType(t *testing.T) {
	body := []byte(`{"timestamp":1782161858551,"gateway":"edge-transformer:outbox","source_type":"refactored","metrics":[{"name":"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit","timestamp":1782161858999,"value":12,"counter":830123,"curspeed":118.5}]}`)

	out, ours, err := Retenant(body, cpackToSbx)
	if err != nil || !ours {
		t.Fatalf("ours=%v err=%v", ours, err)
	}
	env := decode(t, out)
	if env["timestamp"].(float64) != 1782161858551 {
		t.Errorf("top timestamp changed: %v", env["timestamp"])
	}
	if env["source_type"] != "refactored" {
		t.Errorf("source_type changed: %v", env["source_type"])
	}
	if env["gateway"] != "edge-transformer:outbox" {
		t.Errorf("gateway changed: %v", env["gateway"])
	}
	m := env["metrics"].([]any)[0].(map[string]any)
	if m["timestamp"].(float64) != 1782161858999 {
		t.Errorf("metric timestamp changed: %v", m["timestamp"])
	}
	if m["value"].(float64) != 12 {
		t.Errorf("value changed: %v", m["value"])
	}
	if m["counter"].(float64) != 830123 {
		t.Errorf("counter changed: %v", m["counter"])
	}
	if m["curspeed"].(float64) != 118.5 {
		t.Errorf("curspeed changed: %v", m["curspeed"])
	}
}

// Large integer timestamps/counters must NOT be reformatted into float
// exponent notation — UseNumber guarantees exact round-trip.
func TestRetenant_LargeIntegersRoundTripExactly(t *testing.T) {
	body := []byte(`{"timestamp":1782161858551,"metrics":[{"name":"CPACK/SC/A/B/Status/StateCurrent","timestamp":1782161858551,"counter":9007199254740993}]}`)
	out, ours, err := Retenant(body, cpackToSbx)
	if err != nil || !ours {
		t.Fatalf("ours=%v err=%v", ours, err)
	}
	if !strings.Contains(string(out), "1782161858551") {
		t.Errorf("timestamp lost exact form: %s", out)
	}
	if !strings.Contains(string(out), "9007199254740993") {
		t.Errorf("large counter lost exact form (float rounding?): %s", out)
	}
}

// The PackML parameter `id` (30700-30899) MUST survive — clearing it would
// break the worker's PO-control classification.
func TestRetenant_PreservesPackMLParameterID(t *testing.T) {
	body := []byte(`{"timestamp":1,"metrics":[{"name":"CPACK/SC/LINHAS/L5/Admin/Parameter","timestamp":1,"value":1200,"id":30701}]}`)
	out, _, err := Retenant(body, cpackToSbx)
	if err != nil {
		t.Fatal(err)
	}
	m := decode(t, out)["metrics"].([]any)[0].(map[string]any)
	if m["id"].(float64) != 30701 {
		t.Errorf("PackML parameter id was altered: %v", m["id"])
	}
}

// A pre-resolved equipment id (should it ever appear) is cleared so the target
// worker re-resolves against its own SBXCPACK register.
func TestRetenant_ClearsResolvedEquipmentID(t *testing.T) {
	body := []byte(`{"timestamp":1,"id_equipment":57,"metrics":[{"name":"CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/61/Unit","timestamp":1,"value":1,"id_equipment":57,"equipment_id":57}]}`)
	out, ours, err := Retenant(body, cpackToSbx)
	if err != nil || !ours {
		t.Fatalf("ours=%v err=%v", ours, err)
	}
	env := decode(t, out)
	if _, present := env["id_equipment"]; present {
		t.Error("top-level id_equipment should have been cleared")
	}
	m := env["metrics"].([]any)[0].(map[string]any)
	if _, present := m["id_equipment"]; present {
		t.Error("metric id_equipment should have been cleared")
	}
	if _, present := m["equipment_id"]; present {
		t.Error("metric equipment_id should have been cleared")
	}
}

// A top-level tenant/group field (forward-safe) is rewritten to the target.
func TestRetenant_RewritesTopLevelTenantField(t *testing.T) {
	body := []byte(`{"tenant":"cpack","group_id":"CPACK","metrics":[{"name":"CPACK/SC/A/B/Status/StateCurrent","value":6}]}`)
	out, ours, err := Retenant(body, cpackToSbx)
	if err != nil || !ours {
		t.Fatalf("ours=%v err=%v", ours, err)
	}
	env := decode(t, out)
	if env["tenant"] != "sbxcpack" {
		t.Errorf("tenant field = %v, want sbxcpack", env["tenant"])
	}
	if env["group_id"] != "sbxcpack" {
		t.Errorf("group_id field = %v, want sbxcpack", env["group_id"])
	}
}

// A message for a DIFFERENT tenant (arriving on the shared `sparkplug.data`
// binding) must be reported as not-ours and left untouched — the core
// no-cross-contamination guarantee.
func TestRetenant_IgnoresNonSourceTenant(t *testing.T) {
	body := []byte(`{"timestamp":1,"metrics":[{"name":"INCOPLAST/SC/A/B/Status/StateCurrent","value":6}]}`)
	out, ours, err := Retenant(body, cpackToSbx)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if ours {
		t.Fatal("INCOPLAST envelope must NOT be claimed by a CPACK→SBXCPACK fan-out")
	}
	if out != nil {
		t.Errorf("expected nil out for non-source tenant, got %s", out)
	}
}

// An already-re-tenanted message (group == target) is also not-ours, so even if
// one looped back it would never be re-processed (belt-and-braces vs the
// broker-side no-loop guarantee).
func TestRetenant_IgnoresAlreadyTargetTenant(t *testing.T) {
	body := []byte(`{"timestamp":1,"metrics":[{"name":"SBXCPACK/SC/A/B/Status/StateCurrent","value":6}]}`)
	_, ours, err := Retenant(body, cpackToSbx)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if ours {
		t.Fatal("a SBXCPACK envelope must not be claimed (no self-feedback)")
	}
}

// Case-insensitive group match (PLC topics vary in case across clients).
func TestRetenant_CaseInsensitiveGroupMatch(t *testing.T) {
	body := []byte(`{"timestamp":1,"metrics":[{"name":"cpack/sc/a/b/Status/StateCurrent","value":6}]}`)
	out, ours, err := Retenant(body, cpackToSbx)
	if err != nil || !ours {
		t.Fatalf("ours=%v err=%v", ours, err)
	}
	name := decode(t, out)["metrics"].([]any)[0].(map[string]any)["name"].(string)
	if name != "SBXCPACK/sc/a/b/Status/StateCurrent" {
		t.Errorf("name = %q, want SBXCPACK/sc/a/b/Status/StateCurrent", name)
	}
}

func TestRetenant_MalformedJSONIsError(t *testing.T) {
	if _, _, err := Retenant([]byte(`{not json`), cpackToSbx); err == nil {
		t.Fatal("expected an error for malformed JSON")
	}
}

func TestRetenant_NoMetricsArrayIsNotOurs(t *testing.T) {
	_, ours, err := Retenant([]byte(`{"timestamp":1}`), cpackToSbx)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if ours {
		t.Fatal("an envelope with no metrics array must be not-ours")
	}
}

// Idempotence at the transform level: re-running the transform on its own
// output is a no-op (output is already target-tenant → not-ours).
func TestRetenant_IsIdempotentAcrossReapply(t *testing.T) {
	body := []byte(`{"timestamp":1,"metrics":[{"name":"CPACK/SC/A/B/Status/StateCurrent","value":6}]}`)
	out1, ours1, err := Retenant(body, cpackToSbx)
	if err != nil || !ours1 {
		t.Fatalf("first pass ours=%v err=%v", ours1, err)
	}
	_, ours2, err := Retenant(out1, cpackToSbx)
	if err != nil {
		t.Fatal(err)
	}
	if ours2 {
		t.Fatal("re-applying the transform must be a no-op (not-ours)")
	}
}
