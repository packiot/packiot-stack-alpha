package uplink

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"path/filepath"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/aliasmap"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/outbox"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// fakeResolver maps any suffix to a Double metric — enough to build an NBIRTH.
type fakeResolver struct{}

func (fakeResolver) Resolve(s string) (string, sparkplug.DataType, bool) {
	return "CPACK/L5" + s, sparkplug.DataType_Double, true
}

func quietLogger() *slog.Logger {
	return slog.New(slog.NewJSONHandler(io.Discard, nil))
}

func newTestUplink(t *testing.T) (*Uplink, *outbox.Store) {
	t.Helper()
	store, err := outbox.Open(outbox.Config{Path: filepath.Join(t.TempDir(), "outbox.db")})
	if err != nil {
		t.Fatalf("outbox open: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	pub := session.New(fakeResolver{}, aliasmap.New())
	pub.NewConnection()
	snapshot := func() []rawtag.RawTag {
		return []rawtag.RawTag{{Metric: "/Speed", Value: 1.0, Quality: true, TsMillis: 1}}
	}
	u := New(Config{GroupID: "CPACK", EdgeNodeID: "node"}, pub, store, snapshot, quietLogger())
	return u, store
}

// TestRebirthThenDrain proves the load-bearing ADR-0042 §2.5 ordering: on
// reconnect the agent republishes NBIRTH (re-establishing the alias table)
// BEFORE draining buffered NDATA whose alias references the cloud would
// otherwise be unable to resolve.
func TestRebirthThenDrain(t *testing.T) {
	u, store := newTestUplink(t)
	ctx := context.Background()

	// Pre-seed a buffered NDATA (as if published during an outage).
	if _, err := store.Enqueue(ctx, outbox.Message{
		Tenant: "CPACK", Topic: u.DataTopic(), Payload: []byte("buffered-ndata"),
	}); err != nil {
		t.Fatalf("seed outbox: %v", err)
	}

	var order []string
	rec := func(topic string, qos byte, retained bool, body []byte) error {
		order = append(order, topic)
		return nil
	}
	if err := u.rebirthThenDrain(ctx, rec); err != nil {
		t.Fatalf("rebirthThenDrain: %v", err)
	}

	if len(order) != 2 {
		t.Fatalf("published %d messages, want 2 (NBIRTH + buffered NDATA): %v", len(order), order)
	}
	if order[0] != u.birthTopic {
		t.Fatalf("first publish must be NBIRTH (%s), got %s — rebirth MUST precede drain", u.birthTopic, order[0])
	}
	if order[1] != u.DataTopic() {
		t.Fatalf("second publish must be the buffered NDATA (%s), got %s", u.DataTopic(), order[1])
	}
	// Successfully drained rows are deleted.
	if depth, _ := store.Depth(ctx); depth != 0 {
		t.Fatalf("outbox depth after drain: got %d, want 0", depth)
	}
}

// TestDrainRetainsOnPublishFailure proves store-and-forward integrity: a
// publish failure leaves the row in the outbox (marked for retry), never
// dropped.
func TestDrainRetainsOnPublishFailure(t *testing.T) {
	u, store := newTestUplink(t)
	ctx := context.Background()
	if _, err := store.Enqueue(ctx, outbox.Message{Tenant: "CPACK", Topic: u.DataTopic(), Payload: []byte("x")}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	failing := func(topic string, qos byte, retained bool, body []byte) error {
		return errors.New("broker down")
	}
	if err := u.drain(ctx, failing); err == nil {
		t.Fatal("drain should surface the publish error")
	}
	if depth, _ := store.Depth(ctx); depth != 1 {
		t.Fatalf("failed publish must retain the row: depth=%d, want 1", depth)
	}
}
