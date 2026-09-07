// Package unmapped is the sparkplug-agent's "reject-don't-drop" observer for
// raw tags whose suffix is NOT in the agent's raw_tag_map (ADR-0045 §2.4a P0).
//
// Why it exists: the agent's raw_tag_map is a strict allowlist and that
// strictness is CORRECT — a stray PO-control write must never masquerade as a
// Calc seed (ADR-0044 §2), and the agent cannot assign a SparkPlug type to a
// tag it does not know, so an unmapped tag genuinely cannot be PUBLISHED. The
// bug was never the drop; it was the SILENCE. During the CPACK go-live a wrong
// inferred count index (`/…/ProdProcessedCount/<idx>/Unit`) meant a machine's
// counts matched nothing in the allowlist and simply VANISHED with no signal —
// exactly what made L6 (#601) so hard to debug.
//
// This Reporter turns every such drop into an observable, throttled, and
// (optionally) enumerable event WITHOUT changing the drop decision itself:
//
//   - Metric: sparkplug_agent_unmapped_tags_total{group,segment,reason} — a
//     nonzero rate during onboarding says "a tag arrived that maps to nothing;
//     its data is disappearing." Bounded cardinality: labelled by the
//     line/machine SEGMENT (first path element, e.g. "L8"), never the full
//     suffix, so a stray high-cardinality topic can't blow up the series.
//   - Log: one WARN per DISTINCT suffix, THROTTLED (default once/hour per
//     suffix — the shape-adapter cadence) so a steady-state stream of the same
//     unmapped tag prints once, not once-per-message. The line carries the FULL
//     offending suffix + group so it is immediately actionable.
//   - Verbose mode (opt-in, default off): accumulate the DISTINCT set of
//     unmapped suffixes + per-suffix counts and expose them on /healthz. This
//     is the onboarding index-capture aid — one GET dumps "every topic the tee
//     sent that the map doesn't cover," which is precisely the artifact an
//     onboarding engineer needs to author the missing raw_tag_map entries.
//
// Steady-state discipline: Observe does O(1) work (one map probe + one counter
// inc); it never logs per-message and, in non-verbose mode, never accumulates
// the per-suffix list. Memory is bounded by the number of DISTINCT unmapped
// suffixes — the same order as the tag_map itself (tens–hundreds), not the
// message rate — so no eviction is needed.
package unmapped

