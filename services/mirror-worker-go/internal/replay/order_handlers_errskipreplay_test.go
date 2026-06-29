// order_handlers_errskipreplay_test.go — regression guard for the
// translate.ErrUnmapped → ErrSkipReplay wrap pattern across every
// order-* handler that translates a prod production_order id to a
// staging one.
//
// Why this test exists: DLQ id 316 (2026-06-29) showed that order_started
// detected translate.ErrUnmapped but wrapped it as the raw err instead
// of the ErrSkipReplay sentinel. The dispatcher only recognises
// ErrSkipReplay; wrapping with anything else → outcome=failed → row
// lands in DLQ and bounces 5 retries before getting permanently stuck.
//
// The bug was structural — order_changed (PR #82) and order_replaced
// got the fix; order_started + order_stopped + order_status_changed
// were missed. This test pins the fix across all four handlers so a
// future refactor can't silently revert one of them.
//
// Same SQL-blob-scan shape as the translator regression tests in
// translate_test.go: read the source file, assert specific substrings
// are present, fail with a diagnostic message naming the bug if not.
package replay

import (
	"os"
	"strings"
	"testing"
)

func TestOrderHandlersWrapUnmappedAsSkipReplay(t *testing.T) {
	// Each handler that translates a prod PO must:
	//   1. Detect translate.ErrUnmapped via errors.Is
	//   2. Wrap as ErrSkipReplay (NOT raw err) so the dispatcher routes
	//      to outcome=skipped + cursor advances + no DLQ
	//   3. Log a diagnostic info-level line so operators see WHY in worker logs
	//
	// We assert these on source-file text. Crude but effective — catches a
	// regression at `go test` time with zero infra cost.
	handlers := []struct {
		file       string
		eventType  string
		bugContext string
	}{
		{"order_changed.go", "order-changed", "PR #82 — the original fix"},
		{"order_started.go", "order-started", "DLQ id 316 (2026-06-29) — wrapped raw err instead of ErrSkipReplay"},
		{"order_stopped.go", "order-stopped", "wrapped raw err instead of ErrSkipReplay (silent latent bug)"},
		{"order_status_changed.go", "order-status-changed", "didn't even detect ErrUnmapped — every unmapped PO landed in DLQ as a generic translate failure"},
		{"order_replaced.go", "order-replaced", "got the fix early; included as the structural template"},
	}

	for _, h := range handlers {
		t.Run(h.eventType, func(t *testing.T) {
			src, err := os.ReadFile(h.file)
			if err != nil {
				t.Fatalf("read %s: %v", h.file, err)
			}
			body := string(src)

			// (1) Must detect ErrUnmapped via errors.Is.
			if !strings.Contains(body, "errors.Is(err, translate.ErrUnmapped)") {
				t.Errorf("%s: missing `errors.Is(err, translate.ErrUnmapped)` detection branch — %s",
					h.file, h.bugContext)
			}
			// (2) Must wrap as ErrSkipReplay (the sentinel the dispatcher
			// recognises). The textual marker is `, ErrSkipReplay)` — the
			// last positional arg to fmt.Errorf with the %w verb.
			if !strings.Contains(body, ", ErrSkipReplay)") {
				t.Errorf("%s: missing `, ErrSkipReplay)` wrap in the ErrUnmapped branch — %s. Wrapping with raw err sends the row to DLQ instead of skip-+-advance.",
					h.file, h.bugContext)
			}
			// (3) Diagnostic log line so operators can see WHY a row was
			// skipped (otherwise skip-replays look identical to "nothing
			// happened" in the log stream).
			wantLogMsg := "skipping " + h.eventType + ":"
			if !strings.Contains(body, wantLogMsg) {
				t.Errorf("%s: missing diagnostic log message starting with %q — operators inspecting why a row was skipped have nothing to grep for",
					h.file, wantLogMsg)
			}
		})
	}
}
