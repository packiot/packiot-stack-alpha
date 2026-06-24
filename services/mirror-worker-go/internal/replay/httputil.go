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

// PostStaging is the shared POST-to-staging-edge-api boilerplate every
// replay handler uses. Returns (status, body, error). status >= 400 is
// surfaced as a non-nil error so callers can `return err` straight to
// the dispatcher (DLQ-and-advance happens in main.processRow).
//
// MW-4: Idempotency-Key derived from row.id_user_logs lets edge-api
// dedupe replays if it ever chooses to honor the header. The header is
// inert today but costs nothing to send.
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
		return resp.StatusCode, respBody,
			fmt.Errorf("staging %s returned %d: %s", path, resp.StatusCode, string(respBody))
	}
	return resp.StatusCode, respBody, nil
}