import (
	"log/slog"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// ReasonUnknownTopic is the only reason P0 can distinguish: the tag's suffix is
// not an allowlist entry. ADR-0045 §2.4a foresees a richer taxonomy
// (malformed | no_param_id | index_mismatch) once the agent parses param IDs;
// the reason label is present now so those land without a metric rename.
const ReasonUnknownTopic = "unknown_topic"

// DefaultLogWindow throttles the per-suffix WARN to once/hour — the same
// cadence the shape-adapter used for its "topic shape changed" notice. Long
// enough that a steady stream of one unmapped tag is a single line per hour;
// short enough that the signal re-surfaces for an engineer who wasn't watching
// when it first fired.
const DefaultLogWindow = time.Hour

// Reporter observes raw tags the agent's raw_tag_map does not cover. It is safe
// for concurrent use (the MQTT subscriber and the HTTP front-door both call
// Observe). The zero value is not ready — use New.
type Reporter struct {
	group   string
	counter *prometheus.CounterVec // labels: group, segment, reason
	logger  *slog.Logger
	verbose bool
	window  time.Duration // <=0 ⇒ log once per distinct suffix for process life

	// now is the clock, injectable so tests can drive the throttle window
	// without sleeping.
	now func() time.Time

	mu       sync.Mutex
	lastLog  map[string]time.Time // suffix → last WARN time (throttle bookkeeping)
	distinct map[string]int64     // suffix → observed count (verbose mode only)
	total    int64                // total unmapped observations (all suffixes)
}

// New builds a Reporter for tenant `group`. counter may be nil (tests);
// window <=0 selects "log once per distinct suffix, ever." When verbose is
// true the Reporter accumulates the distinct suffix set for /healthz exposure.
func New(group string, counter *prometheus.CounterVec, logger *slog.Logger, verbose bool, window time.Duration) *Reporter {
	if logger == nil {
		logger = slog.Default()
	}
	return &Reporter{
		group:    group,
		counter:  counter,
		logger:   logger,
		verbose:  verbose,
		window:   window,
		now:      time.Now,
		lastLog:  make(map[string]time.Time),
		distinct: make(map[string]int64),
	}
}

// Observe records one unmapped raw tag by its metric SUFFIX. It always bumps
// the metric; it logs a WARN only when the per-suffix throttle allows; it
// accumulates the suffix only in verbose mode. Cheap and per-message-safe.
func (r *Reporter) Observe(suffix string) {
	seg := segmentOf(suffix)
	if r.counter != nil {
		r.counter.WithLabelValues(r.group, seg, ReasonUnknownTopic).Inc()
	}

	r.mu.Lock()
	r.total++
	if r.verbose {
		r.distinct[suffix]++
	}
	shouldLog := r.shouldLogLocked(suffix)
	r.mu.Unlock()

	if shouldLog {
		r.logger.Warn("unmapped raw tag dropped — suffix not in raw_tag_map, cannot be published (ADR-0045 P0)",
			slog.String("group", r.group),
			slog.String("suffix", suffix),
			slog.String("segment", seg),
			slog.String("reason", ReasonUnknownTopic))
	}
}

// shouldLogLocked returns whether a WARN should fire for this suffix now,
// updating the throttle bookkeeping. Caller holds r.mu. First sight of a suffix
// always logs. Thereafter: window<=0 ⇒ never again; window>0 ⇒ again once the
// window has elapsed. Either way lastLog gains an entry per distinct suffix, so
// its size (and thus memory) is bounded by the distinct-suffix cardinality.
func (r *Reporter) shouldLogLocked(suffix string) bool {
	now := r.now()
	last, seen := r.lastLog[suffix]
	if seen {
		if r.window <= 0 || now.Sub(last) < r.window {
			return false
		}
	}
	r.lastLog[suffix] = now
	return true
}

// segmentOf extracts the line/machine segment from a tag suffix for use as a
// BOUNDED metric label. A CPACK suffix looks like "/L8/Status/MachSpeed" or
// "/L8/Admin/ProdProcessedCount/51/Unit"; both yield "L8". Extracting the first
// non-empty path element caps the label's cardinality at the number of lines/
// machines — never the (potentially unbounded) full-suffix space. A suffix with
// no usable element degrades to "unknown" rather than leaking a raw string.
func segmentOf(suffix string) string {
	for _, part := range strings.Split(suffix, "/") {
		if p := strings.TrimSpace(part); p != "" {
			return p
		}
	}
	return "unknown"
}

// --- health.ComponentSnapshotter -------------------------------------------
//
// The Reporter surfaces on /healthz so an onboarding engineer can pull the
// diagnostic without a Prometheus round-trip. It NEVER degrades health: an
// unmapped tag is a provisioning signal, not a service fault (Degraded()=="").

// Component is the /healthz key for this diagnostic.
func (r *Reporter) Component() string { return "unmapped_tags" }

// SnapshotDetail returns the diagnostic body. Totals are always present; the
// full distinct suffix list is included ONLY in verbose mode (bounded-memory
// discipline) — the onboarding index-capture aid.
func (r *Reporter) SnapshotDetail() any {
	r.mu.Lock()
	defer r.mu.Unlock()

	detail := map[string]any{
		"group":                  r.group,
		"total_dropped":          r.total,
		"distinct_suffixes_seen": len(r.lastLog),
		"verbose":                r.verbose,
	}
	if r.verbose {
		suffixes := make([]string, 0, len(r.distinct))
		for s := range r.distinct {
			suffixes = append(suffixes, s)
		}
		sort.Strings(suffixes) // deterministic output for diffable DQ reports
		list := make([]map[string]any, 0, len(suffixes))
		for _, s := range suffixes {
			list = append(list, map[string]any{"suffix": s, "count": r.distinct[s]})
		}
		detail["unmapped_suffixes"] = list
	}
	return detail
}

// Degraded always returns "" — unmapped tags are a diagnostic, not a fault.
func (r *Reporter) Degraded() string { return "" }

// Distinct returns the sorted set of distinct unmapped suffixes seen. In
// verbose mode this is the full accumulated set; otherwise it reflects the
// throttle-bookkeeping keys (still every distinct suffix, just without counts).
// Exposed for tests and ad-hoc debug dumps.
func (r *Reporter) Distinct() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var src map[string]int64
	if r.verbose {
		src = r.distinct
	}
	set := make(map[string]struct{}, len(r.lastLog))
	for s := range r.lastLog {
		set[s] = struct{}{}
	}
	for s := range src {
		set[s] = struct{}{}
	}
	out := make([]string, 0, len(set))
	for s := range set {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}
