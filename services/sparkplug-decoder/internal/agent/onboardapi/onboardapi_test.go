package onboardapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
)

const testKey = "onboard-test-key"

// clientsDir is the repo docs/clients dir relative to this package (5 levels up:
// onboardapi → agent → internal → edge-transformer → services → repo root).
const clientsDir = "../../../../../docs/clients"

func newTestServer(t *testing.T) *Server {
	t.Helper()
	// nil outcomes vec (metric bumps are nil-safe); a discard logger keeps test
	// output clean.
	return New(Config{APIKey: testKey}, nil, nil)
}

// post drives one request through the handler and returns the recorder.
func post(t *testing.T, s *Server, bearer string, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/onboard/generate", bytes.NewReader(body))
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	req.Header.Set("Content-Type", "application/x-yaml")
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(clientsDir, name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return b
}

func decodeResp(t *testing.T, rec *httptest.ResponseRecorder) GenerateResponse {
	t.Helper()
	var resp GenerateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v (body=%s)", err, rec.Body.String())
	}
	return resp
}

// TestGenerate_CPACK: cpack has inferred count indices → 200, four non-empty
// artifacts, cutover_eligible:false with the inferred members listed.
func TestGenerate_CPACK(t *testing.T) {
	s := newTestServer(t)
	rec := post(t, s, testKey, readFixture(t, "cpack.descriptor.yaml"))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body=%s)", rec.Code, rec.Body.String())
	}
	resp := decodeResp(t, rec)
	if resp.Tenant != "CPACK" {
		t.Errorf("tenant = %q, want CPACK", resp.Tenant)
	}
	for name, art := range map[string]string{
		"profile_yaml":  resp.Artifacts.ProfileYAML,
		"register_sql":  resp.Artifacts.RegisterSQL,
		"agent_yaml":    resp.Artifacts.AgentYAML,
		"tee_node_json": resp.Artifacts.TeeNodeJSON,
	} {
		if strings.TrimSpace(art) == "" {
			t.Errorf("artifact %s is empty", name)
		}
	}
	if resp.Validation.CutoverEligible {
		t.Error("cutover_eligible = true, want false (cpack has inferred indices)")
	}
	if len(resp.Validation.InferredCountIndices) == 0 {
		t.Error("inferred_count_indices is empty, want the cpack inferred members")
	}
	// Every reported inferred index must carry a topic and a positive value.
	for _, ii := range resp.Validation.InferredCountIndices {
		if ii.Topic == "" || ii.Index <= 0 {
			t.Errorf("bad inferred index entry: %+v", ii)
		}
	}
}

// TestGenerate_BISPHARMA: bispharma is all-confirmed → cutover_eligible:true and
// an empty (non-null) inferred list.
func TestGenerate_BISPHARMA(t *testing.T) {
	s := newTestServer(t)
	rec := post(t, s, testKey, readFixture(t, "bispharma.descriptor.yaml"))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body=%s)", rec.Code, rec.Body.String())
	}
	resp := decodeResp(t, rec)
	if resp.Tenant != "BISPHARMA" {
		t.Errorf("tenant = %q, want BISPHARMA", resp.Tenant)
	}
	if !resp.Validation.CutoverEligible {
		t.Errorf("cutover_eligible = false, want true (bispharma is all-confirmed); inferred=%+v",
			resp.Validation.InferredCountIndices)
	}
	if len(resp.Validation.InferredCountIndices) != 0 {
		t.Errorf("inferred_count_indices = %+v, want empty", resp.Validation.InferredCountIndices)
	}
	// The field must serialize as [] not null (stable shape for Phase-1b).
	if !bytes.Contains(rec.Body.Bytes(), []byte(`"inferred_count_indices":[]`)) {
		t.Error("inferred_count_indices did not serialize as [] (nil slice leaked as null)")
	}
}

// TestGenerate_EquivalenceWithCLI proves the single-path refactor didn't drift:
// the endpoint's four artifacts are byte-identical to what Descriptor.Generate
// produces directly (the exact call the onboard-gen CLI makes).
func TestGenerate_EquivalenceWithCLI(t *testing.T) {
	s := newTestServer(t)
	for _, name := range []string{"cpack.descriptor.yaml", "bispharma.descriptor.yaml"} {
		t.Run(name, func(t *testing.T) {
			raw := readFixture(t, name)

			// CLI path: Load (== Parse) then Generate, exactly like cmd/onboard-gen.
			d, err := clientdescriptor.Parse(raw)
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			cli, err := d.Generate(clientdescriptor.GenerateOptions{Cutover: false})
			if err != nil {
				t.Fatalf("generate: %v", err)
			}

			// Endpoint path.
			rec := post(t, s, testKey, raw)
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200", rec.Code)
			}
			resp := decodeResp(t, rec)

			eq := map[string][2]string{
				"profile_yaml":  {resp.Artifacts.ProfileYAML, string(cli.ProfileYAML)},
				"register_sql":  {resp.Artifacts.RegisterSQL, cli.RegisterSQL},
				"agent_yaml":    {resp.Artifacts.AgentYAML, string(cli.AgentYAML)},
				"tee_node_json": {resp.Artifacts.TeeNodeJSON, string(cli.TeeSnippet)},
			}
			for field, pair := range eq {
				if pair[0] != pair[1] {
					t.Errorf("%s: endpoint output != CLI output (drift)\nendpoint=%q\ncli=%q",
						field, pair[0], pair[1])
				}
			}
		})
	}
}

