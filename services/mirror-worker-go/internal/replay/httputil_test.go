// httputil_test.go — exercises the shared POST-to-staging helper and
// (more importantly) its narrow chicken-and-egg skip classifier.
//
// Per PR #59: when staging edge-api answers 400 or 404 with body
// `{"statusCode":...,"message":"Downtime does not exist"}` (or the
// split.service.ts variant "Event does not exist"), we reclassify the
// failure as ErrSkipReplay. Any other 4xx/5xx body must keep the
// original error and end up in mirror_replay_dlq — those are real bugs
// (validation errors, transient network failures, edge-api 5xx). The
// tests pin that boundary in both directions.
package replay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
)

func TestClassifyStagingError_TableDriven(t *testing.T) {
	// Sentinel error we hand to classifyStagingError as the "original" —
	// the function either returns this verbatim (NOT a skip) or returns
	// a new error wrapping ErrSkipReplay (skip). Comparing pointer
	// identity is the cleanest way to prove "verbatim".
	orig := errors.New("orig error — must be returned untouched for non-skip cases")

	cases := []struct {
		name     string
		status   int
		body     string
		wantSkip bool
	}{
		{
			// Real DLQ shape, event-edited category.
			name:     "400 + Downtime does not exist → skip",
			status:   400,
			body:     `{"statusCode":400,"message":"Downtime does not exist"}`,
			wantSkip: true,
		},
		{
			// edge-api/justify uses NotFoundException for the same root cause.
			name:     "404 + Downtime does not exist → skip",
			status:   404,
			body:     `{"statusCode":404,"message":"Downtime does not exist","error":"Not Found"}`,
			wantSkip: true,
		},
		{
			// split.service.ts uses a different literal — confirm we match it too.
			name:     "404 + Event does not exist → skip",
			status:   404,
			body:     `{"statusCode":404,"message":"Event does not exist","error":"Not Found"}`,
			wantSkip: true,
		},
		{
			// Real DLQ entry today — actionable validation error.
			// MUST NOT be converted to a skip or we silently swallow bugs.
			name:     "400 + Original end time must not be defined → keep error",
			status:   400,
			body:     `{"statusCode":400,"message":"Original end time must not be defined"}`,
			wantSkip: false,
		},
		{
			// Real DLQ entry — class-validator output.
			name:     "400 + validation failed → keep error",
			status:   400,
			body:     `{"statusCode":400,"message":"validation failed"}`,
			wantSkip: false,
		},
		{
			// Substring guard: the literal must match exactly. Anything
			// that merely contains the phrase is suspect (could be a
			// composite error message wrapping the phrase). Be strict.
			name:     "400 + body merely mentions phrase → keep error",
			status:   400,
			body:     `{"statusCode":400,"message":"validation: Downtime does not exist for some reason"}`,
			wantSkip: false,
		},
		{
			// 5xx is always DLQ-able for downtime/event-missing — that
			// shape ONLY matches 400/404 to avoid swallowing real 5xx
			// upstream crashes that happen to mention the phrase.
			name:     "500 + Downtime does not exist body → keep error (not 4xx)",
			status:   500,
			body:     `{"statusCode":500,"message":"Downtime does not exist"}`,
			wantSkip: false,
		},
		{
			// New rule: stop-already-satisfied is status-agnostic. Edge-api
			// returns BadRequestException → 400 per the source, but real DLQ
			// samples show 500 (cause unconfirmed: NestJS wrap, translator
			// stale-mapping path, etc.). Match on message text alone.
			name:     "500 + Production order can not be stopped → skip",
			status:   500,
			body:     `{"statusCode":500,"message":"Production order can not be stopped"}`,
			wantSkip: true,
		},
		{
			// 400 path — same rule, narrower status, still matches.
			name:     "400 + Production order can not be stopped → skip",
			status:   400,
			body:     `{"statusCode":400,"message":"Production order can not be stopped"}`,
			wantSkip: true,
		},
		{
			// Substring guard for the new rule too — the literal must match
			// exactly, not be embedded in a larger message.
			name:     "400 + body merely mentions stop phrase → keep error",
			status:   400,
			body:     `{"statusCode":400,"message":"validation: Production order can not be stopped due to FK"}`,
			wantSkip: false,
		},
		{
			// Real wire shape observed live for 500 + can-not-be-stopped:
			// edge-api returned text/plain with the bare exception message,
			// NOT the {statusCode,message} JSON envelope. Without the
			// plain-text fallback the classifier returned origErr → DLQ.
			name:     "500 + plain-text body 'Production order can not be stopped' → skip",
			status:   500,
			body:     `Production order can not be stopped`,
			wantSkip: true,
		},
		{
			// Same shape with trailing newline (some HTTP libs append).
			name:     "500 + plain-text body with trailing newline → skip",
			status:   500,
			body:     "Production order can not be stopped\n",
			wantSkip: true,
		},
		{
			// HTML error page MUST NOT match — plain-text fallback only
			// promotes EXACT (trimmed) literal matches, not substring.
			name:     "500 + HTML error page mentioning phrase → keep error",
			status:   500,
			body:     `<html><body>Production order can not be stopped — please file a ticket</body></html>`,
			wantSkip: false,
		},
		{
			// Bound the plain-text path: a giant body shouldn't be dignified
			// as a message even if it happens to start with the phrase.
			name:     "500 + plain-text body > 256 bytes → keep error",
			status:   500,
			body:     `Production order can not be stopped — ` + strings.Repeat("x", 300),
			wantSkip: false,
		},
		{
			// Body that isn't the {statusCode,message} envelope (HTML, proxy
			// junk) — we can't be confident it's parent-missing, so DLQ.
			name:     "400 + non-JSON body → keep error",
			status:   400,
			body:     `<html>nginx 400</html>`,
			wantSkip: false,
		},
		{
			// Empty body — same as above.
			name:     "404 + empty body → keep error",
			status:   404,
			body:     ``,
			wantSkip: false,
		},
		{
			// 2xx must never reach the classifier in practice, but defend
			// against it: status outside 4xx returns original.
			name:     "200 + skip-shaped body → keep error (not 4xx)",
			status:   200,
			body:     `{"statusCode":200,"message":"Downtime does not exist"}`,
			wantSkip: false,
		},

		// ── start-already-satisfied (added 2026-06-29, DLQ id 316) ──────
		{
			// Real wire shape from DLQ 316: edge-api returns 400 with the
			// JSON envelope when /api/production-orders/start hits a PO
			// already in status=2 (running). Classifier must promote to
			// skip — the operator's start-intent is satisfied.
			name:     "400 + Production order already running → skip",
			status:   400,
			body:     `{"statusCode":400,"message":"Production order already running"}`,
			wantSkip: true,
		},
		{
			// Status-agnostic — same rule for 500. Documented in
			// startAlreadySatisfiedMessages comment block.
			name:     "500 + Production order already running → skip",
			status:   500,
			body:     `{"statusCode":500,"message":"Production order already running"}`,
			wantSkip: true,
		},
		{
			// Substring guard — literal-match only. A validation message
			// that happens to contain the phrase MUST NOT be classified
			// as skip, otherwise real validation failures get hidden.
			name:     "400 + body merely mentions running phrase → keep error",
			status:   400,
			body:     `{"statusCode":400,"message":"validation: Production order already running on a different equipment"}`,
			wantSkip: false,
		},

		// ── create-already-satisfied (added 2026-06-29) ─────────────────
		{
			// /api/production-orders/create returns this when the PO row
			// for (id_enterprise, id_order) already exists. Real-world
			// trigger: EnsureActivePOs reconciler raced ahead of the
			// user_logs replay handler.
			name:     "400 + Production order already exists (no bang) → skip",
			status:   400,
			body:     `{"statusCode":400,"message":"Production order already exists"}`,
			wantSkip: true,
		},
		{
			// /setup and /create-and-start both emit the SAME phrase with
			// a trailing exclamation point. Two map entries cover the
			// punctuation variants — we don't normalize, we match literal.
			name:     "400 + Production order already exists! (with bang) → skip",
			status:   400,
			body:     `{"statusCode":400,"message":"Production order already exists!"}`,
			wantSkip: true,
		},
		{
			// Cross-variant guard: the "no-bang" and "with-bang" forms are
			// independent map entries. If someone removes one, the other
			// keeps working — pin both with explicit tests so a future
			// "normalize trailing punctuation" refactor doesn't silently
			// regress one of them.
			name:     "500 + Production order already exists! (with bang) → skip",
			status:   500,
			body:     `{"statusCode":500,"message":"Production order already exists!"}`,
			wantSkip: true,
		},
		{
			// Substring guard — same shape as start-already-running.
			// Validation messages that mention the phrase must NOT skip.
			name:     "400 + body merely mentions exists phrase → keep error",
			status:   400,
			body:     `{"statusCode":400,"message":"validation: Production order already exists in another scope"}`,
			wantSkip: false,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := classifyStagingError(c.status, []byte(c.body), "/api/downtimes/edit-manual-event", orig)
			isSkip := errors.Is(got, ErrSkipReplay)
			if isSkip != c.wantSkip {
				t.Fatalf("errors.Is(ErrSkipReplay) = %v, want %v; got error: %v", isSkip, c.wantSkip, got)
			}
			if !c.wantSkip && got != orig {
				// Non-skip cases must return the EXACT sentinel pointer —
				// no wrapping, no rewriting. Wrapping would break callers
				// that check Is(translate.ErrUnmapped) etc.
				t.Fatalf("non-skip case returned %v, want verbatim orig %v", got, orig)
			}
		})
	}
}

