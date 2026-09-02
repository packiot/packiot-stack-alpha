package rawtag

import "testing"

// TestEncode_Decode_RoundTrip proves Encode is the inverse of Decode: a
// producer that builds OutTags and calls Encode yields a body Decode reads
// back with metric, value, and the long hint preserved. JSON has one numeric
// type, so an int64 comes back as float64 (same as the live wire) — the Long
// hint is what tells a consumer it was an integer.
func TestEncode_Decode_RoundTrip(t *testing.T) {
	const endpoint = "L5_BREYER"
	const scanTS int64 = 1782849957000

	out := []OutTag{
		{Metric: "/Status/MachSpeed", Value: 12.5},                                   // float64 → Double
		{Metric: "/Admin/ProdProcessedCount/1/Unit", Value: int64(4200), Long: true}, // int64 + long hint
		{Metric: "/Status/StateCurrent", Value: int64(6), Long: true},                // int64 + long hint
		{Metric: "/Status/Running", Value: true},                                     // bool
		{Metric: "/Status/PoNumber", Value: "PO-1"},                                  // string
	}

	body, err := Encode(endpoint, scanTS, out)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}

	tags, err := Decode(body)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(tags) != len(out) {
		t.Fatalf("tag count: got %d, want %d", len(tags), len(out))
	}

	// Envelope endpoint + scan_ts propagate to every decoded tag.
	if tags[0].EndpointOrPath != endpoint {
		t.Errorf("endpoint: got %q, want %q", tags[0].EndpointOrPath, endpoint)
	}
	if tags[0].TsMillis != scanTS {
		t.Errorf("scan_ts: got %d, want %d", tags[0].TsMillis, scanTS)
	}

	// Metric suffixes survive in order.
	for i := range out {
		if tags[i].Metric != out[i].Metric {
			t.Errorf("tags[%d].Metric: got %q, want %q", i, tags[i].Metric, out[i].Metric)
		}
	}

	// float64 → Double: exact.
	if v, ok := tags[0].Value.(float64); !ok || v != 12.5 {
		t.Errorf("MachSpeed value: got %v (%T), want 12.5", tags[0].Value, tags[0].Value)
	}

	// int64 + Long hint: value lands as float64 (JSON's only numeric type),
	// and the "long" type hint is preserved so the consumer knows it's integral.
	if v, ok := tags[1].Value.(float64); !ok || v != 4200 {
		t.Errorf("count value: got %v (%T), want 4200", tags[1].Value, tags[1].Value)
	}
	if tags[1].Type != "long" {
		t.Errorf("count long hint: got %q, want long", tags[1].Type)
	}
	if v, ok := tags[2].Value.(float64); !ok || v != 6 {
		t.Errorf("StateCurrent value: got %v (%T), want 6", tags[2].Value, tags[2].Value)
	}
	if tags[2].Type != "long" {
		t.Errorf("StateCurrent long hint: got %q, want long", tags[2].Type)
	}

	// bool round-trips as bool, with no long hint.
	if v, ok := tags[3].Value.(bool); !ok || v != true {
		t.Errorf("Running value: got %v (%T), want true", tags[3].Value, tags[3].Value)
	}
	if tags[3].Type != "" {
		t.Errorf("Running should carry no long hint, got %q", tags[3].Type)
	}

	// string round-trips as string.
	if v, ok := tags[4].Value.(string); !ok || v != "PO-1" {
		t.Errorf("PoNumber value: got %v (%T), want PO-1", tags[4].Value, tags[4].Value)
	}
}

// TestEncode_EmptyTags: a heartbeat scan with no readings is a legal empty
// envelope, and Decode reads it back to an empty slice (not an error).
func TestEncode_EmptyTags(t *testing.T) {
	body, err := Encode("e", 1, nil)
	if err != nil {
		t.Fatalf("encode empty: %v", err)
	}
	tags, err := Decode(body)
	if err != nil {
		t.Fatalf("decode empty: %v", err)
	}
	if len(tags) != 0 {
		t.Fatalf("got %d tags, want 0", len(tags))
	}
}
