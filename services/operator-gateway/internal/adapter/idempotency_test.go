package adapter

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// These tests drive Server.forward with the mapped edge-api call directly (the
// resolve + mapping steps in front of it are covered by server_test.go and
// po_lifecycle_test.go).

func createDowntimeCall(tsEnd string) *edgeCall {
	return &edgeCall{path: "/api/downtimes/create-manual-event", idEnterprise: testEntID, body: edgeCreateDowntime{
		CDCategory: "C", DescCategory: "D", CDMachine: resCDMachine, IDEnterprise: testEntID,
		IDEquipment: resEquipment, TSEvent: "2026-07-08T10:00:00Z", TSEnd: tsEnd,
	}}
}

func changeStatusCall() *edgeCall {
	return &edgeCall{path: "/api/production-orders/change-status", idEnterprise: testEntID,
		body: edgeChangeStatusPO{IDProductionOrder: 90055, IDEquipment: resEquipment}}
}

// forwardCall runs srv.forward for call with the given extra request headers.
func forwardCall(t *testing.T, srv *Server, call *edgeCall, hdr map[string][]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/operator/x", nil)
	for k, vs := range hdr {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	rec := httptest.NewRecorder()
	srv.forward(rec, req, "test", call)
	return rec
}

func okPoster() *fakePoster {
	return &fakePoster{result: &edgeResult{statusCode: 201, body: []byte(`{}`)}}
}

// A time-anchored create gets a derived key: stable for the same body, different
// for a different event.
func TestIdempotency_DerivedKeyForCreate(t *testing.T) {
	fp := okPoster()
	srv, _, _ := newTestServer(t, fp)

	if rec := forwardCall(t, srv, createDowntimeCall("2026-07-08T11:00:00Z"), nil); rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	first := fp.last.idempotencyKey
	if !strings.HasPrefix(first, "opgw-") || len(first) != len("opgw-")+64 {
		t.Fatalf("derived key has the wrong shape: %q", first)
	}

	forwardCall(t, srv, createDowntimeCall("2026-07-08T11:00:00Z"), nil)
	if fp.last.idempotencyKey != first {
		t.Fatalf("same body must give the same key: %q vs %q", fp.last.idempotencyKey, first)
	}

	forwardCall(t, srv, createDowntimeCall("2026-07-08T11:05:00Z"), nil)
	if fp.last.idempotencyKey == first {
		t.Fatal("a different event must give a different key")
	}
}

// Every time-anchored path gets a derived key; the repeatable ones do not.
func TestIdempotency_DerivedKeyOnlyForTimeAnchoredPaths(t *testing.T) {
	cases := []struct {
		path    string
		wantKey bool
	}{
		{"/api/downtimes/create-manual-event", true},
		{"/api/production-orders/create-and-start", true},
		{"/api/production-orders/stop", true},
		{"/api/production-orders/setup", true},
		// Repeatable with an identical body (A→B→A): a derived key would skip the write.
		{"/api/downtimes/edit-manual-event", false},
		{"/api/production-orders/change-status", false},
		{"/api/production-orders/replace", false},
		{"/api/production-orders/change-time", false},
		{"/api/downtimes/split", false},
	}
	for _, c := range cases {
		fp := okPoster()
		srv, _, _ := newTestServer(t, fp)
		call := &edgeCall{path: c.path, idEnterprise: testEntID, body: map[string]string{"timestamp": "2026-07-08 10:00:00"}}
		if rec := forwardCall(t, srv, call, nil); rec.Code != http.StatusAccepted {
			t.Fatalf("%s: want 202, got %d (%s)", c.path, rec.Code, rec.Body.String())
		}
		if got := fp.last.idempotencyKey != ""; got != c.wantKey {
			t.Fatalf("%s: key present = %v, want %v", c.path, got, c.wantKey)
		}
	}
}

// A caller key is used for any action, namespaced per tenant + endpoint.
func TestIdempotency_ClientKeyForwardedHashed(t *testing.T) {
	fp := okPoster()
	srv, _, _ := newTestServer(t, fp)
	hdr := map[string][]string{"Idempotency-Key": {"tablet-7-action-42"}}

	if rec := forwardCall(t, srv, changeStatusCall(), hdr); rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d", rec.Code)
	}
	statusKey := fp.last.idempotencyKey
	if !strings.HasPrefix(statusKey, "opgw-") || strings.Contains(statusKey, "tablet") {
		t.Fatalf("client key must be forwarded hashed and namespaced, got %q", statusKey)
	}

	// The caller key wins over the derived one on a create.
	forwardCall(t, srv, createDowntimeCall("2026-07-08T11:00:00Z"), nil)
	derived := fp.last.idempotencyKey
	forwardCall(t, srv, createDowntimeCall("2026-07-08T11:00:00Z"), hdr)
	if fp.last.idempotencyKey == statusKey {
		t.Fatal("the same client key on a different endpoint must not collide")
	}
	if fp.last.idempotencyKey == derived {
		t.Fatal("client key must take precedence over the derived key")
	}

	// Same client key + same endpoint ⇒ same forwarded key (the retry case).
	forwardCall(t, srv, changeStatusCall(), hdr)
	if fp.last.idempotencyKey != statusKey {
		t.Fatal("a retry with the same client key must forward the same key")
	}
}

