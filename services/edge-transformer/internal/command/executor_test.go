package command

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// ── test doubles ─────────────────────────────────────────────────────────────

type mockDevice struct {
	mu        sync.Mutex
	published []struct {
		topic string
		body  []byte
	}
	err error // if set, PublishDCMD returns it
}

func (m *mockDevice) PublishDCMD(_ context.Context, topic string, body []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.err != nil {
		return m.err
	}
	m.published = append(m.published, struct {
		topic string
		body  []byte
	}{topic, body})
	return nil
}

func (m *mockDevice) count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.published)
}

type mockAcks struct {
	mu   sync.Mutex
	acks []Ack
	keys []string
}

func (m *mockAcks) PublishAck(_ context.Context, routingKey string, body []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	var a Ack
	_ = json.Unmarshal(body, &a)
	m.acks = append(m.acks, a)
	m.keys = append(m.keys, routingKey)
	return nil
}

func (m *mockAcks) last() Ack {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.acks) == 0 {
		return Ack{}
	}
	return m.acks[len(m.acks)-1]
}

func newTestExecutor(device DevicePublisher, acks AckPublisher) *Executor {
	return NewExecutor(Config{
		Allowed:  []string{VerbParamWrite, VerbPOSetup},
		Exchange: "edge.commands",
		EdgeNode: "plc-sim",
		DedupCap: 128,
	}, device, acks, Metrics{}, nil)
}

func mustJSON(t *testing.T, c Command) []byte {
	t.Helper()
	b, err := json.Marshal(c)
	if err != nil {
		t.Fatalf("marshal command: %v", err)
	}
	return b
}

// decodeDCMD pulls the single metric name + value out of an encoded DCMD body.
func decodeDCMD(t *testing.T, body []byte) *sparkplug.Metric {
	t.Helper()
	p, err := sparkplug.Decode(body)
	if err != nil {
		t.Fatalf("decode DCMD: %v", err)
	}
	if len(p.GetMetrics()) != 1 {
		t.Fatalf("want 1 metric, got %d", len(p.GetMetrics()))
	}
	return p.GetMetrics()[0]
}

// ── tests ────────────────────────────────────────────────────────────────────

// Allow-listed param_write translates to a DCMD published on the correct topic
// with the correct metric name + value, and acks delivered.
func TestExecute_ParamWrite_Delivered(t *testing.T) {
	dev := &mockDevice{}
	acks := &mockAcks{}
	e := newTestExecutor(dev, acks)

	body := mustJSON(t, Command{
		Tenant:         "cpack",
		IDEquipment:    53,
		PackmlTopic:    "CPACK/SC/LINHAS/L5/BREYER",
		Verb:           VerbParamWrite,
		Params:         map[string]any{"parameter": "Status/MachSpeed", "value": 137.0},
		IdempotencyKey: "k-1",
	})

	res, err := e.Execute(context.Background(), body)
	if err != nil {
		t.Fatalf("unexpected transient error: %v", err)
	}
	if res.Outcome != OutcomeDelivered {
		t.Fatalf("want delivered, got %s (%s)", res.Outcome, res.Reason)
	}
	if dev.count() != 1 {
		t.Fatalf("want 1 DCMD published, got %d", dev.count())
	}
	if got, want := dev.published[0].topic, "spBv1.0/CPACK/DCMD/plc-sim"; got != want {
		t.Fatalf("DCMD topic = %q, want %q", got, want)
	}
	m := decodeDCMD(t, dev.published[0].body)
	if got, want := m.GetName(), "CPACK/SC/LINHAS/L5/BREYER/Status/MachSpeed"; got != want {
		t.Fatalf("DCMD metric name = %q, want %q", got, want)
	}
	if got := m.GetDoubleValue(); got != 137.0 {
		t.Fatalf("DCMD value = %v, want 137", got)
	}
	if a := acks.last(); a.Status != string(OutcomeDelivered) || a.IdempotencyKey != "k-1" {
		t.Fatalf("ack = %+v, want delivered/k-1", a)
	}
	if rk := acks.keys[len(acks.keys)-1]; rk != "edge.commands.cpack.ack" {
		t.Fatalf("ack routing key = %q, want edge.commands.cpack.ack", rk)
	}
}

