package httpingest

import (
	"io"
	"log/slog"
	"net/http"
	"testing"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

type linkCall struct {
	group string
	link  rawtag.Link
}

func newLinkRouter(t *testing.T, calls *[]linkCall) http.Handler {
	t.Helper()
	outcomes := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "t_link_outcomes"}, []string{"outcome"})
	srv := NewRouter(Config{APIKey: testKey, Link: func(g string, l rawtag.Link) {
		*calls = append(*calls, linkCall{g, l})
	}}, map[string]Sink{"BISPHARMASTAGING": (&captureSink{}).fn}, outcomes, slog.New(slog.NewTextHandler(io.Discard, nil)))
	return srv.Handler()
}

// A failed PLC read arrives as tags:[] + link.ok=false; it is accepted (202) and
// reported with the routed group.
func TestLink_FailedReadReported(t *testing.T) {
	var calls []linkCall
	h := newLinkRouter(t, &calls)
	body := `{"group":"BISPHARMASTAGING","endpoint":"L60","scan_ts":1700000000000,"tags":[],"link":{"ok":false,"err":"timed out","ms":5000}}`
	if rec := post(t, h, testKey, body); rec.Code != http.StatusAccepted {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if len(calls) != 1 || calls[0].group != "BISPHARMASTAGING" || calls[0].link.OK || calls[0].link.Endpoint != "L60" {
		t.Fatalf("calls = %+v", calls)
	}
}

// A rejected request (bad key, unknown group) never reports link health.
func TestLink_RejectedNeverReported(t *testing.T) {
	var calls []linkCall
	h := newLinkRouter(t, &calls)
	body := `{"group":"BISPHARMASTAGING","endpoint":"L60","scan_ts":1,"tags":[],"link":{"ok":false}}`
	if rec := post(t, h, "wrong-key", body); rec.Code != http.StatusUnauthorized {
		t.Fatalf("status %d", rec.Code)
	}
	foreign := `{"group":"OTHER","endpoint":"L60","scan_ts":1,"tags":[],"link":{"ok":false}}`
	if rec := post(t, h, testKey, foreign); rec.Code != http.StatusForbidden {
		t.Fatalf("status %d", rec.Code)
	}
	if len(calls) != 0 {
		t.Fatalf("rejected requests reported link health: %+v", calls)
	}
}

// Envelopes without a link field behave exactly as before (no report).
func TestLink_AbsentIsNoop(t *testing.T) {
	var calls []linkCall
	h := newLinkRouter(t, &calls)
	if rec := post(t, h, testKey, `{"group":"BISPHARMASTAGING","endpoint":"L01","scan_ts":1,"tags":[{"metric":"/a","value":1}]}`); rec.Code != http.StatusAccepted {
		t.Fatalf("status %d", rec.Code)
	}
	if len(calls) != 0 {
		t.Fatalf("calls = %+v", calls)
	}
}