func TestIdempotency_BadClientKeyIs400(t *testing.T) {
	for name, vals := range map[string][]string{
		"space":     {"has space"},
		"too long":  {strings.Repeat("k", maxClientIdempotencyKeyLen+1)},
		"non-ascii": {"chave-ç"},
		"repeated":  {"a", "b"},
	} {
		fp := okPoster()
		srv, _, _ := newTestServer(t, fp)
		rec := forwardCall(t, srv, createDowntimeCall("2026-07-08T11:00:00Z"), map[string][]string{"Idempotency-Key": vals})
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: want 400, got %d", name, rec.Code)
		}
		if fp.last != nil {
			t.Fatalf("%s: nothing may be sent to edge-api", name)
		}
	}
}

func TestIdempotency_KeyBoundToTenant(t *testing.T) {
	a := hashKey(4, "/api/production-orders/stop", "body", []byte(`{}`))
	b := hashKey(5, "/api/production-orders/stop", "body", []byte(`{}`))
	if a == b {
		t.Fatal("different tenants must never share a key")
	}
}

// keyStorePoster models edge-api's IdempotencyInterceptor: a key whose write
// succeeded is answered from the store without running the write again. The
// first call commits and then "times out", the bug scenario.
type keyStorePoster struct {
	mu        sync.Mutex
	commits   int
	stored    map[string]bool
	failFirst bool
}

func (k *keyStorePoster) post(_ context.Context, call *edgeCall) (*edgeResult, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if call.idempotencyKey != "" && k.stored[call.idempotencyKey] {
		return &edgeResult{statusCode: 201, body: []byte(`null`)}, nil
	}
	k.commits++
	if call.idempotencyKey != "" {
		k.stored[call.idempotencyKey] = true
	}
	if k.failFirst {
		k.failFirst = false
		return nil, errors.New("context deadline exceeded (Client.Timeout exceeded while awaiting headers)")
	}
	return &edgeResult{statusCode: 201, body: []byte(`{}`)}, nil
}

func TestIdempotency_RetryAfterTimeoutDoesNotDuplicate(t *testing.T) {
	ks := &keyStorePoster{stored: map[string]bool{}, failFirst: true}
	srv, _, _ := newTestServer(t, ks)

	if rec := forwardCall(t, srv, createDowntimeCall("2026-07-08T11:00:00Z"), nil); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("first attempt: want 503, got %d", rec.Code)
	}
	if rec := forwardCall(t, srv, createDowntimeCall("2026-07-08T11:00:00Z"), nil); rec.Code != http.StatusAccepted {
		t.Fatalf("retry: want 202, got %d", rec.Code)
	}
	if ks.commits != 1 {
		t.Fatalf("the downtime was written %d times, want 1", ks.commits)
	}
}

func TestEdgeClient_SendsIdempotencyKeyHeader(t *testing.T) {
	var got []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.Header.Get(idempotencyHeader))
		w.WriteHeader(http.StatusCreated)
	}))
	defer ts.Close()
	c := NewEdgeClient(ts.URL, "k", 2*time.Second)

	for _, key := range []string{"opgw-abc", ""} {
		if _, err := c.post(context.Background(), &edgeCall{path: "/api/x", idEnterprise: 4, body: map[string]int{}, idempotencyKey: key}); err != nil {
			t.Fatalf("post: %v", err)
		}
	}
	if len(got) != 2 || got[0] != "opgw-abc" || got[1] != "" {
		t.Fatalf("Idempotency-Key headers sent = %q, want [opgw-abc \"\"]", got)
	}
}