// po_setup writes Parameter30700 as a string value.
func TestExecute_POSetup_Delivered(t *testing.T) {
	dev := &mockDevice{}
	e := newTestExecutor(dev, &mockAcks{})

	body := mustJSON(t, Command{
		Tenant:         "cpack",
		PackmlTopic:    "CPACK/SC/LINHAS/L8",
		Verb:           VerbPOSetup,
		Params:         map[string]any{"poNumber": 4210},
		IdempotencyKey: "k-po",
	})
	res, err := e.Execute(context.Background(), body)
	if err != nil || res.Outcome != OutcomeDelivered {
		t.Fatalf("want delivered, got %s / err=%v", res.Outcome, err)
	}
	m := decodeDCMD(t, dev.published[0].body)
	if got, want := m.GetName(), "CPACK/SC/LINHAS/L8/Status/Parameter30700"; got != want {
		t.Fatalf("metric name = %q, want %q", got, want)
	}
	if got := m.GetStringValue(); got != "4210" {
		t.Fatalf("PO value = %q, want \"4210\"", got)
	}
}

// SAFETY: an unknown (non-allow-listed) verb is REJECTED — no DCMD, ack rejected.
func TestExecute_UnknownVerb_Rejected(t *testing.T) {
	dev := &mockDevice{}
	acks := &mockAcks{}
	e := newTestExecutor(dev, acks)

	body := mustJSON(t, Command{
		Tenant:         "cpack",
		PackmlTopic:    "CPACK/SC/LINHAS/L8",
		Verb:           "write_any_register", // not allow-listed
		Params:         map[string]any{"value": 1},
		IdempotencyKey: "k-evil",
	})
	res, err := e.Execute(context.Background(), body)
	if err != nil {
		t.Fatalf("unexpected transient error: %v", err)
	}
	if res.Outcome != OutcomeRejected {
		t.Fatalf("want rejected, got %s", res.Outcome)
	}
	if dev.count() != 0 {
		t.Fatalf("SAFETY VIOLATION: DCMD published for unknown verb (%d)", dev.count())
	}
	if a := acks.last(); a.Status != string(OutcomeRejected) {
		t.Fatalf("want ack rejected, got %+v", a)
	}
}

// SAFETY: a verb allow-listed at the config level but allowed=false in a
// narrowed allow-list is refused (allow-list is authoritative, not the verb set).
func TestExecute_VerbNotInNarrowedAllowList_Rejected(t *testing.T) {
	dev := &mockDevice{}
	e := NewExecutor(Config{
		Allowed:  []string{VerbPOSetup}, // param_write intentionally excluded
		Exchange: "edge.commands",
		EdgeNode: "plc-sim",
	}, dev, &mockAcks{}, Metrics{}, nil)

	body := mustJSON(t, Command{
		Tenant: "cpack", PackmlTopic: "CPACK/X", Verb: VerbParamWrite,
		Params: map[string]any{"parameter": "Status/MachSpeed", "value": 1.0}, IdempotencyKey: "k",
	})
	res, _ := e.Execute(context.Background(), body)
	if res.Outcome != OutcomeRejected || dev.count() != 0 {
		t.Fatalf("param_write should be rejected when not allow-listed: outcome=%s count=%d", res.Outcome, dev.count())
	}
}

// SAFETY (fail-safe): param_write with missing/incomplete params is REJECTED —
// never a partial or guessed write.
func TestExecute_ParamWrite_MissingParams_Rejected(t *testing.T) {
	cases := []struct {
		name   string
		params map[string]any
	}{
		{"no parameter", map[string]any{"value": 1.0}},
		{"no value", map[string]any{"parameter": "Status/MachSpeed"}},
		{"non-numeric value", map[string]any{"parameter": "Status/MachSpeed", "value": "fast"}},
		{"empty params", map[string]any{}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dev := &mockDevice{}
			e := newTestExecutor(dev, &mockAcks{})
			body := mustJSON(t, Command{
				Tenant: "cpack", PackmlTopic: "CPACK/SC/LINHAS/L8",
				Verb: VerbParamWrite, Params: tc.params, IdempotencyKey: "k",
			})
			res, err := e.Execute(context.Background(), body)
			if err != nil {
				t.Fatalf("unexpected transient err: %v", err)
			}
			if res.Outcome != OutcomeRejected {
				t.Fatalf("want rejected, got %s", res.Outcome)
			}
			if dev.count() != 0 {
				t.Fatalf("SAFETY VIOLATION: partial write emitted for %q", tc.name)
			}
		})
	}
}

