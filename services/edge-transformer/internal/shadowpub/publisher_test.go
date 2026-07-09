// Unit tests for the shadow publisher's pure-function seams (the envelope
// builder) + the isConnectionError predicate.

package shadowpub

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// TestBuildEnvelopeCanonicalShape verifies the JSON envelope shape
// matches what oeecloud-worker's sparkplug.Payload parser expects.
func TestBuildEnvelopeCanonicalShape(t *testing.T) {
	metrics := []sparkplug.ResolvedMetric{
		{
			Name:      "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit",
			Timestamp: 1782161858551,
			Value:     uint64(100),
		},
		{
			Name:      "CPACK/SC/LINHAS/L5/BREYER/Status/MachSpeed",
			Timestamp: 1782161858551,
			Value:     float64(1000.0),
		},
	}
	in := EnvelopeInput{
		Tenant:          "cpack",
		PublisherKey:    "CPACK/edge-01",
		Instance:        "edge-transformer-hostname",
		SourceType:      "go", // explicit — BuildEnvelope no longer defaults "" → "go"
		Metrics:         metrics,
		SourceTimestamp: 1782161858551,
	}

	env := BuildEnvelope(in)

	if env.Timestamp != 1782161858551 {
		t.Errorf("Timestamp: got %d, want 1782161858551", env.Timestamp)
	}
	if !strings.Contains(env.Gateway, "edge-transformer-hostname") {
		t.Errorf("Gateway: got %q, want to contain 'edge-transformer-hostname'", env.Gateway)
	}
	if env.SourceType != "go" {
		t.Errorf("SourceType: got %q, want 'go'", env.SourceType)
	}
	if len(env.Metrics) != 2 {
		t.Fatalf("Metrics count: got %d, want 2", len(env.Metrics))
	}
	if env.Metrics[0].Name != metrics[0].Name {
		t.Errorf("Metric[0].Name: got %q, want %q", env.Metrics[0].Name, metrics[0].Name)
	}
	if env.Metrics[1].Name != metrics[1].Name {
		t.Errorf("Metric[1].Name: got %q, want %q", env.Metrics[1].Name, metrics[1].Name)
	}
}

// TestBuildEnvelopeMatchesOeecloudPayloadShape marshals the envelope
// and re-parses to confirm the JSON keys match oeecloud-worker's
// sparkplug.Payload struct tags exactly.
func TestBuildEnvelopeMatchesOeecloudPayloadShape(t *testing.T) {
	env := BuildEnvelope(EnvelopeInput{
		Tenant:       "cpack",
		PublisherKey: "CPACK/edge-01",
		Instance:     "test",
		SourceType:   "go", // explicit — required for source_type to be present (no defaulting)
		Metrics: []sparkplug.ResolvedMetric{
			{
				Name:      "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit",
				Timestamp: 1782161858551,
				Value:     uint64(42),
			},
		},
		SourceTimestamp: 1782161858551,
	})

	body, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var parsed map[string]any
	if err := json.Unmarshal(body, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	requiredKeys := []string{"timestamp", "gateway", "source_type", "metrics"}
	for _, k := range requiredKeys {
		if _, ok := parsed[k]; !ok {
			t.Errorf("JSON body missing top-level key %q; got body: %s", k, string(body))
		}
	}
	if parsed["source_type"] != "go" {
		t.Errorf("source_type: got %v, want 'go'", parsed["source_type"])
	}

	metricsList, ok := parsed["metrics"].([]any)
	if !ok {
		t.Fatalf("metrics: expected []any, got %T", parsed["metrics"])
	}
	if len(metricsList) != 1 {
		t.Fatalf("metrics count: got %d, want 1", len(metricsList))
	}
	m, ok := metricsList[0].(map[string]any)
	if !ok {
		t.Fatalf("metrics[0]: expected map, got %T", metricsList[0])
	}
	for _, k := range []string{"name", "timestamp", "value"} {
		if _, ok := m[k]; !ok {
			t.Errorf("metrics[0] missing key %q; got %+v", k, m)
		}
	}
}

// TestBuildEnvelopeSourceTypeOverride — ADR-0012 Phase 3 lets callers stamp the
// envelope with a source_type. Post-10.9 there is NO defaulting: "" is a
// first-class value (the F1 production route). Callers that want "go" say "go".
func TestBuildEnvelopeSourceTypeOverride(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  string
	}{
		{"empty stays empty (F1 route — no defaulting, post-10.9)", "", ""},
		{"explicit go still yields go", "go", "go"},
		{"refactored routes to shadow DB (ADR-0012)", "refactored", "refactored"},
		{"arbitrary custom value pass-through (worker fail-safes it)", "unknown", "unknown"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := BuildEnvelope(EnvelopeInput{
				Tenant:       "cpack",
				PublisherKey: "CPACK/edge-01",
				Instance:     "test",
				SourceType:   tc.input,
			})
			if env.SourceType != tc.want {
				t.Errorf("SourceType(input=%q): got %q, want %q", tc.input, env.SourceType, tc.want)
			}
		})
	}
}

// TestBuildEnvelopeEmptyMetrics — the builder handles the empty case.
func TestBuildEnvelopeEmptyMetrics(t *testing.T) {
	env := BuildEnvelope(EnvelopeInput{
		Tenant:          "cpack",
		PublisherKey:    "CPACK/edge-01",
		Instance:        "test",
		Metrics:         nil,
		SourceTimestamp: 1782161858551,
	})
	if len(env.Metrics) != 0 {
		t.Errorf("Metrics: got %d entries, want 0", len(env.Metrics))
	}
}

// TestIsConnectionError covers the whitelist of error substrings that
// trigger the shadowpub reconnect path.
func TestIsConnectionError(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil error", nil, false},
		{"unrelated", &testErr{"nack: memory alarm"}, false},
		{"channel closed", &testErr{"channel/connection is not open"}, true},
		{"connection closed", &testErr{"connection closed"}, true},
		{"broken pipe", &testErr{"write: broken pipe"}, true},
		{"EOF", &testErr{"EOF"}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := isConnectionError(tc.err)
			if got != tc.want {
				t.Errorf("isConnectionError: got %v, want %v", got, tc.want)
			}
		})
	}
}

type testErr struct{ s string }

func (e *testErr) Error() string { return e.s }
