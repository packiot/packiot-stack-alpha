package replay

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
)

// downtimeMissingMessages are the EXACT edge-api error messages emitted by
// /api/downtimes/{justify,edit-manual-event,split} when the parent
// downtime/event referenced by the child replay no longer exists on
// staging. These strings are stable literals in:
//
//   - edge-api/src/usecases/downtimes/justify/justify.service.ts
//       throw new NotFoundException('Downtime does not exist');         // 404
//   - edge-api/src/usecases/downtimes/edit-manual-event/...service.ts
//       throw new BadRequestException('Downtime does not exist');       // 400
//   - edge-api/src/usecases/downtimes/split/split.service.ts
//       throw new NotFoundException('Event does not exist');            // 404
//
// When edge-api returns 400 OR 404 with one of these EXACT messages we
// treat the row as ErrSkipReplay — the parent it depends on was never
// mirrored to staging (cursor began after parent creation, or parent was
// the LLLLL-garbage that PR #58 now skips upstream). Retrying will never
// fix it: the row is structurally unmappable, identical in spirit to
// translate.ErrUnmapped, so it must not sit in mirror_replay_dlq.
//
// Other 400s (validation errors like "Original end time must not be
// defined") MUST stay as plain errors → DLQ → operator attention. Match
// on the exact literal only.
var downtimeMissingMessages = map[string]struct{}{
	"Downtime does not exist": {},
	"Event does not exist":    {},
}

// stopAlreadySatisfiedMessages are the EXACT edge-api error messages
// emitted by /api/production-orders/stop when the PO is in a state where
// it can't be stopped (status != 2 / "running"):
//
//   - edge-api/src/usecases/production-orders/stop-production-order/...service.ts
//       throw new BadRequestException('Production order can not be stopped');
//
// In our cross-system replay context this is *intent already satisfied*,
// not an error — the operator's intent ("make this PO not running") is
// met because the staging PO is already non-running. Treating these as
// hard failures fills DLQ with rows that will never become replayable
// (no retry will run staging time backwards). Same skip class as
// downtimeMissingMessages — log + advance cursor, no DLQ.
//
// Note: edge-api's HttpExceptionFilter is correctly returning 400 for
// BadRequestException, but our DLQ samples show 500 in the wire log —
// likely a NestJS wrap around an upstream throw, or a translator-cached
// staging PO that no longer matches its mapping. The classifier matches
// on message text alone for both reasons (a) status code isn't reliable
// for cross-system "already satisfied" semantics, (b) the message is a
// stable string literal in the service source.
var stopAlreadySatisfiedMessages = map[string]struct{}{
	"Production order can not be stopped": {},
}

// edgeAPIError matches the JSON body emitted by edge-api's global
// HttpExceptionFilter: { statusCode, message, error? }. We only care
// about `message` for the skip decision.
type edgeAPIError struct {
	Message string `json:"message"`
}