// TestClassifyStagingError_GateReject — pins the edge-api PR #148 gate-409
// terminal classification (task #46 Part A). A 409 whose structured body
// carries a recognized `reason` must be promoted to ErrTerminalReplay
// (leave the retry loop, land in the DLQ review tray pre-retired). A 409
// with an unknown reason, a non-409 with a gate-shaped body, and a missing
// body must all stay verbatim (retryable / whatever they are today). None
// of these may ever be confused with ErrSkipReplay (which would discard
// them without a review row).
func TestClassifyStagingError_GateReject(t *testing.T) {
	orig := errors.New("orig error — must be returned untouched for non-terminal cases")

	cases := []struct {
		name         string
		status       int
		body         string
		wantTerminal bool
	}{
		{
			// The actual observed shape: a buffered stop whose assumedRunningPo
			// no longer matches the authoritative running PO.
			name:         "409 STALE_HEAD → terminal",
			status:       409,
			body:         `{"statusCode":409,"reason":"STALE_HEAD","currentRunningPo":17106,"actionTime":"22:17-03:00","message":"stale"}`,
			wantTerminal: true,
		},
		{
			name:         "409 RANGE_CONFLICT → terminal",
			status:       409,
			body:         `{"statusCode":409,"reason":"RANGE_CONFLICT","message":"overlaps settled range"}`,
			wantTerminal: true,
		},
		{
			name:         "409 BEYOND_HORIZON → terminal",
			status:       409,
			body:         `{"statusCode":409,"reason":"BEYOND_HORIZON","message":"older than horizon"}`,
			wantTerminal: true,
		},
		{
			// A 409 without a recognized gate reason stays whatever it is
			// today — we only make KNOWN gate rejects terminal.
			name:         "409 unknown reason → keep error (not terminal)",
			status:       409,
			body:         `{"statusCode":409,"reason":"SOMETHING_ELSE","message":"conflict"}`,
			wantTerminal: false,
		},
		{
			// A bare 409 with no reason field (e.g. a generic edge-api
			// ConflictException) is NOT a gate reject — stays retryable.
			name:         "409 no reason field → keep error (not terminal)",
			status:       409,
			body:         `{"statusCode":409,"message":"some other conflict"}`,
			wantTerminal: false,
		},
		{
			// Non-JSON 409 body — can't confirm a gate reason, keep error.
			name:         "409 non-JSON body → keep error (not terminal)",
			status:       409,
			body:         `<html>nginx 409</html>`,
			wantTerminal: false,
		},
		{
			// Status-gated to 409: the pre-#148 masked reject came back as a
			// 500. A 500 — even with a gate-shaped body — must stay a plain
			// retryable error (a real 5xx is a genuine server fault).
			name:         "500 with gate-shaped body → keep error (not terminal)",
			status:       500,
			body:         `{"statusCode":500,"reason":"STALE_HEAD","message":"masked"}`,
			wantTerminal: false,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := classifyStagingError(c.status, []byte(c.body), "/api/production-orders/stop", orig)
			isTerminal := errors.Is(got, ErrTerminalReplay)
			if isTerminal != c.wantTerminal {
				t.Fatalf("errors.Is(ErrTerminalReplay) = %v, want %v; got error: %v", isTerminal, c.wantTerminal, got)
			}
			// A terminal reject must NEVER also read as a skip (skip would
			// discard the row without a DLQ review trail).
			if errors.Is(got, ErrSkipReplay) {
				t.Fatalf("gate reject must not match ErrSkipReplay; got: %v", got)
			}
			// Non-terminal cases must return the EXACT sentinel pointer —
			// verbatim, so the row stays retryable exactly as before #148.
			if !c.wantTerminal && got != orig {
				t.Fatalf("non-terminal case returned %v, want verbatim orig %v", got, orig)
			}
		})
	}
}

