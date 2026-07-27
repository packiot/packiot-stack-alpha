// Package numeric is the STACK-SIDE numeric-count-index TRANSLATION LAYER
// (ADR-0045 §2.3 Option-B, the USER "proper translation layer" directive):
// it turns a legacy pre-SparkPlug edge's numeric-counter payload —
// `counterData[{id,value}]`, a bare integer channel id + an absolute
// totalizer — into the platform's canonical SparkPlug metrics, so a
// counters-only tenant that speaks NO topic strings at all still feeds the one
// ingest contract every other tenant does (ADR-0032).
//
// The seam it closes
// ------------------
// The bispharma / bisnago legacy flows (PR #632/#633) are the pre-SparkPlug
// numeric-counter model: the edge emits DINT counter values keyed by a numeric
// id (bispharma 124..685; bisnago 670..683), and NO topic strings — the
// count-id → equipment/line/metric mapping historically lived in a cloud DB.
// The canonical model (docs/clients/bispharma-bisnago-canonical-model.md §2.1)
// resolves this as a SYNTHESIZE: a `count-id → (canonical line/member, count
// leaf, idx)` table the new edge applies to build the canonical topic.
//
// This package puts that SYNTHESIZE STACK-SIDE, in the Go agent, exactly where
// ADR-0045 §2.3 puts every other tenant's normalization. The tee stays a DUMB
// forwarder (it spells no canonical name — it forwards raw `{id,value}` facts);
// the agent owns the numeric-id → canonical-metric translation. That makes the
// translation a versioned, tested stack artifact reusable for EVERY numeric-
// counter client, instead of a bespoke transform re-typed into each factory's
// low-code flow.
//
// How the translation table is derived (max-reuse, zero new data)
// ---------------------------------------------------------------
// The agent already builds its raw_tag_map (allowlist of canonical metric
// SUFFIXES) from the tenant profile / packml_register — and for a numeric-
// counter tenant every count leaf is `.../<...Count>/<idx>/Unit`, where <idx>
// is precisely the descriptor's `count_index.value` = the legacy numeric id the
// tee forwards. So the numeric→canonical table is NOT new data: it is a pure
// function of the finalized raw_tag_map, obtained by extracting the count index
// out of each count-leaf suffix (BuildIndexFromTagMap). This guarantees by
// construction that every translated tag lands on a suffix the resolver already
// accepts — a translated tag can never be dropped as unmapped for a reason the
// raw_tag_map didn't already surface.
//
// Absolute totalizer, not delta
// ------------------------------
// The legacy flow also computes a per-poll `increment` (a delta). We IGNORE it
// and forward the ABSOLUTE `value`. The new stack recomputes its own delta and
// applies the ADR-0037 per-equipment production-increment SANITY CLAMP (#622),
// so delta ownership stays in ONE place (the Silver invariant), never split
// across the edge and the stack.
package numeric

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
)

// Counter is one legacy numeric-counter reading as the dumb tee forwards it:
// a bare channel id + the ABSOLUTE totalizer value. Optional quality/timestamp
// mirror the rawtag envelope's per-tag overrides.
type Counter struct {
	ID    int     `json:"id"`
	Value float64 `json:"value"`
	Q     *bool   `json:"q,omitempty"`  // absent ⇒ good
	TS    int64   `json:"ts,omitempty"` // per-counter ts override of the envelope ts
}

// Target is the canonical metric a legacy count id resolves to: the SparkPlug
// metric SUFFIX (packml prefix prepended downstream, exactly like a rawtag) and
// its SparkPlug datatype token.
type Target struct {
	Suffix string
	Type   string
}

// Translator maps legacy numeric count ids → canonical rawtag metrics. It is
// immutable after construction; safe for concurrent Translate calls.
type Translator struct {
	byIndex map[int]Target
}

// NewTranslator builds a translator from an explicit index→target table. Callers
// that already hold the table (tests) use this; the agent uses
// BuildIndexFromTagMap to derive it from its finalized raw_tag_map.
func NewTranslator(byIndex map[int]Target) *Translator {
	m := make(map[int]Target, len(byIndex))
	for k, v := range byIndex {
		m[k] = v
	}
	return &Translator{byIndex: m}
}

// Len is the number of translatable count indices (a diagnostic the agent logs
// at startup so a mis-derived empty table is loud, not silent).
func (t *Translator) Len() int { return len(t.byIndex) }

// Indices returns the sorted set of known count indices (diagnostics / DQ).
func (t *Translator) Indices() []int {
	out := make([]int, 0, len(t.byIndex))
	for k := range t.byIndex {
		out = append(out, k)
	}
	sort.Ints(out)
	return out
}

// Translate converts a batch of numeric counters into canonical rawtags. Each
// mapped id becomes a RawTag carrying the ABSOLUTE value (the stack derives the
// delta). endpoint stamps the rawtag's EndpointOrPath (diagnostic); scanTS is
// the envelope timestamp used when a counter omits its own. Unmapped ids are
// returned (sorted, deduped) so the caller can surface them as an onboarding DQ
// signal (ADR-0045 §2.4a "reject-don't-drop") rather than silently vanish them.
func (t *Translator) Translate(counters []Counter, endpoint string, scanTS int64) (tags []rawtag.RawTag, unmapped []int) {
	var unmappedSet map[int]struct{}
	for _, c := range counters {
		tgt, ok := t.byIndex[c.ID]
		if !ok {
			if unmappedSet == nil {
				unmappedSet = map[int]struct{}{}
			}
			unmappedSet[c.ID] = struct{}{}
			continue
		}
		q := true
		if c.Q != nil {
			q = *c.Q
		}
		ts := c.TS
		if ts == 0 {
			ts = scanTS
		}
		tags = append(tags, rawtag.RawTag{
			EndpointOrPath: endpoint,
			Metric:         tgt.Suffix,
			Value:          c.Value, // ABSOLUTE totalizer; delta + sanity-clamp derived stack-side (#622)
			Type:           tgt.Type,
			TsMillis:       ts,
			Quality:        q,
		})
	}
	if len(unmappedSet) > 0 {
		unmapped = make([]int, 0, len(unmappedSet))
		for id := range unmappedSet {
			unmapped = append(unmapped, id)
		}
		sort.Ints(unmapped)
	}
	return tags, unmapped
}

