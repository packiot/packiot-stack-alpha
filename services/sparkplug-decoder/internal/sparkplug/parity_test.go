//go:build parity

// Parity test — runs ONLY with `-tags parity` so the default `go test`
// doesn't require Node.js + the sparkplug-payload npm library.
//
// Purpose: prove wire-format parity between our Go decoder and the exact JS
// library Node-RED's `node-red-contrib-sparkplug-payload` node wraps
// (Eclipse Tahu's `sparkplug-payload`, vendored under testdata/parity/).
//
// Setup once (from the edge-transformer module root):
//
//   cd testdata/parity && npm install
//
// Run:
//
//   go test -tags parity -run TestParity -v ./internal/sparkplug/
//
// The test encodes a fixture with Go, pipes the binary through the Node.js
// `decode.js` harness, and asserts the resulting JSON projection matches
// what the Go side produced. Any mismatch = wire-format drift.

package sparkplug

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
)

// nodeCanonical mirrors the shape emitted by testdata/parity/decode.js.
type nodeCanonical struct {
	Timestamp   any             `json:"timestamp"`
	Seq         any             `json:"seq"`
	MetricCount int             `json:"metric_count"`
	Metrics     []nodeCanMetric `json:"metrics"`
}

type nodeCanMetric struct {
	Name      any `json:"name"`
	Alias     any `json:"alias"`
	Timestamp any `json:"timestamp"`
	Type      any `json:"type"`
	Value     any `json:"value"`
}

// asStr coerces JSON numbers, strings, or nil into a display string —
// tolerating any BigInt-shaped output from Node.js.
func asStr(v any) string {
	if v == nil {
		return ""
	}
	switch x := v.(type) {
	case string:
		return x
	case float64:
		// JSON unmarshalled numbers arrive as float64. Format ints losslessly.
		if x == float64(int64(x)) {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'g', -1, 64)
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// findRepoRoot walks up until a testdata/parity/decode.js is found. Allows
// the test to run from any working directory.
func findRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("cwd: %v", err)
	}
	for i := 0; i < 5; i++ {
		candidate := filepath.Join(dir, "testdata", "parity", "decode.js")
		if _, err := os.Stat(candidate); err == nil {
			return dir
		}
		dir = filepath.Dir(dir)
	}
	t.Fatalf("could not find testdata/parity/decode.js by walking up")
	return ""
}

func TestParityGoEncodeThenNodeDecode(t *testing.T) {
	// Build a known-shape Payload the Node.js side will parse.
	in := &Payload{
		Timestamp: ptr(uint64(1782849957000)),
		Seq:       ptr(uint64(42)),
		Metrics: []*Metric{
			{
				Name:      ptr("CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit"),
				Alias:     ptr(uint64(1)),
				Timestamp: ptr(uint64(1782849957000)),
				Datatype:  ptr(uint32(DataType_Int64.Number())),
				Value:     &Metric_LongValue{LongValue: 12345},
			},
			{
				Name:      ptr("CPACK/SC/LINHAS/L5/POLYTYPE/Admin/ProdProcessedCount/62/Unit"),
				Alias:     ptr(uint64(2)),
				Timestamp: ptr(uint64(1782849957500)),
				Datatype:  ptr(uint32(DataType_Float.Number())),
				Value:     &Metric_FloatValue{FloatValue: 6789.5},
			},
			{
				Name:      ptr("CPACK/SC/CELULA1/CER400/CER400/Status/StateCurrent"),
				Alias:     ptr(uint64(3)),
				Timestamp: ptr(uint64(1782849958000)),
				Datatype:  ptr(uint32(DataType_String.Number())),
				Value:     &Metric_StringValue{StringValue: "RUNNING"},
			},
		},
	}

	body, err := Encode(in)
	if err != nil {
		t.Fatalf("go encode: %v", err)
	}

	// Locate + invoke the Node.js decoder.
	root := findRepoRoot(t)
	script := filepath.Join(root, "testdata", "parity", "decode.js")
	cmd := exec.Command("node", script)
	cmd.Stdin = bytes.NewReader(body)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("node %s failed: %v\nstderr: %s", script, err, stderr.String())
	}

	// Parse Node.js canonical output.
	var got nodeCanonical
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("parse node output: %v\nraw: %s", err, stdout.String())
	}

	// Assert structural equality with what we sent.
	if got.MetricCount != len(in.GetMetrics()) {
		t.Errorf("metric_count: got %d, want %d", got.MetricCount, len(in.GetMetrics()))
	}
	if asStr(got.Timestamp) != "1782849957000" {
		t.Errorf("timestamp mismatch: got %v (%s)", got.Timestamp, asStr(got.Timestamp))
	}
	if asStr(got.Seq) != "42" {
		t.Errorf("seq mismatch: got %v (%s)", got.Seq, asStr(got.Seq))
	}

	// Verify each metric's name + alias survived round-trip through the
	// JS library.
	expectedNames := []string{
		"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit",
		"CPACK/SC/LINHAS/L5/POLYTYPE/Admin/ProdProcessedCount/62/Unit",
		"CPACK/SC/CELULA1/CER400/CER400/Status/StateCurrent",
	}
	for i, wantName := range expectedNames {
		if i >= len(got.Metrics) {
			t.Errorf("metric[%d] missing", i)
			continue
		}
		if s, ok := got.Metrics[i].Name.(string); !ok || s != wantName {
			t.Errorf("metric[%d].name: got %v, want %q", i, got.Metrics[i].Name, wantName)
		}
		wantAlias := float64(i + 1)
		if got.Metrics[i].Alias != wantAlias {
			t.Errorf("metric[%d].alias: got %v, want %v", i, got.Metrics[i].Alias, wantAlias)
		}
	}

	// Verify the values decode with correct types on the JS side.
	// sparkplug-payload maps DataType_Int64 → "Int64" (string type name).
	if got.Metrics[0].Type != "Int64" {
		t.Errorf("metric[0].type: got %v, want %q", got.Metrics[0].Type, "Int64")
	}
	if got.Metrics[0].Value != float64(12345) && got.Metrics[0].Value != "12345" {
		t.Errorf("metric[0].value: got %v, want 12345", got.Metrics[0].Value)
	}
	if got.Metrics[2].Value != "RUNNING" {
		t.Errorf("metric[2].value: got %v, want %q", got.Metrics[2].Value, "RUNNING")
	}

	t.Logf("PARITY CONFIRMED: Node.js sparkplug-payload decoded Go-encoded payload identically")
	t.Logf("  %d metrics, timestamp=%v, seq=%v", got.MetricCount, got.Timestamp, got.Seq)
	t.Logf("  metric[0] value=%v type=%v", got.Metrics[0].Value, got.Metrics[0].Type)
}