// TestPostStaging_TerminalOnGate409StaleHead — end-to-end (httptest) proof
// that a 409 STALE_HEAD from staging edge-api surfaces as ErrTerminalReplay
// through PostStaging, so the dispatcher/processRow terminal path fires
// (ack + retire, no requeue). Task #46 Part A: "409 STALE_HEAD → terminal".
func TestPostStaging_TerminalOnGate409StaleHead(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_, _ = io.WriteString(w, `{"statusCode":409,"reason":"STALE_HEAD","currentRunningPo":17106,"actionTime":"22:17-03:00","message":"assumed PO not running"}`)
	}))
	t.Cleanup(srv.Close)

	cfg := &config.Config{
		StagingAPIBaseURL:   srv.URL,
		SourceName:          "cpack-prod-go-test",
		StagingEnterpriseID: 3,
	}
	httpc := &http.Client{Timeout: 5 * time.Second}
	row := db.ProdUserLog{IDUserLogs: 2567207}

	status, _, err := PostStaging(context.Background(), cfg, httpc, "tok",
		row, "/api/production-orders/stop", map[string]any{"x": 1})
	if err == nil {
		t.Fatal("PostStaging err = nil, want terminal error")
	}
	if !errors.Is(err, ErrTerminalReplay) {
		t.Fatalf("err = %v, want errors.Is(ErrTerminalReplay) = true", err)
	}
	if errors.Is(err, ErrSkipReplay) {
		t.Fatalf("err = %v, must NOT match ErrSkipReplay (terminal keeps a DLQ review row)", err)
	}
	if status != http.StatusConflict {
		t.Errorf("status = %d, want 409", status)
	}
}

