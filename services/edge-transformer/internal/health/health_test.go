// Unit tests for the health package — specifically the ADR-0011 P0-4
// aggregation logic. HTTP-server-level tests use httptest.

package health

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// fakeComponent is a tiny ComponentSnapshotter for tests.
type fakeComponent struct {
	name         string
	detail       any
	degradedReason string
}

func (f *fakeComponent) Component() string       { return f.name }
func (f *fakeComponent) SnapshotDetail() any     { return f.detail }
func (f *fakeComponent) Degraded() string        { return f.degradedReason }

func TestMultiSnapshotterEmpty(t *testing.T) {
	m := NewMulti()
	body, healthy, err := m.Snapshot()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !healthy {
		t.Errorf("empty MultiSnapshotter should be healthy")
	}
	if !strings.Contains(string(body), `"healthy": true`) {
		t.Errorf("body should mark healthy true; got: %s", body)
	}
}

func TestMultiSnapshotterAllHealthy(t *testing.T) {
	m := NewMulti()
	m.Add(&fakeComponent{name: "amqp", detail: map[string]any{"acked": 42}})
	m.Add(&fakeComponent{name: "mqtt", detail: map[string]any{"received": 100}})
	body, healthy, err := m.Snapshot()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !healthy {
		t.Errorf("all healthy components should aggregate healthy")
	}
	// Both component keys present
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("body not valid JSON: %v", err)
	}
	components, ok := got["components"].(map[string]any)
	if !ok {
		t.Fatalf("components not a map: %v", got["components"])
	}
	if _, ok := components["amqp"]; !ok {
		t.Errorf("amqp missing from components: %v", components)
	}
	if _, ok := components["mqtt"]; !ok {
		t.Errorf("mqtt missing from components: %v", components)
	}
	// degraded_components should be empty
	if dc, ok := got["degraded_components"].([]any); ok && len(dc) > 0 {
		t.Errorf("expected empty degraded_components, got %v", dc)
	}
}

func TestMultiSnapshotterOneDegraded(t *testing.T) {
	m := NewMulti()
	m.Add(&fakeComponent{name: "amqp", detail: map[string]any{}})
	m.Add(&fakeComponent{
		name:           "mqtt",
		detail:         map[string]any{},
		degradedReason: "no messages received in 90s",
	})
	body, healthy, err := m.Snapshot()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if healthy {
		t.Errorf("one-degraded should aggregate unhealthy")
	}
	// Parse response to verify degraded_components names the offender
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("body not valid JSON: %v", err)
	}
	dc, ok := got["degraded_components"].([]any)
	if !ok || len(dc) != 1 {
		t.Fatalf("expected 1 degraded component, got %v", got["degraded_components"])
	}
	entry := dc[0].(map[string]any)
	if entry["component"] != "mqtt" {
		t.Errorf("wrong component reported: got %v, want mqtt", entry["component"])
	}
	if !strings.Contains(entry["reason"].(string), "90s") {
		t.Errorf("reason lost during aggregation: %v", entry["reason"])
	}
}

func TestMultiSnapshotterMultipleDegraded(t *testing.T) {
	m := NewMulti()
	m.Add(&fakeComponent{name: "amqp", degradedReason: "broker disconnected"})
	m.Add(&fakeComponent{name: "mqtt", degradedReason: "not connected to broker"})
	m.Add(&fakeComponent{name: "publisher", detail: map[string]any{}})
	_, healthy, err := m.Snapshot()
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if healthy {
		t.Errorf("multiple degraded should aggregate unhealthy")
	}
}

// TestHealthzReturnsCorrectStatus checks the HTTP-layer wiring: healthy → 200,
// degraded → 503. Silent-degrade (200 with healthy=false in body) is a bug
// per ADR-0011 rule 4 — verify the status code and the body agree.
func TestHealthzReturnsCorrectStatus(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))

	cases := []struct {
		name     string
		degraded string
		wantCode int
	}{
		{"healthy", "", http.StatusOK},
		{"degraded", "broker down", http.StatusServiceUnavailable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := NewMulti()
			m.Add(&fakeComponent{name: "amqp", degradedReason: tc.degraded})

			srv := New(":0", m, nil, logger)
			handler := srv.srv.Handler

			req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)

			if rr.Code != tc.wantCode {
				t.Errorf("status: got %d, want %d\nbody: %s",
					rr.Code, tc.wantCode, rr.Body.String())
			}
			if rr.Header().Get("Content-Type") != "application/json" {
				t.Errorf("Content-Type: got %q", rr.Header().Get("Content-Type"))
			}
			body, _ := io.ReadAll(rr.Body)
			var got map[string]any
			if err := json.Unmarshal(body, &got); err != nil {
				t.Fatalf("body not JSON: %v (raw: %s)", err, body)
			}
			// Body's `healthy` boolean must agree with status code
			wantHealthyBool := tc.wantCode == http.StatusOK
			if got["healthy"] != wantHealthyBool {
				t.Errorf("body healthy=%v disagrees with status %d",
					got["healthy"], rr.Code)
			}
		})
	}
}
