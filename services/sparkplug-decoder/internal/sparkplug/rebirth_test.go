package sparkplug

import "testing"

// TestRebirthNCMDRoundTrip proves the consumer-built NCMD survives an
// Encode→wire→Decode round trip and is recognised as a rebirth request — the
// exact path a real NCMD takes from edge-transformer through mosquitto to the
// agent. A break here silently kills the whole task #31 self-heal.
func TestRebirthNCMDRoundTrip(t *testing.T) {
	body, err := EncodeRebirthNCMD()
	if err != nil {
		t.Fatalf("EncodeRebirthNCMD: %v", err)
	}
	p, err := Decode(body)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if !IsRebirthRequest(p) {
		t.Fatal("decoded NCMD not recognised as a rebirth request")
	}
	// The metric must carry the exact well-known name + a boolean true.
	if got := len(p.GetMetrics()); got != 1 {
		t.Fatalf("rebirth NCMD metrics: got %d, want 1", got)
	}
	m := p.GetMetrics()[0]
	if m.GetName() != MetricNodeControlRebirth {
		t.Fatalf("metric name: got %q, want %q", m.GetName(), MetricNodeControlRebirth)
	}
	if !m.GetBooleanValue() {
		t.Fatal("rebirth metric value must be boolean true")
	}
}

func TestIsRebirthRequest_Negatives(t *testing.T) {
	if IsRebirthRequest(nil) {
		t.Fatal("nil payload must not be a rebirth request")
	}
	// Empty payload.
	if IsRebirthRequest(&Payload{}) {
		t.Fatal("empty payload must not be a rebirth request")
	}
	// Rebirth metric present but false → not a request.
	name := MetricNodeControlRebirth
	falseReq := &Payload{Metrics: []*Metric{{
		Name:  &name,
		Value: &Metric_BooleanValue{BooleanValue: false},
	}}}
	if IsRebirthRequest(falseReq) {
		t.Fatal("Rebirth=false must not trigger a rebirth")
	}
	// Some other NCMD metric → ignored.
	other := "Node Control/Reboot"
	otherReq := &Payload{Metrics: []*Metric{{
		Name:  &other,
		Value: &Metric_BooleanValue{BooleanValue: true},
	}}}
	if IsRebirthRequest(otherReq) {
		t.Fatal("unrelated NCMD metric must not trigger a rebirth")
	}
}
