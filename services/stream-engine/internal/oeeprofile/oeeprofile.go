// Package oeeprofile is the stream-engine (rollup) reader for the per-client OEE
// computation profile — WS3 Phase 2 / ADR-0058. WS3 Phase 1 taught the DECODER
// to read client_descriptors.descriptor->'oee_profile' (the spike_margin knob);
// this is the rollup-side counterpart, so the OEE-math knobs a CS engineer
// authors in the customize "OEE Computation" page (availability mode, ideal
// source, quality basis, stop threshold) drive the roll-up instead of the
// hardcoded env lists (COUNTERS_ONLY_LINE_LEAD_ENTERPRISES et al).
//
// The stream-engine has no per-enterprise loop — the rollup is bulk SQL over all
// tenants with the opted-in sets injected as int[] arrays built once at boot
// (main.go). This loader produces those same []int sets from the descriptor, so
// main.go can UNION them onto the env defaults: env stays the floor, a profile
// ADDS its enterprise, and a tenant without a profile changes nothing (parity).
//
// Phase 2a wires the LINE-LEAD availability set — the cleanest 1:1 per-enterprise
// mapping and the one CPACK/Bispharma actually use (availability_mode =
// count_silence ⇒ the tp=3 line derives gross/net/availability from its lead
// machine). Phase 2b (per-equipment availability opt-in expansion, quality_basis,
// stop_threshold_sec) rides the same loader once their consumption sites move off
// env — see the plan doc.
package oeeprofile

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// DefaultTTL matches shiftresolver's cache window and the decoder watcher's
// refresh — a CS profile edit takes effect on the next rollup tick after this,
// no worker redeploy.
const DefaultTTL = 5 * time.Minute

// profileQuery reads each enterprise's OEE profile from its descriptor. One row
// per enterprise that authored a profile; a tenant without one contributes no
// row, so its behavior stays exactly the env default (parity). id_enterprise is
// the descriptor's own key — no cross-tenant leakage.
const profileQuery = `
	SELECT cd.id_enterprise,
	       cd.descriptor->'oee_profile'->>'availability_mode' AS availability_mode,
	       cd.descriptor->'oee_profile'->>'ideal_source'      AS ideal_source
	  FROM client_descriptors cd
	 WHERE cd.descriptor->'oee_profile' IS NOT NULL`

// Sets are the resolved opted-in enterprise sets the rollup injects as int[]
// arrays. Extend this struct as Phase 2b migrates more knobs.
type Sets struct {
	// LineLeadEnterprises = enterprises whose profile selects line-metered
	// availability (availability_mode=count_silence OR ideal_source=lead_machine).
	// UNIONed onto CountersOnlyLineLeadEnterprises in main.go.
	LineLeadEnterprises []int
}

// Load runs the query against an existing pool and folds the rows into Sets.
// Split out so tests can drive it with a pool directly.
func Load(ctx context.Context, pool *pgxpool.Pool) (*Sets, error) {
	rows, err := pool.Query(ctx, profileQuery)
	if err != nil {
		return nil, fmt.Errorf("oee-profile: query: %w", err)
	}
	defer rows.Close()

	var lineLead []int
	seen := map[int]struct{}{}
	for rows.Next() {
		var (
			ent      int
			availMod *string
			idealSrc *string
		)
		if err := rows.Scan(&ent, &availMod, &idealSrc); err != nil {
			return nil, fmt.Errorf("oee-profile: scan: %w", err)
		}
		if wantsLineLead(availMod, idealSrc) {
			if _, dup := seen[ent]; !dup {
				lineLead = append(lineLead, ent)
				seen[ent] = struct{}{}
			}
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("oee-profile: iterate: %w", err)
	}
	return &Sets{LineLeadEnterprises: lineLead}, nil
}

// UnionInts returns the set union of a and b (order-stable on a, then b's
// new elements). Used by main.go to overlay a profile-derived opt-in set onto
// the env default without duplicating an enterprise already opted in via env.
func UnionInts(a, b []int) []int {
	seen := make(map[int]struct{}, len(a)+len(b))
	out := make([]int, 0, len(a)+len(b))
	for _, xs := range [][]int{a, b} {
		for _, x := range xs {
			if _, dup := seen[x]; dup {
				continue
			}
			seen[x] = struct{}{}
			out = append(out, x)
		}
	}
	return out
}

// wantsLineLead reports whether a profile selects line-metered availability.
// Pure so it is unit-testable without a DB.
func wantsLineLead(availabilityMode, idealSource *string) bool {
	return (availabilityMode != nil && *availabilityMode == "count_silence") ||
		(idealSource != nil && *idealSource == "lead_machine")
}

// Resolver caches the resolved Sets with a TTL, fail-open: a reload error keeps
// the previous snapshot (an empty Sets on the first failure), so a DB hiccup
// never blanks a live opt-in set the rollup depends on — it just leaves the env
// default in force. Mirrors shiftresolver.Resolver's ensureFresh pattern.
type Resolver struct {
	pool   *pgxpool.Pool
	ttl    time.Duration
	logger *slog.Logger

	mu       sync.RWMutex
	loadedAt time.Time
	sets     Sets
}

// New builds a Resolver. ttl<=0 uses DefaultTTL.
func New(pool *pgxpool.Pool, ttl time.Duration, logger *slog.Logger) *Resolver {
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Resolver{pool: pool, ttl: ttl, logger: logger}
}

// LineLeadEnterprises returns the current profile-opted line-lead enterprise set,
// refreshing the cache when stale. Fail-open: on a reload error it returns the
// previous snapshot (empty on first failure) so the caller falls back to env.
func (r *Resolver) LineLeadEnterprises(ctx context.Context) []int {
	r.ensureFresh(ctx)
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.sets.LineLeadEnterprises
}

func (r *Resolver) ensureFresh(ctx context.Context) {
	r.mu.RLock()
	fresh := !r.loadedAt.IsZero() && time.Since(r.loadedAt) < r.ttl
	r.mu.RUnlock()
	if fresh {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.loadedAt.IsZero() && time.Since(r.loadedAt) < r.ttl { // double-checked
		return
	}
	sets, err := Load(ctx, r.pool)
	if err != nil {
		r.logger.Warn("oee-profile: reload failed — keeping previous snapshot", slog.String("err", err.Error()))
		return
	}
	r.sets = *sets
	r.loadedAt = time.Now()
}
