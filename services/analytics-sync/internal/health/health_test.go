package health

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func status(t *testing.T, h http.HandlerFunc) int {
	t.Helper()
	rec := httptest.NewRecorder()
	h(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	return rec.Code
}

// A fresh heartbeat within maxAge is healthy; a stale one flips to 503 so the
// docker healthcheck can catch a wedged loop.
func TestChecker_StalenessFlips503(t *testing.T) {
	c := NewChecker("test", 100*time.Millisecond)

	if got := status(t, c.Handler()); got != http.StatusOK {
		t.Fatalf("fresh heartbeat: want 200, got %d", got)
	}

	// Age the heartbeat past maxAge without sleeping the test.
	c.lastBeat.Store(time.Now().Add(-time.Second).UnixNano())
	if got := status(t, c.Handler()); got != http.StatusServiceUnavailable {
		t.Fatalf("stale heartbeat: want 503, got %d", got)
	}

	// A subsequent beat recovers health.
	c.Beat()
	if got := status(t, c.Handler()); got != http.StatusOK {
		t.Fatalf("post-beat: want 200, got %d", got)
	}
}

// maxAge <= 0 disables the staleness check — behaves like the plain probe even
// with an ancient heartbeat (backward-compatible default for shadow-mirror).
func TestChecker_MaxAgeZeroAlwaysHealthy(t *testing.T) {
	c := NewChecker("test", 0)
	c.lastBeat.Store(time.Now().Add(-72 * time.Hour).UnixNano())
	if got := status(t, c.Handler()); got != http.StatusOK {
		t.Fatalf("maxAge=0: want 200, got %d", got)
	}
}