// TestPostStaging_5xxStillRetryable — task #46 Part A: "a 5xx → still
// retried". A 500 (including the pre-#148 masked-reject regime) must stay a
// plain retryable error: NOT terminal, NOT skip. The DLQRetrier keeps
// re-driving it, which is correct for a genuine server fault.
func TestPostStaging_5xxStillRetryable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, `{"statusCode":500,"message":"Internal server error"}`)
	}))
	t.Cleanup(srv.Close)

	cfg := &config.Config{
		StagingAPIBaseURL:   srv.URL,
		SourceName:          "cpack-prod-go-test",
		StagingEnterpriseID: 3,
	}
	httpc := &http.Client{Timeout: 5 * time.Second}
	row := db.ProdUserLog{IDUserLogs: 999}

	_, _, err := PostStaging(context.Background(), cfg, httpc, "tok",
		row, "/api/production-orders/stop", map[string]any{"x": 1})
	if err == nil {
		t.Fatal("PostStaging err = nil, want retryable failure error")
	}
	if errors.Is(err, ErrTerminalReplay) {
		t.Fatalf("err = %v, must NOT match ErrTerminalReplay (5xx is retryable)", err)
	}
	if errors.Is(err, ErrSkipReplay) {
		t.Fatalf("err = %v, must NOT match ErrSkipReplay (5xx is retryable)", err)
	}
}

// TestPostStaging_SkipsOnDowntimeMissing — end-to-end check that the
// classifier is wired into PostStaging itself. Uses httptest.NewServer
// to model staging edge-api returning the 400 + parent-missing body.
// Verifies the returned error satisfies errors.Is(err, ErrSkipReplay)
// so the dispatcher's skip path fires.
func TestPostStaging_SkipsOnDowntimeMissing(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = io.WriteString(w, `{"statusCode":400,"message":"Downtime does not exist"}`)
	}))
	t.Cleanup(srv.Close)

	cfg := &config.Config{
		StagingAPIBaseURL:   srv.URL,
		SourceName:          "cpack-prod-go-test",
		StagingEnterpriseID: 3,
	}
	httpc := &http.Client{Timeout: 5 * time.Second}
	row := db.ProdUserLog{IDUserLogs: 999}

	_, _, err := PostStaging(context.Background(), cfg, httpc, "tok",
		row, "/api/downtimes/edit-manual-event", map[string]any{"x": 1})
	if err == nil {
		t.Fatal("PostStaging err = nil, want skip error")
	}
	if !errors.Is(err, ErrSkipReplay) {
		t.Fatalf("err = %v, want errors.Is(ErrSkipReplay) = true", err)
	}
}

