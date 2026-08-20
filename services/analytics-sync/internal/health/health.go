// Package health serves /healthz. v1 is a plain 200; degraded-state
// reporting per ADR-0011 P0-4 can layer on top later.
package health

import (
	"encoding/json"
	"net/http"
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