// SAFETY (fail-safe): a bad/empty packmlTopic is rejected — we cannot derive the
// DCMD topic, so we must not guess.
func TestExecute_BadTopic_Rejected(t *testing.T) {
	dev := &mockDevice{}
	e := newTestExecutor(dev, &mockAcks{})
	body := mustJSON(t, Command{
		Tenant: "cpack", PackmlTopic: "", Verb: VerbParamWrite,
		Params: map[string]any{"parameter": "Status/MachSpeed", "value": 1.0}, IdempotencyKey: "k",
	})
	res, _ := e.Execute(context.Background(), body)
	if res.Outcome != OutcomeRejected || dev.count() != 0 {
		t.Fatalf("empty topic should reject: outcome=%s count=%d", res.Outcome, dev.count())
	}
}

// SAFETY: a command with no idempotencyKey is rejected — a write must be
// idempotent, so the absence of a dedup key is itself unsafe.
func TestExecute_MissingIdempotencyKey_Rejected(t *testing.T) {
	dev := &mockDevice{}
	e := newTestExecutor(dev, &mockAcks{})
	body := mustJSON(t, Command{
		Tenant: "cpack", PackmlTopic: "CPACK/X", Verb: VerbParamWrite,
		Params: map[string]any{"parameter": "Status/MachSpeed", "value": 1.0},
	})
	res, _ := e.Execute(context.Background(), body)
	if res.Outcome != OutcomeRejected || dev.count() != 0 {
		t.Fatalf("missing idempotencyKey should reject: outcome=%s count=%d", res.Outcome, dev.count())
	}
}

// IDEMPOTENT: re-delivery of the same idempotencyKey does NOT re-issue the DCMD.
func TestExecute_Idempotent_NoDoubleWrite(t *testing.T) {
	dev := &mockDevice{}
	acks := &mockAcks{}
	e := newTestExecutor(dev, acks)

	body := mustJSON(t, Command{
		Tenant: "cpack", PackmlTopic: "CPACK/SC/LINHAS/L8", Verb: VerbParamWrite,
		Params: map[string]any{"parameter": "Status/MachSpeed", "value": 90.0}, IdempotencyKey: "dup-key",
	})

	res1, _ := e.Execute(context.Background(), body)
	res2, _ := e.Execute(context.Background(), body) // redelivery

	if res1.Outcome != OutcomeDelivered || res2.Outcome != OutcomeDelivered {
		t.Fatalf("both should be delivered: %s / %s", res1.Outcome, res2.Outcome)
	}
	if res1.Duplicate {
		t.Fatalf("first delivery must not be flagged duplicate")
	}
	if !res2.Duplicate {
		t.Fatalf("second delivery must be flagged duplicate")
	}
	if dev.count() != 1 {
		t.Fatalf("IDEMPOTENCY VIOLATION: DCMD issued %d times, want 1", dev.count())
	}
}

// A transient DCMD publish failure returns an error (→ consumer retries) and
// does NOT mark the key seen, so a subsequent redelivery re-issues the write.
func TestExecute_TransientPublishFailure_RetriesThenSucceeds(t *testing.T) {
	dev := &mockDevice{err: errors.New("broker down")}
	e := newTestExecutor(dev, &mockAcks{})
	body := mustJSON(t, Command{
		Tenant: "cpack", PackmlTopic: "CPACK/X", Verb: VerbParamWrite,
		Params: map[string]any{"parameter": "Status/MachSpeed", "value": 5.0}, IdempotencyKey: "retry-key",
	})

	if _, err := e.Execute(context.Background(), body); err == nil {
		t.Fatalf("want transient error on publish failure")
	}
	// Broker recovers — the same key must now re-issue (not be deduped away).
	dev.err = nil
	res, err := e.Execute(context.Background(), body)
	if err != nil || res.Outcome != OutcomeDelivered || res.Duplicate {
		t.Fatalf("recovery should deliver fresh: outcome=%s dup=%v err=%v", res.Outcome, res.Duplicate, err)
	}
	if dev.count() != 1 {
		t.Fatalf("want exactly 1 successful publish after recovery, got %d", dev.count())
	}
}

// A malformed envelope is rejected without touching the device.
func TestExecute_MalformedEnvelope_Rejected(t *testing.T) {
	dev := &mockDevice{}
	e := newTestExecutor(dev, &mockAcks{})
	res, err := e.Execute(context.Background(), []byte("{not json"))
	if err != nil {
		t.Fatalf("unexpected transient err: %v", err)
	}
	if res.Outcome != OutcomeRejected || dev.count() != 0 {
		t.Fatalf("malformed body should reject: outcome=%s count=%d", res.Outcome, dev.count())
	}
}
