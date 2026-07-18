package handlers

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"testing"

	amqp "github.com/rabbitmq/amqp091-go"
)

// TestHandle_DoubleEncodedEnvelope_Dropped is the task #92 regression: a
// double-encoded envelope (a JSON string of JSON) on sparkplug.data must be
// DROPPED (ack, counted) — never nack-retried — even with legacyIngest=true
// (the staging config where the #89 poison storm surfaced). Retrying it can
// never succeed because the delivered bytes are fixed, so a returned error
// here would reproduce the ~2/s nack→DLX→redeliver storm.
func TestHandle_DoubleEncodedEnvelope_Dropped(t *testing.T) {
	discard := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := &SparkplugHandler{logger: discard}
	h.SetLegacyIngest(true) // worst case: legacy branch would otherwise nack-retry

	// Build the exact wire shape: marshal a valid envelope once (object), then
	// marshal that serialized JSON a SECOND time → a quoted JSON string.
	single, err := json.Marshal(map[string]any{
		"timestamp": 1782161858551,
		"gateway":   "simulator",
		"metrics": []map[string]any{
			{"name": "CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent", "timestamp": 1782161858551, "value": 6},
		},
	})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	double, err := json.Marshal(string(single))
	if err != nil {
		t.Fatalf("double-marshal: %v", err)
	}
	if double[0] != '"' {
		t.Fatalf("expected double-encoded body to start with '\"', got %q", double[0])
	}

	d := &amqp.Delivery{RoutingKey: "sparkplug.data", Body: double}
	if err := h.Handle(context.Background(), d); err != nil {
		t.Fatalf("Handle must DROP (return nil) a double-encoded body, got err=%v (would nack-retry → poison storm)", err)
	}
	if got := h.DoubleEncodedDroppedCount(); got != 1 {
		t.Fatalf("DoubleEncodedDroppedCount = %d, want 1", got)
	}
	// It must NOT have been counted as a legacy drop nor as parsed.
	if got := h.LegacyDroppedCount(); got != 0 {
		t.Fatalf("LegacyDroppedCount = %d, want 0 (double-encode has its own counter)", got)
	}
}

// TestHandle_MalformedNonStringJSON_PreservesLegacySemantics guards the blast
// radius of the #92 guard: a NON-string malformed body (e.g. a truncated
// object) must keep the existing behavior — nack-retry when legacyIngest=true
// (dead-letter for inspection), drop when false. Only the deterministic
// JSON-string variant is special-cased.
func TestHandle_MalformedNonStringJSON_PreservesLegacySemantics(t *testing.T) {
	discard := slog.New(slog.NewTextHandler(io.Discard, nil))
	truncated := []byte(`{"timestamp":1,"metrics":[`) // valid start, invalid JSON

	// legacyIngest=true → must return an error (nack → dead-letter path intact).
	h := &SparkplugHandler{logger: discard}
	h.SetLegacyIngest(true)
	d := &amqp.Delivery{RoutingKey: "sparkplug.data", Body: truncated}
	if err := h.Handle(context.Background(), d); err == nil {
		t.Fatal("malformed non-string JSON with legacyIngest=true must return err (nack to dead-letter), got nil")
	}
	if h.DoubleEncodedDroppedCount() != 0 {
		t.Fatal("truncated object must NOT be classified as a double-encode drop")
	}

	// legacyIngest=false → dropped as legacy noise (return nil, counted).
	h2 := &SparkplugHandler{logger: discard}
	h2.SetLegacyIngest(false)
	d2 := &amqp.Delivery{RoutingKey: "sparkplug.data", Body: truncated}
	if err := h2.Handle(context.Background(), d2); err != nil {
		t.Fatalf("malformed JSON with legacyIngest=false must drop (nil), got err=%v", err)
	}
	if h2.LegacyDroppedCount() != 1 {
		t.Fatalf("LegacyDroppedCount = %d, want 1", h2.LegacyDroppedCount())
	}
}
