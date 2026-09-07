// Package counterderive is the agent-side COUNTER-DERIVE stage (ADR-0045): it
// turns the per-count `counter_derive` config a CS engineer DECLARES on a tag map
// into the gross/net/scrap SparkPlug counts the cloud Calc consumes — replacing
// the hand-written CPACK `Calc_Counters` Node-RED function with declared config.
//
// The problem it solves
// ---------------------
// A factory rarely senses all three OEE counts. It might have only an outfeed
// sensor (gross), only an infeed sensor (net), or gross+net but no scrap counter.
// The legacy answer was a bespoke Node-RED function per client that filled in the
// missing counts by hand. ADR-0045 makes that a CLOSED ENUM the descriptor
// declares (clientconfig.CounterDerive*), and this stage applies it.
//
// Where it runs (and why the agent, not the reader/cloud)
// -------------------------------------------------------
// It sits in the agent ingest path next to the integral/sum deriver
// (internal/agent/deriver): after the raw count tags a reader/tee forwards are
// decoded, before they resolve+publish. The agent is the ONE correlation point
// that sees every tenant's counts as canonical suffixes regardless of which
// reader produced them (Go s7/modbus/opcua-reader OR the dumb Node-RED tee), so
// the reader stays a dumb physical-tag forwarder and the cloud edge-transformer +
// Calc stay generic (they see only canonical counts, ADR-0032 one-ingest-contract).
//
// How it correlates a count group
// -------------------------------
// A member's gross/net/scrap share ONE count index, differing only by the
// canonical leaf: /…/ProdConsumedCount/<idx>/Unit (gross), /…/ProdProcessedCount/
// <idx>/Unit (net), /…/ProdDefectiveCount/<idx>/Unit (scrap). So a group key is
// (everything-before-the-leaf, idx), and the three sibling suffixes are
// reconstructed by swapping the leaf token — no template lookup needed. The stage
// reads the sensed sibling(s) that arrived in the batch, runs Apply, and
// synthesizes the derived sibling(s) at their (leaf-swapped) suffix.
//
// Statelessness (and the one gap it can't close)
// ----------------------------------------------
// Apply is a PURE, stateless function of the counts present this batch. The
// legacy Calc_Counters was almost entirely stateless too — EXCEPT the rare
// `outfeed_derived` case, whose real formula (net := gross - 2*scrap - in_scrap +
// prev_scrap) carries per-tick state (in_scrap / prev_scrap). Apply implements a
// documented best-effort approximation there; see Apply's comment.
package counterderive

