// Spike validation: confirm we can round-trip a Sparkplug B payload and that
// the decoded structure matches the input. If this passes, edge-transformer
// can replace Node-RED's SparkPlug subflow for the decode step (ADR-0010).
//
// Future work (out of spike scope):
//   - Parity test against a real Node-RED-decoded payload (capture from prod
//     MQTT, decode in both, diff). The spike below proves library correctness;
//     parity proves OUR USE of the library matches Node-RED's USE.
//   - Performance benchmark vs Node-RED's JavaScript decoder (Go should win
//     by 10-100x on the binary parse path).

package sparkplug

import (
	"testing"

	"google.golang.org/protobuf/proto"
)

// ptr is a tiny generic helper for proto2-style optional fields.
func ptr[T any](v T) *T { return &v }

// TestDecodeRoundTrip builds a Sparkplug B payload, encodes to wire bytes,
// decodes back, and asserts structural equality. This is the minimal
// feasibility check that proves the proto bindings work.
func TestDecodeRoundTrip(t *testing.T) {
	// Construct a payload mirroring what a factory PLC would publish on a
	// "data" message: timestamp + sequence number + N metrics with the
	// canonical Sparkplug topic shape (ENT/SITE/AREA/LINE/UNIT/.../Counter).
	in := &Payload{
		Timestamp: ptr(uint64(1782849957000)),
		Seq:       ptr(uint64(42)),
		Metrics: []*Metric{
			{
				Name:      ptr("CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit"),
				Timestamp: ptr(uint64(1782849957000)),
				Datatype:  ptr(uint32(DataType_Int64.Number())),
				Value:     &Metric_LongValue{LongValue: 12345},
			},
			{
				Name:      ptr("CPACK/SC/LINHAS/L5/POLYTYPE/Admin/ProdProcessedCount/62/Unit"),
				Timestamp: ptr(uint64(1782849957500)),
				Datatype:  ptr(uint32(DataType_Float.Number())),
				Value:     &Metric_FloatValue{FloatValue: 6789.5},
			},
			{
				Name:      ptr("CPACK/SC/CELULA1/CER400/CER400/Status/StateCurrent"),
				Timestamp: ptr(uint64(1782849958000)),
				Datatype:  ptr(uint32(DataType_String.Number())),
				Value:     &Metric_StringValue{StringValue: "RUNNING"},
			},
		},
	}

	// Encode → bytes
	body, err := Encode(in)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if len(body) == 0 {
		t.Fatal("encode produced empty body")
	}

	// Decode → struct
	out, err := Decode(body)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}

	// Top-level fields
	if out.GetTimestamp() != in.GetTimestamp() {
		t.Errorf("timestamp: got %d, want %d", out.GetTimestamp(), in.GetTimestamp())
	}
	if out.GetSeq() != in.GetSeq() {
		t.Errorf("seq: got %d, want %d", out.GetSeq(), in.GetSeq())
	}
	if len(out.GetMetrics()) != len(in.GetMetrics()) {
		t.Fatalf("metrics count: got %d, want %d", len(out.GetMetrics()), len(in.GetMetrics()))
	}

	// Per-metric fields
	for i, want := range in.GetMetrics() {
		got := out.GetMetrics()[i]
		if got.GetName() != want.GetName() {
			t.Errorf("metric[%d].name: got %q, want %q", i, got.GetName(), want.GetName())
		}
		if got.GetTimestamp() != want.GetTimestamp() {
			t.Errorf("metric[%d].timestamp: got %d, want %d", i, got.GetTimestamp(), want.GetTimestamp())
		}
		if got.GetDatatype() != want.GetDatatype() {
			t.Errorf("metric[%d].datatype: got %d, want %d", i, got.GetDatatype(), want.GetDatatype())
		}
	}

	// Verify wire-level identity via proto.Equal — strictest comparison
	if !proto.Equal(in, out) {
		t.Errorf("proto.Equal: round-trip not identical\n in: %v\nout: %v", in, out)
	}
}

// TestDecodeMalformed verifies graceful error handling on bad input.
func TestDecodeMalformed(t *testing.T) {
	cases := []struct {
		name string
		body []byte
	}{
		{"empty", []byte{}},
		{"garbage", []byte{0xff, 0xff, 0xff, 0xff}},
		{"truncated", []byte{0x08}}, // varint tag without value
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Decode(tc.body)
			if tc.name == "empty" {
				// Empty body is a valid empty Payload per proto2 spec — no error
				if err != nil {
					t.Errorf("empty body should decode to empty payload, got error: %v", err)
				}
				return
			}
			if err == nil {
				t.Errorf("expected error for %q input, got nil", tc.name)
			}
		})
	}
}

// TestDataTypeEnumStable confirms the canonical Sparkplug B DataType enum
// values are intact after generation. If any of these drift, the wire format
// is incompatible with other Sparkplug B implementations and the spike is
// invalid.
func TestDataTypeEnumStable(t *testing.T) {
	expected := map[string]int32{
		"Int8":    1,
		"Int16":   2,
		"Int32":   3,
		"Int64":   4,
		"UInt8":   5,
		"UInt16":  6,
		"UInt32":  7,
		"UInt64":  8,
		"Float":   9,
		"Double":  10,
		"Boolean": 11,
		"String":  12,
	}
	for name, want := range expected {
		dt, ok := DataType_value[name]
		if !ok {
			t.Errorf("DataType %q missing from generated enum", name)
			continue
		}
		if dt != want {
			t.Errorf("DataType %q: got %d, want %d (wire-format break)", name, dt, want)
		}
	}
}
