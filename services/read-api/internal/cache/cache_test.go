package cache

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

// fakeBackend is an in-memory backend with optional fault injection, so the
// cache-aside contract is tested WITHOUT a real Redis.
type fakeBackend struct {
	mu       sync.Mutex
	store    map[string][]byte
	getErr   error // if set, get() returns it (simulates Redis down/timeout)
	setErr   error // if set, set() returns it (simulates a write failure)
	gets     int
	sets     int
	setValue []byte // last value written
}

func newFake() *fakeBackend { return &fakeBackend{store: map[string][]byte{}} }

func (f *fakeBackend) get(_ context.Context, key string) ([]byte, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gets++
	if f.getErr != nil {
		return nil, false, f.getErr
	}
	v, ok := f.store[key]
	return v, ok, nil
}

func (f *fakeBackend) set(_ context.Context, key string, val []byte, _ time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sets++
	f.setValue = val
	if f.setErr != nil {
		return f.setErr
	}
	f.store[key] = val
	return nil
}

func (f *fakeBackend) ping(context.Context) error { return nil }
func (f *fakeBackend) close() error               { return nil }

// newTestCache returns an enabled cache wired to fb, with a fresh registry so
// each test's counters are independent. It builds a DISABLED cache first (so New
// never dials a real Redis / parses a URL) then flips it on and injects the fake
// backend — exercising the exact Enabled()/GetOrLoad logic with no I/O.
func newTestCache(t *testing.T, fb backend) *Cache {
	t.Helper()
	c, err := New(Config{Enabled: false}, prometheus.NewRegistry())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	c.enabled = true
	c.be = fb
	return c
}

func counter(t *testing.T, c *Cache, result string) float64 {
	t.Helper()
	m := &dto.Metric{}
	if err := c.reqs.WithLabelValues(result).Write(m); err != nil {
		t.Fatalf("counter read: %v", err)
	}
	return m.GetCounter().GetValue()
}

// ── Invariant #1: tenant-key isolation ───────────────────────────────────────

func TestDatasetKey_IncludesEnterprise(t *testing.T) {
	sql := `SELECT * FROM h_piot_oee_score_full_3($1,$2)`
	args := []any{7, "{1,2}"} // args[0] is a tenant id, but the SEGMENT is what fences

	k3 := DatasetKey(3, "f3", "oee-score-full", sql, args)
	k4 := DatasetKey(4, "f3", "oee-score-full", sql, args)

	// Same dataset, same sql, same args — ONLY the enterprise differs. The keys
	// MUST differ, or tenant 4 could read tenant 3's cached rows. This is the
	// single most important property in the package.
	if k3 == k4 {
		t.Fatalf("cross-tenant key collision: e3 and e4 produced the same key %q", k3)
	}
	// The enterprise must appear as a literal, greppable segment (not only inside
	// the opaque hash) so the fence holds even under a hash collision.
	if wantSub := ":e3:"; !contains(k3, wantSub) {
		t.Errorf("key %q missing explicit enterprise segment %q", k3, wantSub)
	}
	if wantSub := ":e4:"; !contains(k4, wantSub) {
		t.Errorf("key %q missing explicit enterprise segment %q", k4, wantSub)
	}
}

func TestDatasetKey_VariesByDatasetFlowAndArgs(t *testing.T) {
	base := DatasetKey(3, "f3", "oee-score-full", "SQL", []any{3, "{1}"})
	cases := map[string]string{
		"different dataset": DatasetKey(3, "f3", "oee-progress", "SQL", []any{3, "{1}"}),
		"different flow":    DatasetKey(3, "f1", "oee-score-full", "SQL", []any{3, "{1}"}),
		"different args":    DatasetKey(3, "f3", "oee-score-full", "SQL", []any{3, "{2}"}),
		"different sql":     DatasetKey(3, "f3", "oee-score-full", "SQL2", []any{3, "{1}"}),
	}
	for name, k := range cases {
		if k == base {
			t.Errorf("%s: key did not change (%q)", name, k)
		}
	}
	// Determinism: identical inputs ⇒ identical key.
	if again := DatasetKey(3, "f3", "oee-score-full", "SQL", []any{3, "{1}"}); again != base {
		t.Errorf("non-deterministic key: %q != %q", again, base)
	}
}

// ── Cache-aside hit / miss ───────────────────────────────────────────────────

