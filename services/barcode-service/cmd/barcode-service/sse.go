// sse.go — a minimal in-memory Server-Sent-Events fan-out, scoped per
// production order AND per tenant.
//
// Phase-0 scope (deliberately small): a single-process, in-memory broker. Each
// GET /v1/scans/stream?id_production_order= subscriber gets a buffered channel;
// an accepted POST /v1/scans publishes the ScanResult to every subscriber of
// that PO whose tenant matches. Delivery is best-effort: if a slow client's
// buffer is full we DROP rather than block the write path — a live scan feed is
// advisory, and the durable truth is always in box_scans.
//
// TENANT ISOLATION: subscriptions carry the JWT-derived id_enterprise and only
// receive events published under the SAME enterprise, so knowing a PO id is not
// enough to snoop another tenant's feed.
//
// PHASE-2: for multi-replica delivery, back this with a broker (RabbitMQ
// fan-out or Postgres LISTEN/NOTIFY on a per-PO channel). The subscribe/publish
// seam here stays; only the transport changes.
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// subscriber is one live SSE connection's delivery channel + its tenant scope.
type subscriber struct {
	enterpriseID int
	ch           chan ScanResult
}

type sseBroker struct {
	mu     sync.RWMutex
	subs   map[int64]map[*subscriber]struct{} // id_production_order → set of subscribers
	closed bool
}

func newSSEBroker() *sseBroker {
	return &sseBroker{subs: make(map[int64]map[*subscriber]struct{})}
}

// subscribe registers a subscriber for a PO and returns its channel plus an
// unsubscribe func the handler MUST defer.
func (b *sseBroker) subscribe(idPO int64, enterpriseID int) (<-chan ScanResult, func()) {
	s := &subscriber{enterpriseID: enterpriseID, ch: make(chan ScanResult, 16)}
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		close(s.ch)
		return s.ch, func() {}
	}
	if b.subs[idPO] == nil {
		b.subs[idPO] = make(map[*subscriber]struct{})
	}
	b.subs[idPO][s] = struct{}{}
	b.mu.Unlock()

	return s.ch, func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		if set := b.subs[idPO]; set != nil {
			if _, ok := set[s]; ok {
				delete(set, s)
				close(s.ch)
			}
			if len(set) == 0 {
				delete(b.subs, idPO)
			}
		}
	}
}

// publish delivers res to every same-tenant subscriber of idPO. Non-blocking:
// a full buffer drops the event rather than stalling the writer.
func (b *sseBroker) publish(idPO int64, enterpriseID int, res ScanResult) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	for s := range b.subs[idPO] {
		if s.enterpriseID != enterpriseID {
			continue // tenant isolation
		}
		select {
		case s.ch <- res:
		default: // slow consumer — drop, don't block the write path
		}
	}
}

// Close tears down all subscriptions (graceful shutdown), unblocking every
// subscriber goroutine.
func (b *sseBroker) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return
	}
	b.closed = true
	for _, set := range b.subs {
		for s := range set {
			close(s.ch)
		}
	}
	b.subs = make(map[int64]map[*subscriber]struct{})
}

// handleStream is the SSE endpoint: GET /v1/scans/stream?id_production_order=.
// Behind the auth middleware, so the tenant is JWT-derived. Emits each accepted
// scan for the requested PO as an SSE `data:` frame, with a periodic heartbeat
// comment so proxies keep the connection open.
func (s *scanServer) handleStream(w http.ResponseWriter, r *http.Request) {
	enterpriseID, ok := enterpriseIDFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, `{"error":"missing tenant"}`)
		return
	}
	idPO, err := strconv.ParseInt(r.URL.Query().Get("id_production_order"), 10, 64)
	if err != nil || idPO <= 0 {
		writeJSON(w, http.StatusBadRequest, `{"error":"id_production_order query param required"}`)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, `{"error":"streaming unsupported"}`)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, ": connected\n\n")
	flusher.Flush()

	ch, unsubscribe := s.broker.subscribe(idPO, enterpriseID)
	defer unsubscribe()

	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()
	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case res, open := <-ch:
			if !open {
				return // broker closed (shutdown)
			}
			payload, _ := json.Marshal(res)
			fmt.Fprintf(w, "event: scan\ndata: %s\n\n", payload)
			flusher.Flush()
		case <-heartbeat.C:
			fmt.Fprint(w, ": heartbeat\n\n")
			flusher.Flush()
		}
	}
}