// classifyStagingError inspects an edge-api error response and returns
// either an error wrapping ErrSkipReplay (chicken-and-egg parent-missing
// case, or stop-already-satisfied), or the original verbatim error.
// Both 4xx and 5xx are considered: 4xx for the downtime/event-missing
// shape (404/400), 5xx for the stop-already-satisfied shape that some
// edge-api code paths surface as 500 instead of 400.
//
// Body handling: tries JSON unmarshal first (the standard NestJS
// {statusCode,message} envelope). If that fails — e.g. edge-api returned
// the bare exception message as text/plain, observed live for the
// /api/production-orders/stop 500 case — fall back to a TRIMMED EXACT
// string match against the same message maps. Substring matching is
// NOT used (a body like "validation: <phrase>" must keep its error so
// real bugs DLQ).
//
// Exposed as a free function (not a method) so the tests can exercise the
// match logic without spinning up a full http.Server.
func classifyStagingError(status int, body []byte, path string, origErr error) error {
	// Only attempt to reclassify error responses (>= 400). Other status
	// codes shouldn't be reaching this function in practice, but guard
	// anyway so a 2xx never gets promoted to skip.
	if status < http.StatusBadRequest {
		return origErr
	}

	// Extract the candidate message either from the JSON envelope or
	// from the raw bytes when they ARE the message. msg ends up as ""
	// when neither path produces a candidate — falls through to origErr.
	var msg string
	var parsed edgeAPIError
	if json.Unmarshal(body, &parsed) == nil && parsed.Message != "" {
		msg = parsed.Message
	} else {
		// Plain-text body — trim trailing newline(s) and treat the whole
		// body as the candidate message. Bounded to a sane size so we
		// don't dignify a 50KB HTML error page as a "message".
		const maxPlainTextMsgLen = 256
		trimmed := bytes.TrimSpace(body)
		if len(trimmed) > 0 && len(trimmed) <= maxPlainTextMsgLen {
			msg = string(trimmed)
		}
	}

	// 400/404 — parent downtime/event missing (existing rule).
	if status == http.StatusBadRequest || status == http.StatusNotFound {
		if _, ok := downtimeMissingMessages[msg]; ok {
			return fmt.Errorf("staging %s returned %d: parent downtime/event missing — child replay skipped: %w",
				path, status, ErrSkipReplay)
		}
	}
	// Any status — PO stop-already-satisfied. Status-agnostic because
	// edge-api inconsistently returns 400 vs 500 for this case depending
	// on the upstream throw path (BadRequestException vs uncaught throw
	// wrapped by NestJS). Message literal is what we match on.
	if _, ok := stopAlreadySatisfiedMessages[msg]; ok {
		return fmt.Errorf("staging %s returned %d: PO already non-running, stop intent already satisfied: %w",
			path, status, ErrSkipReplay)
	}
	return origErr
}

// PostStaging is the shared POST-to-staging-edge-api boilerplate every
// replay handler uses. Returns (status, body, error). status >= 400 is
// surfaced as a non-nil error so callers can `return err` straight to
// the dispatcher (DLQ-and-advance happens in main.processRow).
//
// MW-4: Idempotency-Key derived from row.id_user_logs lets edge-api
// dedupe replays if it ever chooses to honor the header. The header is
// inert today but costs nothing to send.
//
// MW-5 (PR #59): 400/404 responses with body
// `{"message":"Downtime does not exist"}` (or "Event does not exist")
// are reclassified as ErrSkipReplay — the parent the child references
// was never mirrored. Same skip semantics as translate.ErrUnmapped:
// outcome=skipped, no DLQ row, cursor advances.
func PostStaging(
	ctx context.Context,
	cfg *config.Config,
	httpc *http.Client,
	apiToken string,
	row db.ProdUserLog,
	path string,
	body any,
) (int, []byte, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return 0, nil, fmt.Errorf("marshal body: %w", err)
	}
	url := fmt.Sprintf("%s%s?token=%s&idEnterprise=%d",
		cfg.StagingAPIBaseURL, path, apiToken, cfg.StagingEnterpriseID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return 0, nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	nmUser := "mirror-worker-go"
	if row.NmUser != nil {
		nmUser = *row.NmUser
	}
	req.Header.Set("x-user", nmUser)
	req.Header.Set("X-Mirror-Source", cfg.SourceName)
	req.Header.Set("Idempotency-Key", fmt.Sprintf("%s/%d", cfg.SourceName, row.IDUserLogs))

	ctx2, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req = req.WithContext(ctx2)

	resp, err := httpc.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("POST %s: %w", path, err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		origErr := fmt.Errorf("staging %s returned %d: %s", path, resp.StatusCode, string(respBody))
		return resp.StatusCode, respBody, classifyStagingError(resp.StatusCode, respBody, path, origErr)
	}
	return resp.StatusCode, respBody, nil
}
