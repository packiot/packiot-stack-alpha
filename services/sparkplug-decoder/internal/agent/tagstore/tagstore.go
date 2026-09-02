// Package tagstore is the agent's last-value cache + report-by-exception
// (RBE) dirty set (ADR-0042 §2.2 net-new #3). SparkPlug NDATA should carry
// ONLY tags whose value changed since the last publish — RBE is what makes
// the alias-compressed DATA path ~4× smaller than a full snapshot and keeps a
// metered factory WAN cheap.
//
// The store is keyed by the tag's metric SUFFIX (the RawTag.Metric — the
// packml_topic prefix is applied later, in session.Publisher). Apply records
// a reading and reports whether it changed; Snapshot returns every current
// value (for NBIRTH — the full frozen table); DrainDirty returns just the
// changed-since-last-drain set and clears it (for NDATA).
package tagstore

import (
	"sort"
	"sync"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

// Store is the concurrent-safe last-value + dirty-set cache. Zero value is
// not ready — use New.
type Store struct {
	mu    sync.Mutex
	last  map[string]rawtag.RawTag // metric suffix → last applied reading
	dirty map[string]struct{}      // metric suffixes changed since last drain
}

// New constructs an empty Store.
func New() *Store {
	return &Store{
		last:  make(map[string]rawtag.RawTag),
		dirty: make(map[string]struct{}),
	}
}

// Apply records a reading and returns whether it CHANGED versus the last
// value for that metric (report-by-exception). A first-ever reading counts as
// changed. A changed reading joins the dirty set; an unchanged one is a no-op
// (this is the RBE filter — unchanged tags never reach NDATA). Value equality
// covers float64 / bool / string (the scalar shapes rawtag.Decode produces);
// a quality flip also counts as a change.
func (s *Store) Apply(t rawtag.RawTag) (changed bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	prev, ok := s.last[t.Metric]
	if ok && prev.Value == t.Value && prev.Quality == t.Quality {
		// Same value + same quality — update the timestamp silently but do
		// NOT mark dirty. (Keeping the fresh ts aids staleness diagnostics
		// without inflating NDATA.)
		prev.TsMillis = t.TsMillis
		s.last[t.Metric] = prev
		return false
	}
	s.last[t.Metric] = t
	s.dirty[t.Metric] = struct{}{}
	return true
}

// Snapshot returns every current value, sorted by metric suffix for
// deterministic NBIRTH construction (a stable order ⇒ a stable name↔alias
// allocation ⇒ byte-reproducible births). Powers the full BIRTH table.
func (s *Store) Snapshot() []rawtag.RawTag {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]rawtag.RawTag, 0, len(s.last))
	for _, t := range s.last {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Metric < out[j].Metric })
	return out
}

// SnapshotForBirth returns every current value (like Snapshot) AND clears the
// dirty set. A BIRTH freezes and conveys the FULL current table, so any
// pending report-by-exception change is subsumed — it must not also re-emit as
// NDATA right after. This is the snapshot source the uplink rebirth path uses;
// Snapshot (pure, non-mutating) stays for diagnostics/health.
func (s *Store) SnapshotForBirth() []rawtag.RawTag {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]rawtag.RawTag, 0, len(s.last))
	for _, t := range s.last {
		out = append(out, t)
	}
	s.dirty = make(map[string]struct{})
	sort.Slice(out, func(i, j int) bool { return out[i].Metric < out[j].Metric })
	return out
}

// DrainDirty returns the tags that changed since the last drain (sorted by
// metric suffix) and clears the dirty set. Powers NDATA — only report-by-
// exception changes cross the wire. An empty result means nothing changed
// this cycle (the agent skips the NDATA publish entirely).
func (s *Store) DrainDirty() []rawtag.RawTag {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.dirty) == 0 {
		return nil
	}
	out := make([]rawtag.RawTag, 0, len(s.dirty))
	for m := range s.dirty {
		out = append(out, s.last[m])
	}
	s.dirty = make(map[string]struct{})
	sort.Slice(out, func(i, j int) bool { return out[i].Metric < out[j].Metric })
	return out
}

// Len returns the number of distinct metrics tracked. Diagnostic only.
func (s *Store) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.last)
}
