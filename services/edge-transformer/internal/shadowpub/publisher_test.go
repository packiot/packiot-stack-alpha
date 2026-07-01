// Unit tests for the pure-function seams of the shadow publisher.
// AMQP-touching Publish() has no unit test here — that's integration-shaped
// and needs a live broker. See docker-compose + `mqtt_integration` build
// tag work for that.

package shadowpub

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"

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

// ── ADR-0011 rule 1: publisher confirms + observable failure ─────────────────
//
// waitConfirm is unit-testable in isolation: we control the confirms channel
// + the deadline + the context. Each terminal state (ack / nack / timeout /
// ctx.Cancel) must produce the right typed error + increment the right
// counter. Silent success is a bug per ADR-0011 rule 5.

// newTestPublisher builds a Publisher that isn't connected to a real broker.
// waitConfirm only reads from p.confirms and touches counters — no AMQP.
func newTestPublisher() *Publisher {
	return &Publisher{
		logger:         slog.New(slog.NewTextHandler(os.Stderr, nil)),
		ConfirmTimeout: 100 * time.Millisecond,
		confirms:       make(chan amqp.Confirmation, 4),
	}
}

func TestWaitConfirmAck(t *testing.T) {
	p := newTestPublisher()
	go func() { p.confirms <- amqp.Confirmation{DeliveryTag: 1, Ack: true} }()

	if err := p.waitConfirm(context.Background(), p.ConfirmTimeout); err != nil {
		t.Fatalf("expected nil, got %v", err)
	}
	if p.ConfirmedCount() != 1 {
		t.Errorf("ConfirmedCount: got %d, want 1", p.ConfirmedCount())
	}
	if p.NackedCount() != 0 || p.ConfirmTimeoutCount() != 0 {
		t.Errorf("unexpected side effects: nacked=%d timeout=%d",
			p.NackedCount(), p.ConfirmTimeoutCount())
	}
}

func TestWaitConfirmNackReturnsTypedError(t *testing.T) {
	p := newTestPublisher()
	go func() { p.confirms <- amqp.Confirmation{DeliveryTag: 1, Ack: false} }()

	err := p.waitConfirm(context.Background(), p.ConfirmTimeout)
	if !errors.Is(err, ErrPublishNacked) {
		t.Fatalf("want ErrPublishNacked, got %v", err)
	}
	if p.NackedCount() != 1 {
		t.Errorf("NackedCount: got %d, want 1", p.NackedCount())
	}
	if p.ConfirmedCount() != 0 {
		t.Errorf("ConfirmedCount should not advance on nack")
	}
}

func TestWaitConfirmTimeoutReturnsTypedError(t *testing.T) {
	p := newTestPublisher()
	// deliberately DON'T send anything to p.confirms
	err := p.waitConfirm(context.Background(), 20*time.Millisecond)
	if !errors.Is(err, ErrConfirmTimeout) {
		t.Fatalf("want ErrConfirmTimeout, got %v", err)
	}
	if p.ConfirmTimeoutCount() != 1 {
		t.Errorf("ConfirmTimeoutCount: got %d, want 1", p.ConfirmTimeoutCount())
	}
}

func TestWaitConfirmCtxCancel(t *testing.T) {
	p := newTestPublisher()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(10 * time.Millisecond)
		cancel()
	}()
	err := p.waitConfirm(ctx, 500*time.Millisecond)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got %v", err)
	}
	// Neither ack nor timeout should have been counted
	if p.ConfirmedCount() != 0 || p.ConfirmTimeoutCount() != 0 {
		t.Errorf("cancel counted as ack/timeout: confirmed=%d timeout=%d",
			p.ConfirmedCount(), p.ConfirmTimeoutCount())
	}
}

func TestWaitConfirmClosedChannelSurfaced(t *testing.T) {
	p := newTestPublisher()
	close(p.confirms)
	err := p.waitConfirm(context.Background(), 500*time.Millisecond)
	if err == nil {
		t.Fatal("closed confirms channel should surface an error, got nil")
	}
	if !strings.Contains(err.Error(), "confirms channel closed") {
		t.Errorf("unexpected error text: %v", err)
	}
	if p.FailedCount() != 1 {
		t.Errorf("FailedCount: got %d, want 1", p.FailedCount())
	}
}

// TestCounterGettersReflectAtomicWrites is a smoke test that the atomic
// getters return live counter values — future refactors can drift these
// out of sync trivially without noticing.
func TestCounterGettersReflectAtomicWrites(t *testing.T) {
	p := newTestPublisher()
	p.published.Add(3)
	p.confirmed.Add(2)
	p.nacked.Add(1)
	p.confirmTimeouts.Add(4)
	p.failed.Add(5)

	if got, want := p.PublishedCount(), uint64(3); got != want {
		t.Errorf("PublishedCount: got %d, want %d", got, want)
	}
	if got, want := p.ConfirmedCount(), uint64(2); got != want {
		t.Errorf("ConfirmedCount: got %d, want %d", got, want)
	}
	if got, want := p.NackedCount(), uint64(1); got != want {
		t.Errorf("NackedCount: got %d, want %d", got, want)
	}
	if got, want := p.ConfirmTimeoutCount(), uint64(4); got != want {
		t.Errorf("ConfirmTimeoutCount: got %d, want %d", got, want)
	}
	if got, want := p.FailedCount(), uint64(5); got != want {
		t.Errorf("FailedCount: got %d, want %d", got, want)
	}

	// Silence the atomic-import ambient hazard: this test WILL fail to
	// compile if atomic is somehow shadowed, but we don't otherwise use it
	// directly at the test level (we access counters through the atomic
	// fields inside Publisher above).
	_ = atomic.Uint64{}
}
