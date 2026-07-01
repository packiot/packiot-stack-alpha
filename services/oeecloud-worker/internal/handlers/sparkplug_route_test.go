package handlers

import (
	"io"
	"log/slog"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// routeForSource is the ADR-0010 Phase 3 + ADR-0012 shadow routing table.
// The routes it returns are load-bearing: they decide whether every live
// Sparkplug envelope hits packiot public (production), packiot
// shadow_go_port (Phase 3 comparison), or packiot_shadow public (Phase
// 3 refactor POC). A wrong route silently writes to the wrong DB — no
// crash, no alert. So we test every case even though the function is
// tiny. Table lives in code review, not just in a comment.
func TestRouteForSource(t *testing.T) {
	// Non-nil sentinel pools — the routing table only cares which is
	// which, not that they're usable pgx pools. Real connection is
	// tested at integration level.
	mainPool := &pgxpool.Pool{}
	shadowPool := &pgxpool.Pool{}

	discardLogger := slog.New(slog.NewTextHandler(io.Discard, nil))

	tests := []struct {
		name           string
		sourceType     string
		shadowPool     *pgxpool.Pool
		wantMainPool   bool // true = expect main, false = expect shadow
		wantSchema     string
	}{
		{
			name:         "default source_type → main pool + public",
			sourceType:   "",
			shadowPool:   shadowPool,
			wantMainPool: true,
			wantSchema:   "public",
		},
		{
			name:         "source_type=go → main pool + shadow_go_port (ADR-0010)",
			sourceType:   "go",
			shadowPool:   shadowPool,
			wantMainPool: true,
			wantSchema:   "shadow_go_port",
		},
		{
			name:         "source_type=refactored + shadow configured → shadow pool + public (ADR-0012)",
			sourceType:   "refactored",
			shadowPool:   shadowPool,
			wantMainPool: false,
			wantSchema:   "public",
		},
		{
			name:         "source_type=refactored + shadow NOT configured → fallback main pool + public (fail-safe)",
			sourceType:   "refactored",
			shadowPool:   nil,
			wantMainPool: true,
			wantSchema:   "public",
		},
		{
			name:         "unknown source_type → fail-safe fallback",
			sourceType:   "bogus",
			shadowPool:   shadowPool,
			wantMainPool: true,
			wantSchema:   "public",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := &SparkplugHandler{
				pool:       mainPool,
				shadowPool: tt.shadowPool,
				logger:     discardLogger,
			}
			gotPool, gotSchema := h.routeForSource(tt.sourceType)
			gotIsMain := gotPool == mainPool
			if gotIsMain != tt.wantMainPool {
				t.Errorf("pool: got main=%v, want main=%v", gotIsMain, tt.wantMainPool)
			}
			if gotSchema != tt.wantSchema {
				t.Errorf("schema: got %q, want %q", gotSchema, tt.wantSchema)
			}
		})
	}
}
