package onboardapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// simulateWithRule posts the Bispharma example with one extra rule on line L01
// (equipment 100) and returns the status + decoded response.
func simulateWithRule(t *testing.T, vars map[string]any, samples []map[string]any) (int, SimulateResponse, string) {
	t.Helper()
	var d map[string]any
	if err := yaml.Unmarshal(readFixture(t, "examples/bispharma.descriptor.yaml"), &d); err != nil {
		t.Fatalf("yaml: %v", err)
	}
	for _, e := range d["equipment"].([]any) {
		eq := e.(map[string]any)
		if eq["id_equipment"] == 100 {
			eq["derived"] = []any{map[string]any{
				"emit": []any{"/Admin/S3PlusS4/0/Unit"}, "type": "double",
				"expr": map[string]any{"expr": "s3 + s4", "vars": vars},
			}}
		}
	}
	dj, _ := json.Marshal(d)
	body, _ := json.Marshal(map[string]any{"descriptor": json.RawMessage(dj), "samples": samples})
	rec := postJSON(t, newTestServer(t), "/v1/onboard/simulate", testKey, body)
	var resp SimulateResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	return rec.Code, resp, rec.Body.String()
}

// TestSimulate_CrossMachineRule: the automation-team ask — "compute something new
// from two specific machines". The rule lives on line L01 and reads S3 and S4 by
// their FULL topics (absolute vars); the inputs arrive at different times.
func TestSimulate_CrossMachineRule(t *testing.T) {
	code, resp, raw := simulateWithRule(t,
		map[string]any{
			"s3": "BISPHARMA/SP/LINHAS/L01/S3/Admin/ProdProcessedCount/103/Unit",
			"s4": "BISPHARMA/SP/LINHAS/L01/S4/Admin/ProdProcessedCount/104/Unit",
		},
		[]map[string]any{
			{"metric": "/LINHAS/L01/S3/Admin/ProdProcessedCount/103/Unit", "value": 40, "ts_millis": 1000},
			{"metric": "/LINHAS/L01/S4/Admin/ProdProcessedCount/104/Unit", "value": 2, "ts_millis": 2000},
		})
	if code != http.StatusOK {
		t.Fatalf("status %d: %s", code, raw)
	}
	var got any
	for _, e := range resp.Emitted {
		if e.Metric == "/LINHAS/L01/Admin/S3PlusS4/0/Unit" {
			got = e.Value
		}
	}
	if got != float64(42) {
		t.Fatalf("line L01 S3+S4 = %v, want 42; emitted=%+v", got, resp.Emitted)
	}
}

// TestSimulate_CrossMachineRuleRejectsTypos: an absolute var naming no mapped
// machine, or using {idx}, is refused with a plain message — never a silent dead rule.
func TestSimulate_CrossMachineRuleRejectsTypos(t *testing.T) {
	cases := map[string]string{
		"unknown machine": "BISPHARMA/SP/LINHAS/L01/S9/Admin/ProdProcessedCount/1/Unit",
		"{idx} on other":  "BISPHARMA/SP/LINHAS/L01/S3/Admin/ProdProcessedCount/{idx}/Unit",
		"wrong tenant":    "OTHER/SP/LINHAS/L01/S3/Admin/ProdProcessedCount/103/Unit",
	}
	for name, v := range cases {
		t.Run(name, func(t *testing.T) {
			code, _, raw := simulateWithRule(t,
				map[string]any{"s3": v, "s4": "/Admin/ProdProcessedCount/{idx}/Unit"}, nil)
			if code != http.StatusBadRequest || !strings.Contains(raw, "expr.vars") {
				t.Fatalf("want 400 naming expr.vars, got %d: %s", code, raw)
			}
		})
	}
}
