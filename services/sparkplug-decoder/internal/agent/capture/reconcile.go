// Package capture is the ADR-0045 P2 LIVE-TEE COUNT-INDEX CAPTURE engine — the
// "capture" step of the CS-Admin onboarding loop describe → generate → CAPTURE
// → validate → cut over (ADR-0045 §2.5).
//
// The problem it solves (why a whole step exists for one integer)
// ---------------------------------------------------------------
// A member's count index — the integer the PLC embeds in
// `…/Admin/ProdProcessedCount/<IDX>/Unit` — is an ARBITRARY PLC channel number
// that is NOT derivable from any table (#601: CPACK's BREYER1 emits index 26
// while its register id_equipment is 340; L4 uses a private 6/7/8/9 series). It
// is an UNKNOWABLE PLC fact. The onboarding descriptor (ADR-0045 P1) therefore
// carries each member's index tagged confidence: confirmed | inferred, and the
// generator REFUSES a cutover config while any inferred index remains ("no
// tenant cuts over on inferred data").
//
// The only way to turn an inferred guess into a confirmed fact is to OBSERVE
// what the client's live tee actually sends. That observation was, until P0,
// impossible: an unmapped count topic (a wrong inferred index) was SILENTLY
// DROPPED by the agent's strict raw_tag_map allowlist — precisely the failure
// that hid L6's mismatch during the CPACK go-live (#601). ADR-0045 P0 (the
// `unmapped` reporter) turned that silent drop into a verbose `/healthz` field:
// `components.unmapped_tags.unmapped_suffixes` — "here is every topic the tee
// sent that the map does not cover."
//
// This package is the reconciler that closes the loop. Given
//
//   - the DESCRIPTOR (expected indices + confirmed/inferred confidence, P1), and
//   - the OBSERVED topic set = the agent's ACCEPTED/mapped suffixes ∪ the P0
//     verbose `/healthz` UNMAPPED suffixes,
//
// it decides, per opted-in member, one of four verdicts:
//
//	CONFIRMED  the member's expected index was positively OBSERVED on the wire
//	           (its count suffix is in the accepted set, OR a prior confirmation
//	           is retained with no contradicting observation). Cutover-eligible.
//	MISMATCH   an unmapped count suffix for this member carries a DIFFERENT index
//	           than the descriptor expects — the silent-drop cause. The real
//	           index is now captured; the descriptor is wrong and gets corrected.
//	MISSING    the member is opted-in and inferred but produced NO count
//	           observation at all (dormant, or simply not seen this window). It
//	           stays inferred and BLOCKS cutover — we refuse to confirm a guess
//	           we never saw.
//	UNMAPPED   an observed count index maps to NO member in the descriptor — an
//	           orphan topic for equipment that is not onboarded (a new machine, a
//	           typo, or an out-of-scope cell). Flagged for CS Admin.
//
// The output is (1) a reconciliation report and (2) an updated descriptor
// FRAGMENT — the corrected/confirmed equipment rows, ready to paste back into
// the P1 descriptor. The cutover gate (`Report.CutoverReady`) is true ONLY when
// every opted-in member is CONFIRMED: the machine-checkable expression of "no
// cutover on inferred."
//
// Read-only by construction: this package parses files + an HTTP GET of
// `/healthz`; it never writes to the agent, the broker, or any database.
package capture

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// Confidence vocabulary — re-exported from the P1 descriptor so this package and
// the generator can never disagree on the strings that gate cutover.
const (
	ConfidenceConfirmed = clientdescriptor.ConfidenceConfirmed
	ConfidenceInferred  = clientdescriptor.ConfidenceInferred
)

// State is a per-member reconciliation verdict.
type State string

const (
	StateConfirmed State = "CONFIRMED"
	StateMismatch  State = "MISMATCH"
	StateMissing   State = "MISSING"
	StateUnmapped  State = "UNMAPPED"
)

// Channel records where an observed suffix came from — the accepted/mapped set
// (positive proof the index is live and correct) or the P0 unmapped set (proof
// a DIFFERENT index is on the wire, i.e. the descriptor is wrong).
type Channel string

const (
	ChannelAccepted Channel = "accepted"
	ChannelUnmapped Channel = "unmapped"
)

// ── Descriptor: the ADR-0045 P1 client descriptor (reused, not remodelled) ───
//
// The capture step reads + emits the SAME clientdescriptor.Descriptor the P1
// generator authors. Reusing the type (rather than a local mirror) is the actual
// loop-closure: P1's InferredMembers() names what must be captured, and an
// emitted fragment is byte-compatible with the P1 descriptor's equipment rows.

