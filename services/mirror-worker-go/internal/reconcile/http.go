package reconcile

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// post is the reconciler's POST helper — same wire shape as
// replay/httputil.go:PostStaging but without the db.ProdUserLog
// dependency, since reconciler runs outside the user_logs cursor flow.
// Idempotency-Key derived from a stable per-PO id so retries on a
// transient failure don't double-create on edge-api.
//
// Test-friendly: if r.postFunc is set, it wins (table-driven tests
// inject a fake without touching the network).
func (r *Reconciler) post(ctx context.Context, path string, body any, idemKey string) (int, []byte, error) {
	if r.postFunc != nil {
		return r.postFunc(ctx, path, body, idemKey)
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return 0, nil, fmt.Errorf("marshal body: %w", err)
	}
	url := fmt.Sprintf("%s%s?token=%s&idEnterprise=%d",
		r.cfg.StagingAPIBaseURL, path, r.apiToken(), r.cfg.StagingEnterpriseID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return 0, nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-user", "mirror-worker-go-reconciler")
	req.Header.Set("X-Mirror-Source", r.cfg.SourceName)
	req.Header.Set("Idempotency-Key", idemKey)

	ctx2, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req = req.WithContext(ctx2)

	resp, err := r.httpc.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("POST %s: %w", path, err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return resp.StatusCode, respBody, fmt.Errorf("staging %s returned %d", path, resp.StatusCode)
	}
	return resp.StatusCode, respBody, nil
}
