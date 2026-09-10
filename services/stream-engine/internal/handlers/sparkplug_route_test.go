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
// shadow_go_port (Phase 3 comparison), or packiot_analytics public (Phase
// 3 refactor POC). A wrong route silently writes to the wrong DB — no
// crash, no alert. So we test every case even though the function is
// tiny. Table lives in code review, not just in a comment.
func TestRouteForSource(t *testing.T) {
	// Non-nil sentinel pools — the routing table only cares which is
	// which, not that they're usable pgx pools. Real connection is
	// tested at integration level.
	mainPool := &pgxpool.Pool{}
	analyticsPool := &pgxpool.Pool{}

	discardLogger := slog.New(slog.NewTextHandler(io.Discard, nil))

	tests := []struct {
		name          string
		sourceType    string
		analyticsPool *pgxpool.Pool
		wantMainPool  bool // true = expect main, false = expect shadow
		wantSilver    string
		wantBronze    string
		wantEv        string
	}{
		{
			name:          "default source_type → main pool + all public",
			sourceType:    "",
			analyticsPool: analyticsPool,
			wantMainPool:  true,
			wantSilver:    "public",
			wantBronze:    "public",
			wantEv:        "public",
		},
		{
			// t231 medallion split: facts→silver, raw→bronze, DQ/PO→public.
			name:          "source_type=refactored + shadow configured → analytics pool + medallion layers (t231)",
			sourceType:    "refactored",
			analyticsPool: analyticsPool,
			wantMainPool:  false,
			wantSilver:    "silver",
			wantBronze:    "bronze",
			wantEv:        "public",
		},
		{
			name:          "source_type=refactored + shadow NOT configured → fallback main pool + all public (fail-safe)",
			sourceType:    "refactored",
			analyticsPool: nil,
			wantMainPool:  true,
			wantSilver:    "public",
			wantBronze:    "public",
			wantEv:        "public",
		},
		{
			name:          "unknown source_type → fail-safe fallback (all public)",
			sourceType:    "bogus",
			analyticsPool: analyticsPool,
			wantMainPool:  true,
			wantSilver:    "public",
			wantBronze:    "public",
			wantEv:        "public",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := &SparkplugHandler{
				pool:          mainPool,
				analyticsPool: tt.analyticsPool,
				logger:        discardLogger,
			}
			r := h.routeForSource(tt.sourceType)
			gotIsMain := r.pool == mainPool
			if gotIsMain != tt.wantMainPool {
				t.Errorf("pool: got main=%v, want main=%v", gotIsMain, tt.wantMainPool)
			}
			if r.silver != tt.wantSilver {
				t.Errorf("silver: got %q, want %q", r.silver, tt.wantSilver)
			}
			if r.bronze != tt.wantBronze {
				t.Errorf("bronze: got %q, want %q", r.bronze, tt.wantBronze)
			}
			if r.ev != tt.wantEv {
				t.Errorf("ev: got %q, want %q", r.ev, tt.wantEv)
			}
		})
	}
}