// LoadDescriptor reads + validates a client descriptor via the P1 loader.
func LoadDescriptor(path string) (*clientdescriptor.Descriptor, error) {
	return clientdescriptor.Load(path)
}

// ── Healthz: the P0 verbose /healthz envelope (the observed UNMAPPED set) ────

// Healthz is the sparkplug-agent /healthz body, narrowed to the P0 unmapped
// diagnostic. Shape mirrors internal/health.MultiSnapshotter +
// internal/agent/unmapped.Reporter.SnapshotDetail.
type Healthz struct {
	Healthy    bool `json:"healthy"`
	Components struct {
		UnmappedTags struct {
			Group            string           `json:"group"`
			TotalDropped     int64            `json:"total_dropped"`
			Verbose          bool             `json:"verbose"`
			UnmappedSuffixes []UnmappedSuffix `json:"unmapped_suffixes"`
		} `json:"unmapped_tags"`
	} `json:"components"`
}

// UnmappedSuffix is one distinct dropped suffix + how many times it was seen.
type UnmappedSuffix struct {
	Suffix string `json:"suffix"`
	Count  int64  `json:"count"`
}

// ParseHealthz decodes a /healthz JSON body.
func ParseHealthz(raw []byte) (*Healthz, error) {
	var h Healthz
	if err := json.Unmarshal(raw, &h); err != nil {
		return nil, fmt.Errorf("capture: parse healthz: %w", err)
	}
	return &h, nil
}

// LoadHealthzFile reads a captured /healthz JSON fixture from disk.
func LoadHealthzFile(path string) (*Healthz, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("capture: read healthz %s: %w", path, err)
	}
	return ParseHealthz(raw)
}

// LoadAcceptedFile reads the accepted/mapped suffix set from a newline-delimited
// file (blank lines + `#` comments ignored). This is the positive-evidence
// channel — every suffix the agent ACCEPTED (mapped + applied at least one
// value). Today it is produced read-only from the agent's SparkPlug NBIRTH
// (the tagstore snapshot = every mapped metric that has received a value) or a
// future verbose-/healthz accepted list; see the cmd/onboard-capture header.
func LoadAcceptedFile(path string) ([]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("capture: read accepted %s: %w", path, err)
	}
	var out []string
	for _, ln := range strings.Split(string(raw), "\n") {
		s := strings.TrimSpace(ln)
		if s == "" || strings.HasPrefix(s, "#") {
			continue
		}
		out = append(out, s)
	}
	return out, nil
}

// ── Reconciliation ──────────────────────────────────────────────────────────

// Options tunes a reconciliation run.
type Options struct {
	// Only, if non-empty, scopes the run to members whose canonical topic
	// contains this path COMPONENT (e.g. "L6" reconciles only the L6 line's
	// members). Empty ⇒ every member in the descriptor.
	Only string
}

// MemberResult is one member's reconciliation verdict.
type MemberResult struct {
	Topic              string  `json:"topic"`
	Key                string  `json:"key"`      // trailing LINE/MEMBER identity used for matching
	Expected           int     `json:"expected"` // descriptor's declared index
	ExpectedConfidence string  `json:"expected_confidence"`
	Observed           *int    `json:"observed,omitempty"` // index seen on the wire (nil ⇒ none)
	Channel            Channel `json:"channel,omitempty"`  // where Observed came from
	State              State   `json:"state"`
	Note               string  `json:"note"`
	// Captured is the corrected equipment row when the verdict changes the
	// descriptor (MISMATCH → real index confirmed; a fresh CONFIRMED that flips
	// an inferred flag). Nil when nothing changes.
	Captured *clientdescriptor.Equipment `json:"-"`
}

// OrphanResult is an observed count index that maps to no descriptor member.
type OrphanResult struct {
	Key     string  `json:"key"`
	Index   int     `json:"index"`
	Channel Channel `json:"channel"`
	Suffix  string  `json:"suffix"`
}

// Report is the full reconciliation outcome.
type Report struct {
	Tenant       string         `json:"tenant"`
	Scope        string         `json:"scope"` // "all" or the --only value
	Members      []MemberResult `json:"members"`
	Orphans      []OrphanResult `json:"orphans"`
	CutoverReady bool           `json:"cutover_ready"`
	Blocking     []string       `json:"blocking"`
	// Counts summarises the member verdicts.
	Counts map[State]int `json:"counts"`
}

// observation is one (index, channel) sighting for a member key.
type observation struct {
	index   int
	channel Channel
	suffix  string
}

