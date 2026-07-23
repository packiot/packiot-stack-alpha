package rawtag

import "testing"

func TestDecode_Envelope(t *testing.T) {
	body := []byte(`{
	  "endpoint": "L5_BREYER",
	  "scan_ts": 1782849957000,
	  "tags": [
	    {"metric": "/Status/MachSpeed", "value": 12.5, "q": true},
	    {"metric": "/Status/StateCurrent", "value": 6, "long": true},
	    {"metric": "/Status/PoNumber", "value": "PO-1"},
	    {"metric": "/Status/Bad", "value": false, "q": false, "ts": 1782849958000}
	  ]
	}`)
	tags, err := Decode(body)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(tags) != 4 {
		t.Fatalf("tag count: got %d, want 4", len(tags))
	}

	// Envelope endpoint propagates to every tag.
	if tags[0].EndpointOrPath != "L5_BREYER" {
		t.Errorf("endpoint: got %q", tags[0].EndpointOrPath)
	}
	// scan_ts is the default per-tag timestamp.
	if tags[0].TsMillis != 1782849957000 {
		t.Errorf("ts default: got %d", tags[0].TsMillis)
	}
	// Numbers land as float64 (JSON's only numeric type).
	if v, ok := tags[0].Value.(float64); !ok || v != 12.5 {
		t.Errorf("MachSpeed value: got %v (%T)", tags[0].Value, tags[0].Value)
	}
	// `long: true` surfaces as the type hint.
	if tags[1].Type != "long" {
		t.Errorf("StateCurrent type hint: got %q, want long", tags[1].Type)
	}
	// Absent `q` ⇒ good quality.
	if !tags[2].Quality {
		t.Error("absent q should default to good quality")
	}
	// Explicit q:false + per-tag ts override.
	if tags[3].Quality {
		t.Error("q:false should yield bad quality")
	}
	if tags[3].TsMillis != 1782849958000 {
		t.Errorf("per-tag ts override: got %d", tags[3].TsMillis)
	}
	if v, ok := tags[3].Value.(bool); !ok || v != false {
		t.Errorf("bool value: got %v (%T)", tags[3].Value, tags[3].Value)
	}
}

func TestDecode_Errors(t *testing.T) {
	if _, err := Decode([]byte(`not json`)); err == nil {
		t.Error("malformed body should error")
	}
	if _, err := Decode([]byte(`{"tags":[{"metric":"","value":1}]}`)); err == nil {
		t.Error("empty metric suffix should error")
	}
	if _, err := Decode([]byte(`{"tags":[{"metric":"/x","value":[1,2]}]}`)); err == nil {
		t.Error("non-scalar value should error")
	}
}

func TestDecode_EmptyTags(t *testing.T) {
	tags, err := Decode([]byte(`{"endpoint":"e","scan_ts":1,"tags":[]}`))
	if err != nil {
		t.Fatalf("empty tags should not error: %v", err)
	}
	if len(tags) != 0 {
		t.Fatalf("got %d tags, want 0", len(tags))
	}
}
