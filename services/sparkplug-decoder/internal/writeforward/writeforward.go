// Package writeforward is the ADR-0054 Option-A operator write forwarder: the
// factory-local edge-api front for the on-box operator. It sits behind the
// operator's edge nginx (which proxies /api + /session to it) and makes the
// CLOUD edge-api the single authoritative writer while keeping the floor usable
// through an internet outage.
//
// The contract:
//
//   - ONLINE — a write is forwarded to the cloud edge-api and its real response
//     (200/400/401/409/…) is returned verbatim. A 4xx is a legitimate answer
//     (e.g. a stale-state 409), NOT an outage — it is returned, never queued.
//
//   - OUTAGE — when the cloud is UNREACHABLE (transport error, or a 502/503/504
//     gateway error), the write is appended to a durable on-disk outbox (the
//     ADR-0011 store-and-forward, reused here) and the caller gets 202 { queued:
//     true }. A background drain replays queued writes to the cloud in FIFO
//     order when connectivity returns, deleting each on a definitive response.
//
// Idempotency: the operator SPA stamps every durable write with an
// Idempotency-Key (src/Services/durableWrite.js); the forwarder preserves it (and
// the nginx-injected x-api-key) on replay, so the cloud edge-api dedups a write
// that was optimistically accepted at the edge and later replayed.
//
// This is Option A (durable-forward-only): the box owns no PO state and runs no
// local Postgres — it only guarantees the write is not LOST and lands exactly
// once when the link returns. (Option B — locally-authoritative — is the gated
// ADR-0054 future.)
package writeforward

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/outbox"
)

// forwardHeaders is the safelist replayed to the cloud. The operator write
// contract needs the idempotency key (dedup), the tenant api-key the edge nginx
// injects (auth), the content type, and any bearer. Everything else (Host,
// hop-by-hop headers) is intentionally dropped — the http.Client sets its own.
var forwardHeaders = []string{
	"Idempotency-Key",
	"X-Api-Key",
	"Content-Type",
	"Authorization",
}

// pending is the self-contained replay envelope stored as the outbox Payload:
// everything needed to re-issue the write to the cloud with no other state.
type pending struct {
	Method  string            `json:"method"`
	Path    string            `json:"path"` // request URI incl. query, e.g. /api/production-orders/start
	Headers map[string]string `json:"headers"`
	Body    []byte            `json:"body"`
}

// Forwarder forwards operator writes to the cloud edge-api, queuing on outage.
type Forwarder struct {
	// CloudBase is the cloud edge-api origin, e.g. https://edge.api.staging.packiot.app.
	CloudBase string
	// Tenant is the lowercased group id (the outbox Message.Tenant).
	Tenant string
	// Store is the durable outbox (reused ADR-0011 store-and-forward).
	Store *outbox.Store
	// Client is the HTTP client used for both live forward and drain replay.
	Client *http.Client
	// MaxBackoff caps the per-message drain backoff.
	MaxBackoff time.Duration
}

// Result is the outcome of Handle.
type Result struct {
	Status int    // HTTP status to return to the operator SPA
	Body   []byte // response body to return
	Queued bool   // true when the write was buffered (cloud unreachable)
}

// unreachable reports whether an upstream response/error means "cloud is down"
// (→ queue) rather than "cloud answered" (→ return the answer). A transport
// error, or a gateway 502/503/504, is an outage; any other status is an answer.
func unreachable(status int, err error) bool {
	if err != nil {
		return true
	}
	return status == http.StatusBadGateway ||
		status == http.StatusServiceUnavailable ||
		status == http.StatusGatewayTimeout
}

