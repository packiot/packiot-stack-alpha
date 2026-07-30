package refdataresolver_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/birthbind"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/refdataresolver"
)

// Compile-time proof the resolver satisfies the birthbind seam — the whole point
// of #19a is that it drops in behind DeviceResolver with no interface change.
var _ birthbind.DeviceResolver = (*refdataresolver.Resolver)(nil)

// fakeRefdata is a stand-in for refdata-api's /internal/resolve-device: it
// enforces the key, echoes the enterprise/device_key it saw, and serves a small
// fixed map. hits counts how many times it was actually called (to prove the
// cache).
type fakeRefdata struct {
	key   string
	table map[string]int // device_key → id_equipment
	hits  atomic.Int64
}

func (f *fakeRefdata) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		f.hits.Add(1)
		if r.Header.Get("X-Internal-Key") != f.key {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		if r.URL.Query().Get("enterprise") == "" || r.URL.Query().Get("device_key") == "" {
			http.Error(w, `{"error":"bad request"}`, http.StatusBadRequest)
			return
		}
		id, ok := f.table[r.URL.Query().Get("device_key")]
		if !ok {
			http.Error(w, `{"error":"not mapped"}`, http.StatusNotFound)
			return
		}
		fmt.Fprintf(w, `{"id_equipment":%d}`, id)
	}
}

func newFake(t *testing.T, key string, table map[string]int) (*fakeRefdata, *httptest.Server) {
	t.Helper()
	f := &fakeRefdata{key: key, table: table}
	srv := httptest.NewServer(f.handler())
	t.Cleanup(srv.Close)
	return f, srv
}

// TestResolveHit — a mapped key resolves, and a second call is served from the
// positive cache (no extra HTTP hit).
func TestResolveHit(t *testing.T) {
	f, srv := newFake(t, "k", map[string]int{"CPACK-SC-LINHAS-L5": 40004})
	r := refdataresolver.New(refdataresolver.Config{
		BaseURL: srv.URL, EnterpriseID: 1, InternalKey: "k",
		PositiveTTL: time.Minute, NegativeTTL: time.Minute,
	})

	id, ok := r.Resolve("CPACK-SC-LINHAS-L5")
	if !ok || id != 40004 {
		t.Fatalf("Resolve = (%d, %v), want (40004, true)", id, ok)
	}
	if _, ok := r.Resolve("CPACK-SC-LINHAS-L5"); !ok {
		t.Fatalf("second Resolve should still hit")
	}
	if got := f.hits.Load(); got != 1 {
		t.Errorf("upstream hits = %d, want 1 (second lookup must be cached)", got)
	}
}

// TestResolveMissFailClosed — an unmapped key returns ok=false (404 →
// fail-closed) and is negative-cached (no second HTTP hit within negTTL).
func TestResolveMissFailClosed(t *testing.T) {
	f, srv := newFake(t, "k", map[string]int{})
	r := refdataresolver.New(refdataresolver.Config{
		BaseURL: srv.URL, EnterpriseID: 1, InternalKey: "k",
		PositiveTTL: time.Minute, NegativeTTL: time.Minute,
	})

	if id, ok := r.Resolve("UNKNOWN"); ok || id != 0 {
		t.Fatalf("Resolve = (%d, %v), want (0, false)", id, ok)
	}
	_, _ = r.Resolve("UNKNOWN")
	if got := f.hits.Load(); got != 1 {
		t.Errorf("upstream hits = %d, want 1 (miss must be negative-cached)", got)
	}
}

// TestResolveNegativeCacheExpires — a miss re-queries after the negative TTL, so
// a freshly-registered device is eventually picked up.
func TestResolveNegativeCacheExpires(t *testing.T) {
	f, srv := newFake(t, "k", map[string]int{})
	r := refdataresolver.New(refdataresolver.Config{
		BaseURL: srv.URL, EnterpriseID: 1, InternalKey: "k",
		PositiveTTL: time.Minute, NegativeTTL: 10 * time.Millisecond,
	})
	_, _ = r.Resolve("LATER")
	time.Sleep(25 * time.Millisecond)
	_, _ = r.Resolve("LATER")
	if got := f.hits.Load(); got != 2 {
		t.Errorf("upstream hits = %d, want 2 (negative cache should have expired)", got)
	}
}

// TestResolveWrongKeyFailClosed — a bad internal key 401s upstream and the
// resolver fails closed.
func TestResolveWrongKeyFailClosed(t *testing.T) {
	_, srv := newFake(t, "right", map[string]int{"D": 7})
	r := refdataresolver.New(refdataresolver.Config{
		BaseURL: srv.URL, EnterpriseID: 1, InternalKey: "wrong",
		PositiveTTL: time.Minute, NegativeTTL: time.Minute,
	})
	if _, ok := r.Resolve("D"); ok {
		t.Errorf("Resolve must fail closed on 401")
	}
}

// TestResolveTransportErrorFailClosed — an unreachable refdata fails closed
// rather than panicking or blocking the birth path.
func TestResolveTransportErrorFailClosed(t *testing.T) {
	r := refdataresolver.New(refdataresolver.Config{
		BaseURL: "http://127.0.0.1:1", EnterpriseID: 1, InternalKey: "k",
		HTTPTimeout: 200 * time.Millisecond,
		PositiveTTL: time.Minute, NegativeTTL: time.Minute,
	})
	if _, ok := r.Resolve("D"); ok {
		t.Errorf("Resolve must fail closed when refdata is unreachable")
	}
}

// TestResolveEmptyKey — the empty device_key never hits the network.
func TestResolveEmptyKey(t *testing.T) {
	f, srv := newFake(t, "k", map[string]int{})
	r := refdataresolver.New(refdataresolver.Config{BaseURL: srv.URL, EnterpriseID: 1, InternalKey: "k"})
	if _, ok := r.Resolve(""); ok {
		t.Errorf("empty device_key must not resolve")
	}
	if got := f.hits.Load(); got != 0 {
		t.Errorf("empty key must not hit upstream, got %d hits", got)
	}
}