// countTemplate is a member count leaf split around the {idx} placeholder.
type countTemplate struct {
	pre  string // e.g. "/Admin/ProdProcessedCount/"
	post string // e.g. "/Unit"
}

// Reconcile compares the descriptor's expected indices against the observed
// topic set (accepted ∪ unmapped) and returns a Report.
func Reconcile(d *clientdescriptor.Descriptor, accepted []string, h *Healthz, opts Options) (*Report, error) {
	tmpls := countTemplates(d.MetricTemplates.Member)
	if len(tmpls) == 0 {
		return nil, fmt.Errorf("capture: descriptor has no indexed member count leaf ({idx}) — nothing to reconcile")
	}

	// Index the descriptor members by their trailing LINE/MEMBER key.
	members := map[string]*clientdescriptor.Equipment{}
	for i := range d.Equipment {
		e := &d.Equipment[i]
		if e.TPEquipment != 1 { // only members (tp=1) carry a count index
			continue
		}
		key := trailingKey(e.Topic)
		if _, dup := members[key]; dup {
			return nil, fmt.Errorf("capture: descriptor has two members with the same trailing key %q "+
				"(%s) — the tool identifies members by LINE/MEMBER and cannot disambiguate", key, e.Topic)
		}
		members[key] = e
	}

	// Fold the observed suffixes into per-key sightings.
	obs := map[string][]observation{}
	foldSuffix := func(suffix string, ch Channel) {
		seg, idx, ok := extractIndex(suffix, tmpls)
		if !ok {
			return // not a count leaf (e.g. a Status suffix) — irrelevant to index capture
		}
		key := trailingKey(seg)
		obs[key] = append(obs[key], observation{index: idx, channel: ch, suffix: suffix})
	}
	for _, s := range accepted {
		foldSuffix(s, ChannelAccepted)
	}
	for _, u := range h.Components.UnmappedTags.UnmappedSuffixes {
		foldSuffix(u.Suffix, ChannelUnmapped)
	}

	rep := &Report{
		Tenant: d.Tenant,
		Scope:  "all",
		Counts: map[State]int{},
	}
	if opts.Only != "" {
		rep.Scope = opts.Only
	}

	// Verdict per in-scope member.
	inScope := func(topic string) bool {
		if opts.Only == "" {
			return true
		}
		return hasComponent(topic, opts.Only)
	}
	keys := make([]string, 0, len(members))
	for k := range members {
		keys = append(keys, k)
	}
	sort.Strings(keys) // deterministic report ordering
	matched := map[string]bool{}
	for _, key := range keys {
		e := members[key]
		if !inScope(e.Topic) {
			continue
		}
		matched[key] = true
		res := verdict(e, key, obs[key])
		rep.Members = append(rep.Members, res)
		rep.Counts[res.State]++
	}

	// Orphans: observed count keys that matched no member (in scope). An orphan
	// under the current scope blocks cutover; out-of-scope orphans are noise and
	// omitted so a scoped run stays focused.
	orphanKeys := make([]string, 0)
	for key := range obs {
		if _, isMember := members[key]; isMember {
			continue
		}
		orphanKeys = append(orphanKeys, key)
	}
	sort.Strings(orphanKeys)
	for _, key := range orphanKeys {
		o := obs[key][0]
		if opts.Only != "" && !hasComponent("/"+key, opts.Only) {
			continue
		}
		rep.Orphans = append(rep.Orphans, OrphanResult{Key: key, Index: o.index, Channel: o.channel, Suffix: o.suffix})
		rep.Counts[StateUnmapped]++
	}

	// Cutover gate: READY iff every in-scope member is CONFIRMED and no orphan.
	rep.CutoverReady = true
	for _, m := range rep.Members {
		if m.State != StateConfirmed {
			rep.CutoverReady = false
			rep.Blocking = append(rep.Blocking, fmt.Sprintf("%s: %s (%s)", m.Key, m.State, m.Note))
		}
	}
	for _, o := range rep.Orphans {
		rep.CutoverReady = false
		rep.Blocking = append(rep.Blocking, fmt.Sprintf("%s: UNMAPPED orphan index %d", o.Key, o.Index))
	}
	return rep, nil
}