// Handle forwards one operator write. path is the full request URI (with query).
func (f *Forwarder) Handle(
	ctx context.Context,
	method, path string,
	headers map[string]string,
	body []byte,
) (Result, error) {
	status, respBody, err := f.postCloud(ctx, method, path, headers, body)
	if !unreachable(status, err) {
		// The cloud answered (2xx or a real 4xx like a stale-state 409). Return
		// it verbatim — this is NOT an outage, so nothing is queued.
		return Result{Status: status, Body: respBody}, nil
	}

	// Outage: durably buffer the write and tell the SPA it is queued. The SPA's
	// own review tray + optimistic UI take it from here; the drain replays it.
	env, mErr := json.Marshal(pending{Method: method, Path: path, Headers: headers, Body: body})
	if mErr != nil {
		return Result{}, mErr
	}
	if _, qErr := f.Store.Enqueue(ctx, outbox.Message{
		Tenant:  f.Tenant,
		Topic:   method + " " + path,
		Payload: env,
	}); qErr != nil {
		// Could not even persist the write — surface a 503 so the SPA keeps it
		// in its own IndexedDB queue rather than believing it was accepted.
		return Result{}, qErr
	}
	resp, _ := json.Marshal(map[string]any{
		"queued": true,
		"detail": "cloud unreachable; write buffered on the edge and will forward on reconnect",
	})
	return Result{Status: http.StatusAccepted, Body: resp, Queued: true}, nil
}

// DrainOnce replays up to batchSize queued writes to the cloud. A definitive
// response (any non-gateway status, incl. a 4xx the cloud won't reconsider)
// deletes the row — a replayed write must not loop forever on a permanent
// rejection. A transport/gateway error marks an attempt with backoff and leaves
// the row for the next pass. Returns the number of rows removed.
func (f *Forwarder) DrainOnce(ctx context.Context, batchSize int) (int, error) {
	msgs, err := f.Store.Peek(ctx, batchSize)
	if errors.Is(err, outbox.ErrOutboxEmpty) {
		// Nothing ready — either truly empty or every row is still in backoff.
		// A no-op drain, not an error.
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	drained := 0
	for _, m := range msgs {
		var p pending
		if err := json.Unmarshal(m.Payload, &p); err != nil {
			// A corrupt/undecodable row can never be replayed — drop it rather
			// than wedge the queue head forever.
			if dErr := f.Store.Delete(ctx, m.ID); dErr != nil {
				return drained, dErr
			}
			drained++
			continue
		}
		status, _, postErr := f.postCloud(ctx, p.Method, p.Path, p.Headers, p.Body)
		if unreachable(status, postErr) {
			// Still down — back off and stop the batch (FIFO: don't skip ahead).
			backoff := time.Duration(m.Attempts+1) * time.Second
			if f.MaxBackoff > 0 && backoff > f.MaxBackoff {
				backoff = f.MaxBackoff
			}
			if err := f.Store.MarkAttempt(ctx, m.ID, backoff); err != nil {
				return drained, err
			}
			break
		}
		// Definitive response (2xx or a permanent 4xx) — the write is resolved.
		if err := f.Store.Delete(ctx, m.ID); err != nil {
			return drained, err
		}
		drained++
	}
	return drained, nil
}

// Depth is the current buffered-write count (for /healthz + metrics).
func (f *Forwarder) Depth(ctx context.Context) (int, error) {
	return f.Store.Depth(ctx)
}

// postCloud issues one request to the cloud edge-api and returns (status, body,
// err). A transport error yields (0, nil, err).
func (f *Forwarder) postCloud(
	ctx context.Context,
	method, path string,
	headers map[string]string,
	body []byte,
) (int, []byte, error) {
	if f.CloudBase == "" {
		return 0, nil, errors.New("writeforward: CloudBase not configured")
	}
	url := strings.TrimRight(f.CloudBase, "/") + path
	req, err := http.NewRequestWithContext(ctx, method, url, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	for _, h := range forwardHeaders {
		if v, ok := headers[h]; ok && v != "" {
			req.Header.Set(h, v)
		}
	}
	resp, err := f.Client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	return resp.StatusCode, respBody, nil
}
