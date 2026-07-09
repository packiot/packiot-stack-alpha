package adapter

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// edgeResult captures what came back from edge-api so the handler can translate
// it into the adapter's own status semantics without re-reading the body.
type edgeResult struct {
	statusCode int
	body       []byte
}

// EdgeClient calls edge-api internally. It injects the enterprise-4 api key
// (never client-supplied, never logged) and the ?idEnterprise= query param so
// edge-api's audit logger records the correct tenant on user_logs.
type EdgeClient struct {
	baseURL string
	apiKey  string
	http    *http.Client
}

// NewEdgeClient constructs the real edge-api client used by main. It is
// returned as the concrete type but satisfies the unexported edgePoster seam
// the Server depends on.
func NewEdgeClient(baseURL, apiKey string, timeout time.Duration) *EdgeClient {
	return &EdgeClient{
		baseURL: baseURL,
		apiKey:  apiKey,
		http:    &http.Client{Timeout: timeout},
	}
}

// post sends the mapped edgeCall to edge-api. Auth is the documented
// contract: x-api-key header (preferred over the deprecated ?token=) plus
// ?idEnterprise= for tenant scoping and audit attribution.
//
// A transport error (edge-api down / DNS / TLS) returns a non-nil error so the
// handler can answer 503. A 4xx/5xx from edge-api is NOT an error here — it's a
// valid result the handler passes through / maps.
func (c *EdgeClient) post(ctx context.Context, call *edgeCall) (*edgeResult, error) {
	payload, err := json.Marshal(call.body)
	if err != nil {
		return nil, fmt.Errorf("marshal edge body: %w", err)
	}

	u, err := url.Parse(c.baseURL + call.path)
	if err != nil {
		return nil, fmt.Errorf("parse edge url: %w", err)
	}
	q := u.Query()
	q.Set("idEnterprise", fmt.Sprintf("%d", call.idEnterprise))
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("build edge request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", c.apiKey)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("edge-api unreachable: %w", err)
	}
	defer resp.Body.Close()

	// Cap the response we read — edge-api replies are small; this guards
	// against a misbehaving upstream flooding memory.
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("read edge response: %w", err)
	}
	return &edgeResult{statusCode: resp.StatusCode, body: body}, nil
}
