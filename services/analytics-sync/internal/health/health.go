// Package health serves /healthz.
//
// Handler() is the plain-200 liveness probe (HTTP server is up). It is still
// used by services whose only failure mode is "process/HTTP dead" (shadow-mirror,
// and any idle no-op mode).
//
// Checker adds staleness detection for long-running poll loops: the loop stamps
// a heartbeat every successful iteration and /healthz returns 503 once the
// heartbeat is older than maxAge. This is what lets the docker healthcheck flag
// a *wedged loop* (deadlock, hung DB call, dead goroutine) — a plain 200 never
// can, because the HTTP server keeps answering while the loop is stuck. This is
// the "green healthcheck != working loop" trap.
package health

import (
	"encoding/json"
	"net/http"
	"sync/atomic"
	"time"
)

func Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"service": "analytics-sync",
			"healthy": true,
		})
	}
}

// Checker is a heartbeat-backed health source. maxAge <= 0 disables the
// staleness check (Handler behaves like the plain always-200 probe), so it is
// safe to adopt without changing behaviour until a positive maxAge is set.
type Checker struct {
	service  string
	maxAge   time.Duration
	lastBeat atomic.Int64 // unix nanoseconds of the last successful loop iteration
}

// NewChecker starts the heartbeat at "now" so a slow first poll (cold-start
// backfill) does not trip the check before the loop's first beat.
func NewChecker(service string, maxAge time.Duration) *Checker {
	c := &Checker{service: service, maxAge: maxAge}
	c.lastBeat.Store(time.Now().UnixNano())
	return c
}

// Beat records a successful loop iteration. Cheap and lock-free — safe to call
// on the hot path every poll.
func (c *Checker) Beat() { c.lastBeat.Store(time.Now().UnixNano()) }

// Handler reports 200 while the last heartbeat is within maxAge, else 503.
func (c *Checker) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		age := time.Since(time.Unix(0, c.lastBeat.Load()))
		healthy := c.maxAge <= 0 || age <= c.maxAge
		w.Header().Set("Content-Type", "application/json")
		if healthy {
			w.WriteHeader(http.StatusOK)
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"service":           c.service,
			"healthy":           healthy,
			"last_beat_age_sec": age.Seconds(),
			"max_age_sec":       c.maxAge.Seconds(),
		})
	}
}