// TestPostStaging_KeepsValidationErrorAsFailure — same shape, but with
// a real-world validation error body (event-splitted DLQ today). The
// returned error MUST NOT match ErrSkipReplay or we'd silently lose
// actionable bug reports.
func TestPostStaging_KeepsValidationErrorAsFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = io.WriteString(w, `{"statusCode":400,"message":"Original end time must not be defined"}`)
	}))
	t.Cleanup(srv.Close)

	cfg := &config.Config{
		StagingAPIBaseURL:   srv.URL,
		SourceName:          "cpack-prod-go-test",
		StagingEnterpriseID: 3,
	}
	httpc := &http.Client{Timeout: 5 * time.Second}
	row := db.ProdUserLog{IDUserLogs: 999}

	_, _, err := PostStaging(context.Background(), cfg, httpc, "tok",
		row, "/api/downtimes/split", map[string]any{"x": 1})
	if err == nil {
		t.Fatal("PostStaging err = nil, want failure error")
	}
	if errors.Is(err, ErrSkipReplay) {
		t.Fatalf("err = %v, must NOT match ErrSkipReplay (validation error must DLQ)", err)
	}
	// Sanity-check the original message survived.
	if !strings.Contains(err.Error(), "Original end time") {
		t.Errorf("error string lost original validation message: %v", err)
	}
}

// TestPostStaging_KeepsServerErrorAsFailure — 5xx must always DLQ, even
// if the body happens to contain the skip phrase (defense in depth
// against a future bug where edge-api emits a 500 with the wrong body).
func TestPostStaging_KeepsServerErrorAsFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, `{"statusCode":500,"message":"Downtime does not exist"}`)
	}))
	t.Cleanup(srv.Close)

	cfg := &config.Config{
		StagingAPIBaseURL:   srv.URL,
		SourceName:          "cpack-prod-go-test",
		StagingEnterpriseID: 3,
	}
	httpc := &http.Client{Timeout: 5 * time.Second}
	row := db.ProdUserLog{IDUserLogs: 999}

	_, _, err := PostStaging(context.Background(), cfg, httpc, "tok",
		row, "/api/downtimes/edit-manual-event", map[string]any{"x": 1})
	if err == nil {
		t.Fatal("PostStaging err = nil, want failure error")
	}
	if errors.Is(err, ErrSkipReplay) {
		t.Fatalf("err = %v, must NOT match ErrSkipReplay (5xx must DLQ regardless of body)", err)
	}
}

// TestPostStaging_HappyPath — 2xx returns nil error, unchanged contract.
func TestPostStaging_HappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"ok":true}`)
	}))
	t.Cleanup(srv.Close)

	cfg := &config.Config{
		StagingAPIBaseURL:   srv.URL,
		SourceName:          "cpack-prod-go-test",
		StagingEnterpriseID: 3,
	}
	httpc := &http.Client{Timeout: 5 * time.Second}
	row := db.ProdUserLog{IDUserLogs: 999}

	status, _, err := PostStaging(context.Background(), cfg, httpc, "tok",
		row, "/api/downtimes/justify", map[string]any{"x": 1})
	if err != nil {
		t.Fatalf("PostStaging err = %v, want nil", err)
	}
	if status != http.StatusCreated {
		t.Errorf("status = %d, want 201", status)
	}
}

// TestEdgeAPIError_Unmarshal — defensive parse check on the edge-api
// error envelope. Pinned so a future "tighten the schema" change to
// edgeAPIError doesn't silently break the message extraction.
func TestEdgeAPIError_Unmarshal(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		wantMsg string
	}{
		{"BadRequest standard", `{"statusCode":400,"message":"Downtime does not exist"}`, "Downtime does not exist"},
		{"NotFound with error field", `{"statusCode":404,"message":"Event does not exist","error":"Not Found"}`, "Event does not exist"},
		{"message-only", `{"message":"x"}`, "x"},
		{"extras tolerated", `{"foo":"bar","message":"y","baz":1}`, "y"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var p edgeAPIError
			if err := json.Unmarshal([]byte(c.raw), &p); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if p.Message != c.wantMsg {
				t.Errorf("Message = %q, want %q", p.Message, c.wantMsg)
			}
		})
	}
}

// TestErrSkipReplay_WrappedByPostStagingPath — explicit wrapping check.
// The handler-level `errors.Is(err, ErrSkipReplay)` decision in the
// dispatcher depends on errors.Unwrap walking through `fmt.Errorf("...%w",
// ErrSkipReplay)`. Pin it.
func TestErrSkipReplay_WrappedByPostStagingPath(t *testing.T) {
	wrapped := fmt.Errorf("staging /api/downtimes/edit-manual-event returned 400: parent missing: %w", ErrSkipReplay)
	if !errors.Is(wrapped, ErrSkipReplay) {
		t.Fatal("errors.Is failed on direct wrap")
	}
	// Double-wrap (handler-level wrapping over PostStaging's wrap).
	doubleWrapped := fmt.Errorf("event-edited: %w", wrapped)
	if !errors.Is(doubleWrapped, ErrSkipReplay) {
		t.Fatal("errors.Is failed through 2 layers of wrap — dispatcher would miss the skip")
	}
}