// BuildIndexFromTagMap derives the numeric-id → canonical-metric table from a
// finalized agent raw_tag_map. A count-leaf suffix has the canonical shape
// `.../<X>Count/<idx>/Unit` (ADR-0045 §2.1 metric templates: ProdProcessedCount
// / ProdConsumedCount / ProdDefectiveCount). For every such entry it extracts
// the integer <idx> and maps it to that suffix + type. A suffix that is not a
// count leaf (MachSpeed, StateCurrent, Parameter30700, or a bare line count with
// no idx) is skipped — those are not numeric-id-routable.
//
// It is STRICT on collisions: two count leaves claiming the SAME index is a
// descriptor bug (a numeric id must resolve to exactly one canonical metric), so
// it errors rather than silently pick one — the same fail-closed discipline the
// register loader uses. An empty result (no count leaves at all) is NOT an error
// here (a tenant may legitimately have none); the agent decides whether that is
// fatal for its numeric-ingest mode.
func BuildIndexFromTagMap(entries []agentcfg.TagMapEntry) (map[int]Target, error) {
	out := map[int]Target{}
	for _, e := range entries {
		idx, ok := countIndexOf(e.MetricSuffix)
		if !ok {
			continue
		}
		if prev, dup := out[idx]; dup {
			return nil, fmt.Errorf("numeric: count index %d claimed by two metrics (%q and %q) — a numeric id must map to exactly one canonical metric",
				idx, prev.Suffix, e.MetricSuffix)
		}
		out[idx] = Target{Suffix: e.MetricSuffix, Type: e.Type}
	}
	return out, nil
}

// countIndexOf extracts the count index from a canonical count-leaf suffix. It
// returns (idx, true) only for a suffix whose last segment is "Unit", whose
// penultimate segment is a non-negative integer, and whose ante-penultimate
// segment ends in "Count" (the ProdProcessedCount / ProdConsumedCount /
// ProdDefectiveCount family). Anything else → (0, false).
func countIndexOf(suffix string) (int, bool) {
	segs := strings.Split(suffix, "/")
	if len(segs) < 3 {
		return 0, false
	}
	if segs[len(segs)-1] != "Unit" {
		return 0, false
	}
	if !strings.HasSuffix(segs[len(segs)-3], "Count") {
		return 0, false
	}
	idx, err := strconv.Atoi(segs[len(segs)-2])
	if err != nil || idx < 0 {
		return 0, false
	}
	return idx, true
}

// DecodeEnvelope parses a numeric-counter POST body into its metadata + a flat
// list of counters. It accepts BOTH shapes the legacy flows emit:
//
//	{ "group": "...", "gateway": "...", "timestamp": <ms>,
//	  "counterData": [ {"id":164,"value":12345}, ... ] }
//
// and the nested form the bisnago flow wraps per endpoint:
//
//	{ ..., "counters": [ { "endpoint":"L71", "counterData":[ ... ] }, ... ] }
//
// Both are flattened into one []Counter; the per-endpoint form preserves the
// endpoint on each counter so diagnostics can attribute an unmapped id. Unknown
// keys are ignored (a tee may stamp extra provenance).
func DecodeEnvelope(body []byte) (*Envelope, []Counter, error) {
	var env Envelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, nil, fmt.Errorf("numeric: decode envelope (%d bytes): %w", len(body), err)
	}
	flat := make([]Counter, 0, len(env.CounterData))
	flat = append(flat, env.CounterData...)
	for _, grp := range env.Counters {
		flat = append(flat, grp.CounterData...)
	}
	return &env, flat, nil
}

// Envelope is the on-wire numeric-counter body (a superset of both flow shapes).
type Envelope struct {
	Group       string         `json:"group,omitempty"`
	GroupID     string         `json:"group_id,omitempty"`
	Tenant      string         `json:"tenant,omitempty"`
	Gateway     string         `json:"gateway,omitempty"`
	Endpoint    string         `json:"endpoint,omitempty"`
	Timestamp   int64          `json:"timestamp,omitempty"`
	ScanTS      int64          `json:"scan_ts,omitempty"`
	CounterData []Counter      `json:"counterData,omitempty"`
	Counters    []CounterGroup `json:"counters,omitempty"`
}

// CounterGroup is one endpoint's counter batch in the nested envelope form.
type CounterGroup struct {
	Endpoint    string    `json:"endpoint,omitempty"`
	CounterData []Counter `json:"counterData,omitempty"`
}

// EnvelopeTS returns the best-available envelope timestamp (timestamp, then
// scan_ts, then 0 ⇒ caller falls back to now).
func (e *Envelope) EnvelopeTS() int64 {
	if e.Timestamp != 0 {
		return e.Timestamp
	}
	return e.ScanTS
}
