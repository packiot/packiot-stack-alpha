// Unit tests for the pure-function seams of the shadow publisher.
// AMQP-touching Publish() has no unit test here — that's integration-shaped
// and needs a live broker. See docker-compose + `mqtt_integration` build
// tag work for that.

package shadowpub

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

func TestBuildEnvelopeCanonicalShape(t *testing.T) {
	in := EnvelopeInput{
		Tenant:          "cpack",
		PublisherKey:    "CPACK/edge-01",
		Instance:        "edge-transformer-hostname",
		IngestedAt:      "2026-06-30T20:00:00.000Z",
		SourceTimestamp: "2026-06-30T19:59:59.500Z",
		Metric: sparkplug.ResolvedMetric{
			Name:      "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit",
			Alias:     1,
			Timestamp: 1782849957000,
			Datatype:  uint32(sparkplug.DataType_Int64.Number()),
			Value:     uint64(12345),
		},
	}

	env := BuildEnvelope(in)

	if env.SchemaVersion != "1.0" {
		t.Errorf("schema_version: got %q, want %q", env.SchemaVersion, "1.0")
	}
	if env.Envelope.Tenant != "cpack" {
		t.Errorf("tenant: got %q", env.Envelope.Tenant)
	}
	if env.Envelope.Source.Type != "go" {
		t.Errorf("source.type: got %q, want %q", env.Envelope.Source.Type, "go")
	}
	if env.Envelope.Source.Package != "sparkplug" {
		t.Errorf("source.package: got %q", env.Envelope.Source.Package)
	}
	if env.Envelope.MessageID == "" || env.Envelope.MessageID != env.Envelope.TraceID {
		t.Errorf("message_id / trace_id: got %q / %q (want non-empty + equal)",
			env.Envelope.MessageID, env.Envelope.TraceID)
	}
	if env.Envelope.PublisherKey != "CPACK/edge-01" {
		t.Errorf("publisher_key: got %q", env.Envelope.PublisherKey)
	}
	if env.Envelope.OrderingKey != "publisher_CPACK_edge-01" {
		t.Errorf("ordering_key: got %q", env.Envelope.OrderingKey)
	}
	if env.Type != "sparkplug.metric" {
		t.Errorf("type: got %q", env.Type)
	}
	if env.Payload.Parameter != "Unit" {
		t.Errorf("parameter: got %q, want %q", env.Payload.Parameter, "Unit")
	}
	if env.Payload.Datatype != "int64" {
		t.Errorf("datatype: got %q, want %q", env.Payload.Datatype, "int64")
	}
	if env.Payload.Value != uint64(12345) {
		t.Errorf("value: got %v, want 12345", env.Payload.Value)
	}
	if env.Payload.EquipmentID != 0 {
		t.Errorf("equipment_id: got %d, want 0 (Phase 3 lookup TBD)", env.Payload.EquipmentID)
	}
	if env.Payload.SourceMetricName != in.Metric.Name {
		t.Errorf("source_metric_name preserved: got %q", env.Payload.SourceMetricName)
	}
}

func TestBuildEnvelopeJSONShape(t *testing.T) {
	// Round-trip a built envelope through json and back — asserts field
	// names + wire format match what Phase 2.5b's Node-RED publisher emits.
	in := EnvelopeInput{
		Tenant:          "cpack",
		PublisherKey:    "CPACK/edge-01",
		Instance:        "test",
		IngestedAt:      "2026-06-30T20:00:00.000Z",
		SourceTimestamp: "2026-06-30T19:59:59.500Z",
		Metric: sparkplug.ResolvedMetric{
			Name:     "CPACK/SC/LINHAS/L5/BREYER/Admin/Count",
			Datatype: uint32(sparkplug.DataType_Float.Number()),
			Value:    float32(3.14),
		},
	}
	body, err := json.Marshal(BuildEnvelope(in))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(body)

	// Assert canonical field names appear
	for _, want := range []string{
		`"schema_version":"1.0"`,
		`"tenant":"cpack"`,
		`"type":"go"`,
		`"package":"sparkplug"`,
		`"type":"sparkplug.metric"`,
		`"equipment_id":0`,
		`"parameter":"Count"`,
		`"datatype":"float"`,
		`"quality":"good"`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("marshal missing %s\nfull:\n%s", want, s)
		}
	}
}

func TestParameterFromMetricName(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"CPACK/SC/L5/BREYER/Admin/ProdConsumedCount/61/Unit", "Unit"},
		{"CPACK/SC/L5/BREYER/Status/StateCurrent", "StateCurrent"},
		{"foo", "foo"},
		{"", "unknown"},
		{"trailing/", "trailing/"},
	}
	for _, tc := range cases {
		if got := parameterFromMetricName(tc.in); got != tc.want {
			t.Errorf("parameterFromMetricName(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestDatatypeToString(t *testing.T) {
	// Sample the canonical Sparkplug B datatypes we care about most.
	cases := map[sparkplug.DataType]string{
		sparkplug.DataType_Int8:    "int32",
		sparkplug.DataType_Int32:   "int32",
		sparkplug.DataType_Int64:   "int64",
		sparkplug.DataType_UInt64:  "uint64",
		sparkplug.DataType_Float:   "float",
		sparkplug.DataType_Double:  "double",
		sparkplug.DataType_Boolean: "bool",
		sparkplug.DataType_String:  "string",
	}
	for dt, want := range cases {
		if got := datatypeToString(uint32(dt.Number())); got != want {
			t.Errorf("datatype %v: got %q, want %q", dt, got, want)
		}
	}
	// Unknowns fall back to "auto"
	if got := datatypeToString(99); got != "auto" {
		t.Errorf("unknown datatype: got %q, want auto", got)
	}
}

func TestMessageIDUnique(t *testing.T) {
	seen := make(map[string]bool)
	for i := 0; i < 100; i++ {
		id := newMessageID()
		if seen[id] {
			t.Fatalf("collision on iter %d: %q", i, id)
		}
		if len(id) == 0 {
			t.Fatalf("empty id on iter %d", i)
		}
		seen[id] = true
	}
}
