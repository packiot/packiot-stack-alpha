package uplink

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// fakeMessage is a minimal paho.Message carrying a topic + body — enough to
// drive onNCMD without a live broker.
type fakeMessage struct {
	topic string
	body  []byte
}

func (m fakeMessage) Duplicate() bool   { return false }
func (m fakeMessage) Qos() byte         { return 1 }
func (m fakeMessage) Retained() bool    { return false }
func (m fakeMessage) Topic() string     { return m.topic }
func (m fakeMessage) MessageID() uint16 { return 0 }
func (m fakeMessage) Payload() []byte   { return m.body }
func (m fakeMessage) Ack()              {}

// TestOnNCMD_RebirthRequest proves the edge-node half of task #31: a
// "Node Control/Rebirth"=true NCMD arms pendingRebirth (so the single-drainer
// republishes NBIRTH on its next tick) AND fires the metric hook.
func TestOnNCMD_RebirthRequest(t *testing.T) {
	u, _ := newTestUplink(t)
	u.pendingRebirth.Store(false) // clear the constructor/connect default

	var hookFired int
	u.SetRebirthMetric(func() { hookFired++ })

	body, err := sparkplug.EncodeRebirthNCMD()
	if err != nil {
		t.Fatalf("encode NCMD: %v", err)
	}
	u.onNCMD(nil, fakeMessage{topic: u.ncmdTopic, body: body})

	if !u.pendingRebirth.Load() {
		t.Fatal("Rebirth NCMD must arm pendingRebirth so the drainLoop republishes NBIRTH")
	}
	if got := u.rebirthsNCMD.Load(); got != 1 {
		t.Fatalf("rebirthsNCMD counter: got %d, want 1", got)
	}
	if hookFired != 1 {
		t.Fatalf("Prometheus hook fired %d times, want 1", hookFired)
	}
}

// TestOnNCMD_NonRebirthIgnored proves a non-rebirth (or malformed) NCMD is a
// no-op: no rebirth armed, no counter bump. Guards against a spurious NBIRTH
// storm from unrelated host commands.
func TestOnNCMD_NonRebirthIgnored(t *testing.T) {
	u, _ := newTestUplink(t)
	u.pendingRebirth.Store(false)

	// A well-formed NCMD that is NOT a rebirth request.
	name := "Node Control/Reboot"
	other, err := sparkplug.Encode(&sparkplug.Payload{Metrics: []*sparkplug.Metric{{
		Name:  &name,
		Value: &sparkplug.Metric_BooleanValue{BooleanValue: true},
	}}})
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	u.onNCMD(nil, fakeMessage{topic: u.ncmdTopic, body: other})
	if u.pendingRebirth.Load() {
		t.Fatal("non-rebirth NCMD must NOT arm pendingRebirth")
	}

	// Garbage payload → decode fails → no-op (no panic, no arm).
	u.onNCMD(nil, fakeMessage{topic: u.ncmdTopic, body: []byte("not-protobuf\xff\xfe")})
	if u.pendingRebirth.Load() {
		t.Fatal("undecodable NCMD must NOT arm pendingRebirth")
	}
	if got := u.rebirthsNCMD.Load(); got != 0 {
		t.Fatalf("rebirthsNCMD counter: got %d, want 0", got)
	}
}