// TestGenerate_EquivalenceWithGoldens: for bispharma, the endpoint's artifacts
// must equal the Phase-0 goldens checked into docs/clients/gen/. This anchors the
// generation to the committed reference, not just to itself.
func TestGenerate_EquivalenceWithGoldens(t *testing.T) {
	s := newTestServer(t)
	rec := post(t, s, testKey, readFixture(t, "bispharma.descriptor.yaml"))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	resp := decodeResp(t, rec)

	golden := func(name string) string {
		b, err := os.ReadFile(filepath.Join(clientsDir, "gen", name))
		if err != nil {
			t.Fatalf("read golden %s: %v", name, err)
		}
		return string(b)
	}
	for _, c := range []struct {
		field, got, golden string
	}{
		{"profile_yaml", resp.Artifacts.ProfileYAML, golden("bispharma-profile.yaml")},
		{"register_sql", resp.Artifacts.RegisterSQL, golden("bispharma-register.sql")},
		{"agent_yaml", resp.Artifacts.AgentYAML, golden("bispharma-agent.yaml")},
		{"tee_node_json", resp.Artifacts.TeeNodeJSON, golden("bispharma-tee-node.json")},
	} {
		if c.got != c.golden {
			t.Errorf("%s: endpoint output != Phase-0 golden\ngot=%q\ngolden=%q", c.field, c.got, c.golden)
		}
	}
}

// TestGenerate_JSONBody: a JSON request body is accepted (JSON is a subset of
// YAML; the descriptor decodes through the same path).
func TestGenerate_JSONBody(t *testing.T) {
	s := newTestServer(t)
	jsonDescriptor := []byte(`{
		"tenant": "TESTCO",
		"enterprise_id": 99,
		"canonical": {"prefix": "TESTCO/SP"},
		"mapping": {"count_index_default_mode": "equipment_id"},
		"equipment": [
			{"topic": "TESTCO/SP/LINHAS/L1/M1", "id_equipment": 501, "tp_equipment": 1, "id_unit": 501}
		]
	}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/onboard/generate", bytes.NewReader(jsonDescriptor))
	req.Header.Set("Authorization", "Bearer "+testKey)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body=%s)", rec.Code, rec.Body.String())
	}
	resp := decodeResp(t, rec)
	if resp.Tenant != "TESTCO" {
		t.Errorf("tenant = %q, want TESTCO", resp.Tenant)
	}
	// No metric_templates → the generator falls back to the scaffold-default
	// metric_templates (clientdescriptor.DefaultMetricTemplates), so this member
	// synthesizes the standard member leaves and is NOT reported unmapped.
	if len(resp.Validation.Unmapped) != 0 {
		t.Errorf("unmapped = %+v, want none (templateless member now uses the default templates)", resp.Validation.Unmapped)
	}
}

// TestGenerate_Malformed: a descriptor that fails validation → 400 (not 500) with
// a JSON error, and the reason is surfaced.
func TestGenerate_Malformed(t *testing.T) {
	cases := []struct {
		name string
		body []byte
		want string // substring expected in the error
	}{
		{"not yaml", []byte("::: not : valid : yaml :::\n\t- x"), ""},
		{"empty body", []byte(""), "empty body"},
		{"missing tenant", []byte("canonical:\n  prefix: X/Y\nequipment:\n  - {topic: X/Y/M, id_equipment: 1, tp_equipment: 1}\n"), "tenant is required"},
		{"topic outside prefix", []byte("tenant: X\ncanonical:\n  prefix: X/Y\nequipment:\n  - {topic: Z/OTHER/M, id_equipment: 1, tp_equipment: 1}\n"), "must start with"},
	}
	s := newTestServer(t)
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := post(t, s, testKey, c.body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400 (body=%s)", rec.Code, rec.Body.String())
			}
			var er errorResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &er); err != nil {
				t.Fatalf("decode error response: %v", err)
			}
			if er.Error == "" {
				t.Error("error message is empty")
			}
			if c.want != "" && !strings.Contains(er.Error, c.want) {
				t.Errorf("error = %q, want substring %q", er.Error, c.want)
			}
		})
	}
}

// TestGenerate_Auth: missing or wrong bearer token → 401, and generation never
// runs (no artifacts leak).
func TestGenerate_Auth(t *testing.T) {
	s := newTestServer(t)
	body := readFixture(t, "bispharma.descriptor.yaml")
	for _, c := range []struct {
		name, bearer string
	}{
		{"missing", ""},
		{"wrong", "not-the-key"},
	} {
		t.Run(c.name, func(t *testing.T) {
			rec := post(t, s, c.bearer, body)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401", rec.Code)
			}
			if bytes.Contains(rec.Body.Bytes(), []byte("profile_yaml")) {
				t.Error("unauthorized response leaked artifacts")
			}
		})
	}
}

// TestGenerate_MethodAndPath: only POST /v1/onboard/generate is routed.
func TestGenerate_MethodAndPath(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/v1/onboard/generate", nil)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Errorf("GET returned 200, want a non-OK (method not allowed / not found), got %d", rec.Code)
	}
}

// TestNew_PanicsWithoutKey: an empty key is a programming error (auth must never
// be optional) — New panics rather than serve open.
func TestNew_PanicsWithoutKey(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("New with empty APIKey did not panic")
		}
	}()
	_ = New(Config{APIKey: ""}, nil, nil)
}