// verdict decides one member's state from its expected index + observations.
func verdict(e *clientdescriptor.Equipment, key string, sightings []observation) MemberResult {
	res := MemberResult{Topic: e.Topic, Key: key}
	if e.CountIndex != nil {
		res.Expected = e.CountIndex.Value
		res.ExpectedConfidence = e.CountIndex.Confidence
	}

	// Partition observations relative to the expected index.
	var conflict *observation // an index != expected (the real one, prefer unmapped)
	var acceptedEqual bool
	for i := range sightings {
		s := sightings[i]
		if s.index == res.Expected {
			if s.channel == ChannelAccepted {
				acceptedEqual = true
			}
			continue
		}
		// A differing index. Prefer an unmapped sighting (that is the topic the
		// tee sends that the allowlist rejects — the silent-drop cause); fall
		// back to any conflict.
		if conflict == nil || (conflict.channel != ChannelUnmapped && s.channel == ChannelUnmapped) {
			c := s
			conflict = &c
		}
	}

	switch {
	case conflict != nil:
		idx := conflict.index
		res.Observed = &idx
		res.Channel = conflict.channel
		res.State = StateMismatch
		res.Note = fmt.Sprintf("descriptor expects %d but tee sends %d (silent-drop cause) — capturing %d as confirmed",
			res.Expected, idx, idx)
		res.Captured = withCountIndex(e, idx, ConfidenceConfirmed)
	case acceptedEqual:
		idx := res.Expected
		res.Observed = &idx
		res.Channel = ChannelAccepted
		res.State = StateConfirmed
		if res.ExpectedConfidence == ConfidenceInferred {
			res.Note = "expected index observed live on the accepted set — flipping inferred → confirmed"
			res.Captured = withCountIndex(e, idx, ConfidenceConfirmed)
		} else {
			res.Note = "expected index observed live on the accepted set — confirmed"
		}
	default:
		// No observation of this member's count index at all.
		if res.ExpectedConfidence == ConfidenceConfirmed {
			res.State = StateConfirmed
			res.Note = "no live observation this window; retaining prior confirmation"
		} else {
			res.State = StateMissing
			res.Note = "opted-in but inferred and unobserved — dormant or not seen; blocks cutover"
		}
	}
	return res
}

// withCountIndex returns a copy of e with its count index set to (value,conf).
// A pre-existing Active flag is preserved (capture corrects the index, not the
// active/dormant provenance the DQ report tracks).
func withCountIndex(e *clientdescriptor.Equipment, value int, confidence string) *clientdescriptor.Equipment {
	cp := *e
	next := clientdescriptor.CountIndexCapture{Value: value, Confidence: confidence}
	if e.CountIndex != nil {
		next.Active = e.CountIndex.Active
	}
	cp.CountIndex = &next
	return &cp
}

// countTemplates splits every indexed member leaf around the {idx} placeholder.
func countTemplates(member []tenantprofile.TemplateEntry) []countTemplate {
	var out []countTemplate
	for _, t := range member {
		i := strings.Index(t.Leaf, tenantprofile.IdxPlaceholder)
		if i < 0 {
			continue
		}
		out = append(out, countTemplate{
			pre:  t.Leaf[:i],
			post: t.Leaf[i+len(tenantprofile.IdxPlaceholder):],
		})
	}
	return out
}

// extractIndex pulls (segment, index) from a metric suffix if it matches any
// count template. e.g. "/L6/BREYER/Admin/ProdProcessedCount/91/Unit" with
// template pre="/Admin/ProdProcessedCount/" post="/Unit" → ("/L6/BREYER", 91).
func extractIndex(suffix string, tmpls []countTemplate) (seg string, idx int, ok bool) {
	for _, t := range tmpls {
		if !strings.HasSuffix(suffix, t.post) {
			continue
		}
		core := suffix[:len(suffix)-len(t.post)]
		at := strings.LastIndex(core, t.pre)
		if at < 0 {
			continue
		}
		digits := core[at+len(t.pre):]
		if digits == "" || !isDigits(digits) {
			continue
		}
		n, err := strconv.Atoi(digits)
		if err != nil {
			continue
		}
		return core[:at], n, true
	}
	return "", 0, false
}

// trailingKey returns the last two path components of a topic/segment joined by
// "/", the tenant-prefix-independent LINE/MEMBER identity used to match a
// member across differing agent prefixes (the agent may publish "/L6/BREYER/…"
// while the descriptor's canonical prefix yields "/LINHAS/L6/BREYER"; both share
// the trailing "L6/BREYER"). A path with fewer than two components returns all
// of them.
func trailingKey(path string) string {
	parts := components(path)
	if len(parts) >= 2 {
		parts = parts[len(parts)-2:]
	}
	return strings.Join(parts, "/")
}

// hasComponent reports whether comp appears as a whole path component in topic.
func hasComponent(topic, comp string) bool {
	for _, p := range components(topic) {
		if p == comp {
			return true
		}
	}
	return false
}

// components splits a slash path dropping empty segments.
func components(path string) []string {
	var out []string
	for _, p := range strings.Split(path, "/") {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func isDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