import (
	"fmt"
	"math"
	"regexp"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

// Mode tokens — the closed counter_derive enum. They MIRROR the canonical
// clientconfig.CounterDerive* constants (which the schema + loader own); they are
// duplicated here rather than imported so this agent-runtime package does not
// depend on the reader-config package (matching how agentcfg duplicates the
// SparkPlug type tokens instead of importing clientconfig).
const (
	ModeFull           = "full"
	ModeOutfeedOnly    = "outfeed_only"
	ModeInfeedOnly     = "infeed_only"
	ModeScrapDerived   = "scrap_derived"
	ModeGrossDerived   = "gross_derived"
	ModeOutfeedDerived = "outfeed_derived"
	ModeNone           = "none"
)

// Apply derives the missing counts IN PLACE per the counter_derive mode. On
// entry the sensed slots (per the mode) hold the values read this batch; Apply
// overwrites the derived slots. It is the single source of the exact arithmetic
// decoded from CPACK's Calc_Counters:
//
//	full / none          — no derivation (all sensed / not a counter).
//	outfeed_only         — gross sensed → net := gross;         scrap := 0.
//	infeed_only          — net   sensed → gross := net;         scrap := 0.
//	scrap_derived        — gross+net    → scrap := gross - net  (floored at 0).
//	gross_derived        — net+scrap    → gross := net + scrap.
//	outfeed_derived      — gross+scrap  → net := max(gross - scrap, 0)  [APPROXIMATION].
//
// An unknown mode is an error (the loader's closed-enum lint prevents it
// upstream; this is belt-and-braces so a hand-built call can't silently no-op).
func Apply(gross, net, scrap *float64, mode string) error {
	switch mode {
	case "", ModeFull, ModeNone:
		// full: every count sensed, nothing to derive. none: not a counter.
		return nil
	case ModeOutfeedOnly:
		// One sensor on the outfeed measures the total off the machine (gross);
		// with no scrap detector, all of it is treated as good (net) and scrap=0.
		*net = *gross
		*scrap = 0
	case ModeInfeedOnly:
		// One sensor on the infeed measures what entered (net, in this platform's
		// leaf naming); with no scrap detector gross := net and scrap := 0.
		*gross = *net
		*scrap = 0
	case ModeScrapDerived:
		// Gross+net sensed, no scrap counter: the shortfall IS the scrap. Floor at
		// 0 so a transient net>gross (out-of-order totalizers) can't emit negative
		// scrap, which would read as a counter reset to Calc.
		s := *gross - *net
		if s < 0 {
			s = 0
		}
		*scrap = s
	case ModeGrossDerived:
		// Net+scrap sensed, no gross counter: gross is their sum by definition.
		*gross = *net + *scrap
	case ModeOutfeedDerived:
		// ⚠ APPROXIMATION. The legacy CPACK formula is STATEFUL:
		//     net := gross - 2*scrap - in_scrap + prev_scrap
		// where in_scrap / prev_scrap are per-tick carried state (rare — x1 in
		// CPACK). A stateless Apply cannot replicate the in_scrap/prev_scrap terms,
		// so this is a documented best-effort: net := max(gross - scrap, 0). Flagged
		// so a correctness audit knows exactly which case diverges from legacy.
		n := *gross - *scrap
		if n < 0 {
			n = 0
		}
		*net = n
	default:
		return fmt.Errorf("counterderive: unknown mode %q", mode)
	}
	return nil
}

// role identifies one of the three canonical OEE counts within a group. The
// platform's leaf naming is counter-intuitive (see oeecloud-worker parse.go):
// ProdConsumedCount = gross (total in), ProdProcessedCount = net (good out),
// ProdDefectiveCount = scrap.
type role int

const (
	roleGross role = iota // ProdConsumedCount
	roleNet               // ProdProcessedCount
	roleScrap             // ProdDefectiveCount
)

// leafWord is the count-leaf token for each role, the substring swapped to move
// between sibling suffixes of one group.
var leafWord = map[role]string{
	roleGross: "Consumed",
	roleNet:   "Processed",
	roleScrap: "Defective",
}

// modeSpec declares, per mode, which roles are SENSED (must be present this batch
// for a derivation to fire) and which are DERIVED (synthesized). full/none are
// absent — they derive nothing, so a group carrying only those never builds.
type modeSpec struct {
	sensed  []role
	derived []role
}

var modeSpecs = map[string]modeSpec{
	ModeOutfeedOnly:    {sensed: []role{roleGross}, derived: []role{roleNet, roleScrap}},
	ModeInfeedOnly:     {sensed: []role{roleNet}, derived: []role{roleGross, roleScrap}},
	ModeScrapDerived:   {sensed: []role{roleGross, roleNet}, derived: []role{roleScrap}},
	ModeGrossDerived:   {sensed: []role{roleNet, roleScrap}, derived: []role{roleGross}},
	ModeOutfeedDerived: {sensed: []role{roleGross, roleScrap}, derived: []role{roleNet}},
}

// countLeaf parses a canonical count suffix into (head, role, idx). It matches
// only the three OEE count leaves; a non-count suffix (speed, state, …) returns
// ok=false and is ignored. head is everything before "/Prod<Role>Count", idx is
// the count-index string (kept as a string — it is only ever re-emitted verbatim).
var countLeaf = regexp.MustCompile(`^(.*)/Prod(Consumed|Processed|Defective)Count/(\d+)/Unit$`)

func parseCountLeaf(suffix string) (head string, r role, idx string, ok bool) {
	m := countLeaf.FindStringSubmatch(suffix)
	if m == nil {
		return "", 0, "", false
	}
	switch m[2] {
	case "Consumed":
		r = roleGross
	case "Processed":
		r = roleNet
	case "Defective":
		r = roleScrap
	}
	return m[1], r, m[3], true
}

// siblingSuffix reconstructs the group's suffix for role r from the shared
// (head, idx) — the leaf-swap that ties gross/net/scrap of one member together.
func siblingSuffix(head string, r role, idx string) string {
	return fmt.Sprintf("%s/Prod%sCount/%s/Unit", head, leafWord[r], idx)
}

// Entry is one count-tag declaration the stage is built from: a full metric
// SUFFIX and the counter_derive mode carried on it. Suffixes whose mode is
// empty/full/none contribute no derivation; non-count suffixes are ignored.
type Entry struct {
	Suffix string
	Mode   string
}

// group is one (head, idx) count family + its derivation mode, precompiled to the
// three sibling suffixes so Process does no per-batch parsing.
type group struct {
	mode     string
	suffixes [3]string // indexed by role
}

// Stage holds the compiled derive groups. Like the sibling deriver it is NOT safe
// for concurrent use — the agent ingest is single-writer per envelope.
type Stage struct {
	groups []*group
	// bySuffix routes an arriving count suffix to (group, role) in O(1).
	bySuffix map[string]suffixRef
}

type suffixRef struct {
	g *group
	r role
}

// New compiles a Stage from the count-tag entries. Entries with a no-op mode
// (empty/full/none, or any mode not in modeSpecs) are skipped, so a tenant with
// no counter_derive declarations yields an empty Stage whose Process is a no-op —
// building it unconditionally costs nothing. Entries are grouped by (head, idx);
// a group takes the mode of its first deriving entry (all tags of one group
// declare the same mode by construction — it describes the group, not the tag).
func New(entries []Entry) *Stage {
	s := &Stage{bySuffix: map[string]suffixRef{}}
	byKey := map[string]*group{}
	for _, e := range entries {
		if _, ok := modeSpecs[e.Mode]; !ok {
			continue // full/none/empty/unknown → derives nothing
		}
		head, _, idx, ok := parseCountLeaf(e.Suffix)
		if !ok {
			continue // a counter_derive on a non-count suffix is meaningless; ignore
		}
		key := head + "\x00" + idx
		g := byKey[key]
		if g == nil {
			g = &group{mode: e.Mode}
			for r := roleGross; r <= roleScrap; r++ {
				g.suffixes[r] = siblingSuffix(head, r, idx)
			}
			byKey[key] = g
			s.groups = append(s.groups, g)
			for r := roleGross; r <= roleScrap; r++ {
				s.bySuffix[g.suffixes[r]] = suffixRef{g: g, r: r}
			}
		}
		// First deriving entry wins the mode; a conflicting later mode is ignored
		// (the descriptor authors one mode per equipment group).
	}
	return s
}

// Empty reports whether the stage has no derive groups (Process is a no-op).
func (s *Stage) Empty() bool { return len(s.groups) == 0 }

// present accumulates, per group this batch, the sensed count values + a ts.
type present struct {
	val [3]float64
	has [3]bool
	ts  int64
}

// Process runs the derive stage over one envelope's decoded tags and returns the
// synthesized canonical count tags to inject into the ingest path (they resolve +
// store on the SAME path as any tag — their suffixes are the group's leaf-swapped
// siblings, which the equipment's raw_tag_map allowlist carries). It does NOT
// consume the sensed inputs: a sensed count is a real reading that still
// publishes; only the DERIVED siblings are synthesized. Returns nil when nothing
// was derived this batch.
func (s *Stage) Process(tags []rawtag.RawTag) []rawtag.RawTag {
	if s.Empty() {
		return nil
	}
	// First pass: collect the sensed count values, per group, from this batch.
	acc := map[*group]*present{}
	for _, t := range tags {
		ref, ok := s.bySuffix[t.Metric]
		if !ok {
			continue
		}
		v, num := toFloat(t.Value)
		if !num {
			continue // a non-numeric count can't contribute
		}
		p := acc[ref.g]
		if p == nil {
			p = &present{}
			acc[ref.g] = p
		}
		p.val[ref.r] = v
		p.has[ref.r] = true
		if t.TsMillis > p.ts {
			p.ts = t.TsMillis
		}
	}
	// Second pass: per group, if every SENSED role for its mode arrived, run Apply
	// and synthesize the DERIVED siblings.
	var synth []rawtag.RawTag
	for g, p := range acc {
		spec := modeSpecs[g.mode]
		ready := true
		for _, r := range spec.sensed {
			if !p.has[r] {
				ready = false // a partial group looks like a drop to Calc — hold
				break
			}
		}
		if !ready {
			continue
		}
		gross, net, scrap := p.val[roleGross], p.val[roleNet], p.val[roleScrap]
		if err := Apply(&gross, &net, &scrap, g.mode); err != nil {
			continue // unknown mode (can't happen for a compiled group) — skip safely
		}
		out := [3]float64{gross, net, scrap}
		for _, r := range spec.derived {
			synth = append(synth, rawtag.RawTag{
				Metric:   g.suffixes[r],
				Value:    math.Floor(out[r]),
				TsMillis: p.ts,
				Quality:  true,
			})
		}
	}
	return synth
}

// toFloat coerces a decoded raw-tag value to a float (mirrors deriver.toFloat).
// Only a numeric count is a valid derivation input; bool/string/nil are not.
func toFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int64:
		return float64(n), true
	case int:
		return float64(n), true
	default:
		return 0, false
	}
}