func TestGetOrLoad_MissThenHit(t *testing.T) {
	fb := newFake()
	c := newTestCache(t, fb)
	ctx := context.Background()
	key := "refdata:ds:v1:f3:e3:oee:abc"

	loaderCalls := 0
	loader := func(context.Context) ([]byte, error) {
		loaderCalls++
		return []byte(`[{"oee":0.9}]`), nil
	}

	// First call: MISS ⇒ loader runs, result cached.
	got, err := c.GetOrLoad(ctx, key, 30*time.Second, loader)
	if err != nil || string(got) != `[{"oee":0.9}]` {
		t.Fatalf("miss: got %q err %v", got, err)
	}
	if loaderCalls != 1 {
		t.Fatalf("miss should run loader once, ran %d", loaderCalls)
	}
	if fb.sets != 1 {
		t.Fatalf("miss should write-through once, wrote %d", fb.sets)
	}

	// Second call: HIT ⇒ loader must NOT run.
	got, err = c.GetOrLoad(ctx, key, 30*time.Second, loader)
	if err != nil || string(got) != `[{"oee":0.9}]` {
		t.Fatalf("hit: got %q err %v", got, err)
	}
	if loaderCalls != 1 {
		t.Fatalf("hit must not re-run loader; loaderCalls=%d", loaderCalls)
	}
	if c := counter(t, c, "hit"); c != 1 {
		t.Errorf("hit counter = %v, want 1", c)
	}
	if c := counter(t, c, "miss"); c != 1 {
		t.Errorf("miss counter = %v, want 1", c)
	}
}

// ── Invariant #2: fail-open ──────────────────────────────────────────────────

func TestGetOrLoad_FailOpenOnGetError(t *testing.T) {
	fb := newFake()
	fb.getErr = errors.New("connection refused") // Redis is down
	c := newTestCache(t, fb)

	loaderCalls := 0
	got, err := c.GetOrLoad(context.Background(), "k", 30*time.Second, func(context.Context) ([]byte, error) {
		loaderCalls++
		return []byte(`[1,2,3]`), nil
	})
	// A cache read error must NEVER fail the request — it degrades to a DB read.
	if err != nil {
		t.Fatalf("get error must fail open, got err %v", err)
	}
	if string(got) != `[1,2,3]` || loaderCalls != 1 {
		t.Fatalf("fail-open should serve from loader: got %q calls %d", got, loaderCalls)
	}
	if c := counter(t, c, "error"); c != 1 {
		t.Errorf("error counter = %v, want 1", c)
	}
}

func TestGetOrLoad_FailOpenOnSetError(t *testing.T) {
	fb := newFake()
	fb.setErr = errors.New("OOM command not allowed") // write fails
	c := newTestCache(t, fb)

	got, err := c.GetOrLoad(context.Background(), "k", 30*time.Second, func(context.Context) ([]byte, error) {
		return []byte(`[]`), nil
	})
	// A write-through failure must not fail the read that already succeeded.
	if err != nil || string(got) != `[]` {
		t.Fatalf("set error must not fail the read: got %q err %v", got, err)
	}
}

func TestGetOrLoad_LoaderErrorPropagates(t *testing.T) {
	c := newTestCache(t, newFake())
	dbErr := errors.New("query failed")
	_, err := c.GetOrLoad(context.Background(), "k", 30*time.Second, func(context.Context) ([]byte, error) {
		return nil, dbErr
	})
	if !errors.Is(err, dbErr) {
		t.Fatalf("real DB error must propagate, got %v", err)
	}
}

// ── Invariant #3: bypass (ttl<=0 or disabled) ────────────────────────────────

func TestGetOrLoad_BypassOnZeroTTL(t *testing.T) {
	fb := newFake()
	c := newTestCache(t, fb)
	loaderCalls := 0
	_, _ = c.GetOrLoad(context.Background(), "k", 0, func(context.Context) ([]byte, error) {
		loaderCalls++
		return []byte(`[]`), nil
	})
	if fb.gets != 0 || fb.sets != 0 {
		t.Errorf("ttl=0 must bypass Redis entirely: gets=%d sets=%d", fb.gets, fb.sets)
	}
	if loaderCalls != 1 {
		t.Errorf("ttl=0 must still run the loader once, ran %d", loaderCalls)
	}
	if c := counter(t, c, "bypass"); c != 1 {
		t.Errorf("bypass counter = %v, want 1", c)
	}
}

func TestGetOrLoad_DisabledCacheBypasses(t *testing.T) {
	c, err := New(Config{Enabled: false}, prometheus.NewRegistry())
	if err != nil {
		t.Fatalf("New disabled: %v", err)
	}
	if c.Enabled() {
		t.Fatal("cache built with Enabled=false must report !Enabled()")
	}
	loaderCalls := 0
	got, err := c.GetOrLoad(context.Background(), "k", 30*time.Second, func(context.Context) ([]byte, error) {
		loaderCalls++
		return []byte(`[7]`), nil
	})
	if err != nil || string(got) != `[7]` || loaderCalls != 1 {
		t.Fatalf("disabled cache must pass through to loader: got %q err %v calls %d", got, err, loaderCalls)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
