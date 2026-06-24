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

// edgeAPIError matches the JSON body emitted by edge-api's global
// HttpExceptionFilter: { statusCode, message, error? }. We only care
// about `message` for the skip decision.
type edgeAPIError struct {
	Message string `json:"message"`
}

// classifyStagingError inspects an edge-api error response and returns
// either an error wrapping ErrSkipReplay (chicken-and-egg parent-missing
// case), or the original verbatim error. Only HTTP 400/404 with an EXACT
// known-message match is promoted; everything else passes through.
//
// Exposed as a free function (not a method) so the tests can exercise the
// match logic without spinning up a full http.Server.
func classifyStagingError(status int, body []byte, path string, origErr error) error {
	if status != http.StatusBadRequest && status != http.StatusNotFound {
		return origErr
	}
	var parsed edgeAPIError
	if err := json.Unmarshal(body, &parsed); err != nil {
		// Body wasn't the standard {statusCode,message} shape — don't
		// claim it's a skip. Could be HTML, plain text, or upstream
		// proxy junk; safer to DLQ + investigate.
		return origErr
	}
	if _, ok := downtimeMissingMessages[parsed.Message]; !ok {
		return origErr
	}
	return fmt.Errorf("staging %s returned %d: parent downtime/event missing — child replay skipped: %w",
		path, status, ErrSkipReplay)
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
