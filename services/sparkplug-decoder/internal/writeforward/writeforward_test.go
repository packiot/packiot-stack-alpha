package writeforward

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/outbox"
)

func newStore(t *testing.T) *outbox.Store {
	t.Helper()
	st, err := outbox.Open(outbox.Config{
		Path:     filepath.Join(t.TempDir(), "wf.db"),
		Capacity: 1000,
	})
	if err != nil {
		t.Fatalf("outbox.Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func newForwarder(t *testing.T, cloudBase string, st *outbox.Store) *Forwarder {
	return &Forwarder{
		CloudBase:  cloudBase,
		Tenant:     "bispharmastaging",
		Store:      st,
		Client:     &http.Client{Timeout: 2 * time.Second},
		MaxBackoff: 10 * time.Millisecond, // tiny so the drain retry test doesn't wait seconds
	}
}

func depth(t *testing.T, f *Forwarder) int {
	t.Helper()
	d, err := f.Depth(context.Background())
	if err != nil {
		t.Fatalf("Depth: %v", err)
	}
	return d
}

// ONLINE: a 2xx is returned verbatim and NOTHING is queued.
func TestHandle_online_passthrough(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"id_production_order":42}`))
	}))
	defer srv.Close()

	f := newForwarder(t, srv.URL, newStore(t))
	res, err := f.Handle(context.Background(), "POST", "/api/production-orders/start", nil, []byte(`{}`))
	if err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if res.Status != http.StatusOK || res.Queued {
		t.Fatalf("want 200 not-queued, got status=%d queued=%v", res.Status, res.Queued)
	}
	if string(res.Body) != `{"id_production_order":42}` {
		t.Fatalf("body not passed through verbatim: %s", res.Body)
	}
	if d := depth(t, f); d != 0 {
		t.Fatalf("nothing should be queued on a 200, depth=%d", d)
	}
}

// ONLINE: a real 4xx (e.g. a stale-state 409) is an ANSWER, not an outage —
// returned verbatim, never queued.
func TestHandle_real4xx_not_queued(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"error":"stale PO"}`))
	}))
	defer srv.Close()

	f := newForwarder(t, srv.URL, newStore(t))
	res, err := f.Handle(context.Background(), "POST", "/api/downtimes/justify", nil, []byte(`{}`))
	if err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if res.Status != http.StatusConflict || res.Queued {
		t.Fatalf("want 409 not-queued, got status=%d queued=%v", res.Status, res.Queued)
	}
	if d := depth(t, f); d != 0 {
		t.Fatalf("a 409 is an answer, not an outage — depth=%d", d)
	}
}

// OUTAGE (transport error): cloud unreachable → 202 queued, write durably buffered.
func TestHandle_outage_transport_queues(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	dead := srv.URL
	srv.Close() // now unreachable → Client.Do returns a transport error

	f := newForwarder(t, dead, newStore(t))
	res, err := f.Handle(context.Background(), "POST", "/api/production-orders/start", nil, []byte(`{"idOrder":"X"}`))
	if err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if res.Status != http.StatusAccepted || !res.Queued {
		t.Fatalf("want 202 queued, got status=%d queued=%v", res.Status, res.Queued)
	}
	if d := depth(t, f); d != 1 {
		t.Fatalf("the write must be buffered, depth=%d", d)
	}
}

// OUTAGE (gateway 503): a 502/503/504 is treated as unreachable → queued.
func TestHandle_outage_gateway_queues(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()

	f := newForwarder(t, srv.URL, newStore(t))
	res, _ := f.Handle(context.Background(), "POST", "/api/downtimes/split", nil, []byte(`{}`))
	if res.Status != http.StatusAccepted || !res.Queued {
		t.Fatalf("a 503 is an outage → want 202 queued, got status=%d queued=%v", res.Status, res.Queued)
	}
	if d := depth(t, f); d != 1 {
		t.Fatalf("depth=%d", d)
	}
}

// The full outage→reconnect cycle: buffer while down, then DrainOnce replays to
// the cloud (in order) and clears the queue — preserving the Idempotency-Key so
// the cloud can dedup.
func TestDrainOnce_replays_and_preserves_idempotency(t *testing.T) {
	var up atomic.Bool
	var gotKey atomic.Value // string
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !up.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		hits.Add(1)
		gotKey.Store(r.Header.Get("Idempotency-Key"))
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	f := newForwarder(t, srv.URL, newStore(t))
	ctx := context.Background()

	// Down: the write buffers.
	hdr := map[string]string{"Idempotency-Key": "op-abc-123", "Content-Type": "application/json"}
	res, _ := f.Handle(ctx, "POST", "/api/production-orders/start", hdr, []byte(`{"idOrder":"X"}`))
	if !res.Queued || depth(t, f) != 1 {
		t.Fatalf("write should be queued while down (queued=%v depth=%d)", res.Queued, depth(t, f))
	}

	// Still down: DrainOnce leaves it queued (backoff), never drops it.
	if n, _ := f.DrainOnce(ctx, 10); n != 0 || depth(t, f) != 1 {
		t.Fatalf("must not drop a write while still down (drained=%d depth=%d)", n, depth(t, f))
	}

	// Reconnect: DrainOnce replays and clears the queue. Wait past the (tiny,
	// test-only) backoff the still-down attempt above scheduled, so the row is
	// visible to Peek again.
	time.Sleep(25 * time.Millisecond)
	up.Store(true)
	n, err := f.DrainOnce(ctx, 10)
	if err != nil {
		t.Fatalf("DrainOnce: %v", err)
	}
	if n != 1 || depth(t, f) != 0 {
		t.Fatalf("want drained=1 depth=0, got drained=%d depth=%d", n, depth(t, f))
	}
	if hits.Load() != 1 {
		t.Fatalf("cloud should have received exactly one replay, got %d", hits.Load())
	}
	if k, _ := gotKey.Load().(string); k != "op-abc-123" {
		t.Fatalf("Idempotency-Key not preserved on replay, got %q", k)
	}
}
