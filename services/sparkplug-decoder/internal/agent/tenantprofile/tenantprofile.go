// Package tenantprofile is the declarative, CS-Admin-owned per-tenant
// SparkPlug topic + metric CONVERSION PROFILE (task #13, ADR-0009 "replace
// EQUIPMENT_MAP with a packml_register-driven loader"; ADR-0042 north-star
// "customization as data, not code").
//
// The problem it solves
// ----------------------
// The CPACK L6 tee validation proved the ingest pipeline end-to-end, but only
// after HAND-EDITING docs/clients/cpack-agent.yaml's raw_tag_map (PR #590) to
// match the real prod PLC naming. That hand-YAML is a STOPGAP: with N client
// factories, each with its own PLC tag quirks, a per-client YAML edit + deploy
// does not scale, and it puts factory-onboarding data in an engineering
// artifact. USER directive (2026-07-23): "CS Admin will be responsible to set
// this all up. topics, conversion etc."
//
// This package is that config surface. It expresses — declaratively, with no
// per-client Go code — the four quirk classes surfaced by the CPACK validation:
//
//  1. prefix fixups     real "C-PACK/…"            → canonical "CPACK/…"
//  2. metric aliases     real "Status/CurMachSpeed" → canonical "Status/MachSpeed"
//  3. ambiguous Parameter real "Status/Parameter"   → canonical "Status/Parameter30700"
//     (bare "Parameter" is ambiguous across 30700 / 30750 /
//     30758 — a per-tenant rule names which one is meant)
//  4. count-index rules   the count metric embeds an id: members carry the prod
//     id_equipment (e.g. L6/TEXA → …/92/Unit); lines carry
//     their own; the surrogate ids can diverge on staging.
//     line-vs-member      lines (tp_equipment=3) additionally publish
//     Parameter30700 (the line-machines CSV); members do not.
//
// The sparkplug-agent and edge-transformer stay GENERIC: they LOAD a tenant's
// profile and packml_register and build the tag map from data. Zero per-client
// code, one ingest contract for every tenant (ADR-0032).
//
// Two conversion directions
// --------------------------
// A profile drives two complementary transforms, both defined here so a single
// artifact is the source of truth:
//
//   - SYNTHESIZE (build the canonical raw_tag_map): given the tenant's equipment
//     rows from packml_register (+ tp_equipment), emit the canonical
//     suffix→type entries the agent's resolver keys on. Uses MetricTemplates +
//     CountIndex. This is the register-driven replacement for the hand YAML.
//   - NORMALIZE (canonicalise an inbound metric name): given a raw tag name as a
//     PLC/tee actually sends it, rewrite it to the canonical form the resolver
//     expects. Uses PrefixFixups + MetricAliases + ParameterAliases. This is the
//     resolver-side quirk absorber for tenants whose packml_register already
//     carries per-metric rows in real naming.
package tenantprofile

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// EquipClass is the line-vs-member distinction that selects a metric-template
// set and gates Parameter30700 (lines only).
type EquipClass string

const (
	ClassLine   EquipClass = "line"   // tp_equipment = 3 (also 2/sector, aggregates like a line)
	ClassMember EquipClass = "member" // tp_equipment = 1 (individual machine)
)

// Profile is the parsed per-tenant conversion profile. Every field is data a
// Customer Success engineer fills during onboarding — no code path is
// per-tenant.
type Profile struct {
	// Tenant is the SparkPlug group_id / enterprise short-name (e.g. "CPACK").
	// Documentation + a cross-check against the agent descriptor's group_id.
	Tenant string `yaml:"tenant"`

	// EnterpriseID is the packml_register.id_enterprise the register loader
	// scopes its query to (the cross-tenant guard). Optional in the schema so a
	// profile can be validated/tested without it; the DB loader requires it.
	EnterpriseID int `yaml:"enterprise_id"`

	// TenantPrefix is the CANONICAL packml prefix (post-fixup) shared by every
	// equipment topic, e.g. "CPACK/SC/LINHAS". A registered equipment topic
	// minus this prefix is its LOCAL SEGMENT (e.g. "/L5/BREYER"); the agent's
	// packml_topic prepends it back. Never spelled per-tag (the s7/mapping.go
	// PackMLTopic+Metric discipline).
	TenantPrefix string `yaml:"tenant_prefix"`

	// ── NORMALIZE side (inbound real→canonical) ──────────────────────────────

	// PrefixFixups rewrite the head of a raw topic to canonical form. Applied
	// FIRST, in order, first-match-per-rule (like translate.RemapTopic's single
	// C-PACK/→CPACK/ replace). Example: {from: "C-PACK/", to: "CPACK/"}.
	PrefixFixups []Rewrite `yaml:"prefix_fixups"`

	// MetricAliases rewrite a metric leaf that a PLC names differently from the
	// canonical Calc input. Applied as a suffix rewrite (the raw leaf → canonical
	// leaf). Example: {from: "Status/CurMachSpeed", to: "Status/MachSpeed"}.
	MetricAliases []Rewrite `yaml:"metric_aliases"`

	// ParameterAliases disambiguate a bare, overloaded "Parameter" tag by a
	// single per-class rename. Real PLCs may publish "Status/Parameter" for what
	// the Calc keys as Parameter30700 (line-machines CSV), Parameter30750 (min
	// speed), or Parameter30758 (event trigger) — the raw name alone cannot tell
	// them apart, so CS Admin states the mapping per tenant, optionally scoped to
	// a class (Parameter30700 is a line concept).
	//
	// LIMITATION (why ParameterDecomposition below exists): a bare "Parameter"
	// carries DIFFERENT parameters on the SAME topic over time — the same line
	// emits 30700, 30701, 30750, 30758 all as ".../Status/Parameter". A single
	// class-scoped rename can only pick ONE, so ParameterAliases alone cannot
	// route a real CPACK stream. It stays for the simple single-parameter tenant;
	// CPACK needs the per-tag id-driven ParameterDecomposition.
	ParameterAliases []ParameterAlias `yaml:"parameter_aliases"`

	// ParameterDecomposition decomposes a bare, id-carrying "Parameter" metric
	// into its canonical numbered leaf using the tag's PackML parameter id — the
	// #593 follow-up that makes Phase-9 line aggregation fire on real CPACK data.
	ParameterDecomposition ParameterDecomposition `yaml:"parameter_decomposition"`

	// ── SYNTHESIZE side (build canonical raw_tag_map from register) ───────────

	// CountIndex resolves the {idx} embedded in a count metric's name.
	CountIndex CountIndexRule `yaml:"count_index"`

	// MetricTemplates are the per-class canonical metric leaves the loader emits
	// for each equipment. "{idx}" in a leaf is filled from CountIndex.
	MetricTemplates MetricTemplates `yaml:"metric_templates"`

	// Derived are the per-equipment agent-side SYNTHESIS rules (ADR-0045 P2c).
	// Each rule is FULLY RESOLVED at generate time (GenerateProfile): its Emit /
	// Source / Addends are segment-qualified suffixes with {idx} already
	// substituted, so both the register-synthesis path (SynthesizeEquipment adds
	// the Emit suffixes to the allowlist) and the runtime deriver (which computes
	// their VALUES) consume the profile directly, with no descriptor at runtime.
	// A profile with no derived rules is a no-op (the deriver stays empty).
	Derived []DerivedRule `yaml:"derived,omitempty"`
}

// DerivedRule is one equipment's agent-side derive rule, fully resolved.
// Exactly one of {Integral, Sum} is set. The Emit suffixes are the canonical
// count leaves the deriver publishes (they must ALSO appear in the synthesized
// raw_tag_map allowlist so the resolver accepts them — SynthesizeEquipment adds
// them). Segment is the equipment LOCAL SEGMENT (e.g. "/L5/FLEXO") the rule
// belongs to, so SynthesizeEquipment (called per equipment) can match its rules.
type DerivedRule struct {
	// Segment is the equipment local segment (topic minus tenant prefix), e.g.
	// "/L5/FLEXO". Used only to attach the rule's Emit leaves to that equipment's
	// synthesis; the runtime deriver keys on the FULL Source/Addend suffixes.
	Segment string `yaml:"segment"`

	// Emit are the FULL (segment-qualified) canonical count suffixes the deriver
	// publishes the computed value to, e.g. "/L5/FLEXO/Admin/ProdConsumedCount/61/Unit".
	Emit []string `yaml:"emit"`

	// Type is the SparkPlug type of the emitted count (the tenant's count type,
	// e.g. "double" for CPACK). Used as the allowlist entry's type when the Emit
	// suffix is not already produced by a metric template.
	Type string `yaml:"type"`

	// Integral synthesizes a monotonic count by integrating an analog source rate
	// over time (FLEXO: an analog speed → a virtual production counter).
	Integral *IntegralSource `yaml:"integral,omitempty"`

	// Sum synthesizes a count by summing several register addends (PTH: A+B).
	Sum *SumSource `yaml:"sum,omitempty"`
}

// IntegralSource declares an analog→count time integral. In a descriptor its
// Source is a RELATIVE leaf with an optional {idx}; in a resolved profile it is
// the FULL segment-qualified arriving suffix the tee actually sends.
type IntegralSource struct {
	// Source is the analog rate metric suffix to integrate, e.g.
	// "/Status/CurMachSpeed" (descriptor, relative) →
	// "/L5/FLEXO/Status/CurMachSpeed" (profile, resolved). ⚠ It matches the RAW
	// ARRIVING suffix — the agent ingest does NOT run metric aliases inbound
	// (those are register-side), so declare the raw name the tee emits.
	Source string `yaml:"source"`

	// Conversion scales the source value into a per-second production rate
	// (units/s = value * conversion). E.g. a speed in units/min → 1.0/60.
	Conversion float64 `yaml:"conversion"`

	// ClampMin floors the computed rate (default 0 keeps the integral monotonic
	// even if the source briefly reports a negative/garbage rate).
	ClampMin float64 `yaml:"clamp_min,omitempty"`

	// MaxRate, when > 0, rejects a sample whose computed rate exceeds it (a spike
	// guard): the sample is skipped entirely (no accumulation, lastTs unchanged).
	MaxRate float64 `yaml:"max_rate,omitempty"`
}

// SumSource declares a multi-register sum. In a descriptor the Addends are
// RELATIVE leaves; in a resolved profile they are FULL segment-qualified
// arriving suffixes. At least two addends (a one-addend "sum" is a rename).
type SumSource struct {
	// Addends are the arriving suffixes to latch-and-sum, e.g.
	// ["/L5/PTH/Status/CountA", "/L5/PTH/Status/CountB"].
	Addends []string `yaml:"addends"`
}

// Rewrite is an ordered from→to string rewrite.
type Rewrite struct {
	From string `yaml:"from"`
	To   string `yaml:"to"`
}

// ParameterAlias maps an ambiguous raw Parameter leaf to a specific canonical
// Parameter<NNNNN> leaf, optionally scoped to a class ("line"|"member"|"" =
// any). AppliesTo lets the same raw name resolve differently by equipment type.
type ParameterAlias struct {
	From      string     `yaml:"from"`
	To        string     `yaml:"to"`
	AppliesTo EquipClass `yaml:"applies_to,omitempty"`
}

// ParameterDecomposition resolves the CPACK-class "one overloaded Parameter
// metric, disambiguated by a metric-level id" quirk.
//
// The prod reality (SELECT-only read of the ent-1 register + the oeecloud
// ingestion flow, 2026-07-23): CPACK publishes a SINGLE SparkPlug metric per
// equipment named ".../Status/Parameter" — there are NO numbered Parameter
// topics on the wire. The PackML parameter NUMBER travels in the SparkPlug
// metric's id/alias field: {name:".../Status/Parameter", id:30700, value:"5"}.
// The current cloud (oeecloud-node-red "01 · Ingestion & Writes") reads
// `parameter_id = JSON.parse(metric).id` and branches on it (30700 line order,
// 30701 ideal speed, 30750 min-speed, 30758 event trigger, 30800+ PO control).
//
// The refactored Calc, by contrast, keys its state seeds on the metric NAME
// suffix (HasSuffix(name,"/Status/Parameter30700")). A bare "Parameter" matches
// none of them, and — unlike ParameterAliases — one topic carries MANY
// parameters over time, so no single rename works. This rule closes the gap by
// decomposing PER TAG: the inbound tag carries its id (rawtag.RawTag.ParamID),
// the id selects a DECLARED canonical numbered leaf, and the agent rewrites the
// suffix before it hits the raw_tag_map allowlist. Decomposition is an explicit
// allowlist (Params), never a blind numeric append: an undeclared id is left
// bare (→ dropped as unmapped), so a stray PO-control write can never be
// mistaken for a Calc seed.
type ParameterDecomposition struct {
	// SourceLeaf is the bare, overloaded leaf the tee sends, e.g.
	// "/Status/Parameter". A tag whose suffix ends with this leaf AND carries a
	// param id present in Params is rewritten to that id's canonical leaf.
	// Empty ⇒ decomposition disabled for this tenant.
	SourceLeaf string `yaml:"source_leaf"`

	// Params is the declared id → canonical-numbered-leaf table. The SparkPlug
	// datatype of the rewritten metric is NOT set here — it comes from the
	// raw_tag_map allowlist entry the rewritten suffix resolves to (metric_
	// templates for the register path, or the hand YAML), keeping one source of
	// truth for wire types.
	Params []DecomposedParam `yaml:"params"`
}

// DecomposedParam is one id → canonical leaf mapping. AppliesTo optionally
// documents/scopes the parameter to a class (30700 is a line concept); it is
// advisory — the raw_tag_map allowlist is the hard gate (only lines carry a
// Parameter30700 entry, so a member's decomposed 30700 is dropped anyway).
type DecomposedParam struct {
	ID        int        `yaml:"id"`
	Leaf      string     `yaml:"leaf"`
	AppliesTo EquipClass `yaml:"applies_to,omitempty"`
}

// DecomposeParameterSuffix rewrites an inbound bare-Parameter metric SUFFIX to
// its canonical numbered suffix using the tag's PackML parameter id. Returns
// (rewritten, true) when the rule is configured, suffix ends with SourceLeaf,
// and paramID is a declared param; otherwise (suffix, false) — the caller
// leaves the tag untouched (bare Parameter stays unmapped → dropped).
func (p *Profile) DecomposeParameterSuffix(suffix string, paramID int) (string, bool) {
	d := p.ParameterDecomposition
	if d.SourceLeaf == "" || paramID == 0 || !strings.HasSuffix(suffix, d.SourceLeaf) {
		return suffix, false
	}
	for _, pr := range d.Params {
		if pr.ID == paramID {
			return strings.TrimSuffix(suffix, d.SourceLeaf) + pr.Leaf, true
		}
	}
	return suffix, false
}

// CountIndexRule tells the synthesizer what integer to substitute for "{idx}".
//
//	mode: equipment_id  → the equipment's own id_equipment (register default)
//	mode: explicit      → only Overrides are honoured; no default (fail if unset)
//
// Overrides (keyed by LOCAL SEGMENT, e.g. "/L5/BREYER") pin an index when the
// PLC embeds a legacy/foreign id that differs from the register surrogate — the
// exact CPACK staging case (BREYER register id 53 but the metric embeds 61).
type CountIndexRule struct {
	Mode      string         `yaml:"mode"`
	Overrides map[string]int `yaml:"overrides,omitempty"`
}

// MetricTemplates hold the canonical leaves emitted per class. A member set
// omits Parameter30700; a line set includes it — that is the whole line-vs-
// member expression, as data.
type MetricTemplates struct {
	Line   []TemplateEntry `yaml:"line"`
	Member []TemplateEntry `yaml:"member"`
}

// TemplateEntry is one canonical metric leaf + SparkPlug type. Leaf may contain
// the "{idx}" placeholder (count metrics); a leaf without it is index-free
// (MachSpeed, StateCurrent, Parameter30700).
type TemplateEntry struct {
	Leaf string `yaml:"leaf"`
	Type string `yaml:"type"`
}

// IdxPlaceholder is the token replaced by the resolved count index.
const IdxPlaceholder = "{idx}"

// validTypes is the SparkPlug type set (mirrors agentcfg.validate so a profile
// can never synthesise a type agentcfg would later reject).
var validTypes = map[string]bool{
	"double": true, "float": true, "long": true,
	"int": true, "bool": true, "string": true,
}

// LoadProfile reads + validates a tenant conversion profile from disk.
func LoadProfile(path string) (*Profile, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("tenantprofile: read %s: %w", path, err)
	}
	var p Profile
	if err := yaml.Unmarshal(raw, &p); err != nil {
		return nil, fmt.Errorf("tenantprofile: parse %s: %w", path, err)
	}
	if err := p.Validate(); err != nil {
		return nil, fmt.Errorf("tenantprofile: validate %s: %w", path, err)
	}
	return &p, nil
}

// Validate checks internal consistency. It is intentionally strict on the
// synthesize inputs (a bad template type would corrupt the whole map) and
// lenient on the normalize inputs (a tenant may legitimately have zero fixups).
func (p *Profile) Validate() error {
	if strings.TrimSpace(p.TenantPrefix) == "" {
		return fmt.Errorf("tenant_prefix is required")
	}
	switch p.CountIndex.Mode {
	case "", "equipment_id", "explicit":
	default:
		return fmt.Errorf("count_index.mode=%q must be equipment_id|explicit", p.CountIndex.Mode)
	}
	for class, tmpls := range map[EquipClass][]TemplateEntry{
		ClassLine:   p.MetricTemplates.Line,
		ClassMember: p.MetricTemplates.Member,
	} {
		for i, t := range tmpls {
			if strings.TrimSpace(t.Leaf) == "" {
				return fmt.Errorf("metric_templates.%s[%d]: leaf is required", class, i)
			}
			if !validTypes[t.Type] {
				return fmt.Errorf("metric_templates.%s[%d] (%s): type=%q must be double|float|long|int|bool|string",
					class, i, t.Leaf, t.Type)
			}
		}
	}
	// parameter_decomposition: strict when configured (a bad id→leaf mapping
	// would silently misroute a Calc seed). Absent (SourceLeaf empty) is fine.
	if d := p.ParameterDecomposition; d.SourceLeaf != "" {
		if len(d.Params) == 0 {
			return fmt.Errorf("parameter_decomposition.source_leaf set but params is empty")
		}
		seen := map[int]bool{}
		for i, pr := range d.Params {
			if pr.ID <= 0 {
				return fmt.Errorf("parameter_decomposition.params[%d]: id must be > 0", i)
			}
			if seen[pr.ID] {
				return fmt.Errorf("parameter_decomposition.params[%d]: duplicate id %d", i, pr.ID)
			}
			seen[pr.ID] = true
			if strings.TrimSpace(pr.Leaf) == "" {
				return fmt.Errorf("parameter_decomposition.params[%d] (id %d): leaf is required", i, pr.ID)
			}
			switch pr.AppliesTo {
			case "", ClassLine, ClassMember:
			default:
				return fmt.Errorf("parameter_decomposition.params[%d] (id %d): applies_to=%q must be line|member|empty",
					i, pr.ID, pr.AppliesTo)
			}
		}
	}
	// derived: strict when present (a bad synthesis rule would silently corrupt a
	// tenant's counts). Exactly one of {integral, sum}; Emit non-empty + valid
	// type; sum needs ≥2 addends; integral needs a source.
	for i, r := range p.Derived {
		if err := r.validate(fmt.Sprintf("derived[%d]", i)); err != nil {
			return err
		}
	}
	return nil
}

// validate checks one resolved DerivedRule. label is the caller's positional
// context for a precise error. The shape rules mirror the descriptor's
// DerivedMetric validation (one source of truth for "is a derive rule sane"),
// but on the RESOLVED form (segment-qualified suffixes).
func (r DerivedRule) validate(label string) error {
	hasIntegral := r.Integral != nil
	hasSum := r.Sum != nil
	if hasIntegral == hasSum {
		return fmt.Errorf("%s: exactly one of {integral, sum} must be set", label)
	}
	if len(r.Emit) == 0 {
		return fmt.Errorf("%s: emit must list at least one canonical count suffix", label)
	}
	for j, e := range r.Emit {
		if strings.TrimSpace(e) == "" {
			return fmt.Errorf("%s: emit[%d] is empty", label, j)
		}
	}
	if !validTypes[r.Type] {
		return fmt.Errorf("%s: type=%q must be double|float|long|int|bool|string", label, r.Type)
	}
	if hasIntegral && strings.TrimSpace(r.Integral.Source) == "" {
		return fmt.Errorf("%s: integral.source is required", label)
	}
	if hasSum && len(r.Sum.Addends) < 2 {
		return fmt.Errorf("%s: sum.addends must list at least two suffixes (a one-addend sum is a rename)", label)
	}
	return nil
}

// ClassOf maps a tp_equipment to an EquipClass. 3 (line) and 2 (sector) select
// the line template set; 1 (machine) selects member. Sectors aggregate like
// lines (they carry the line-machines Parameter30700), so they share the line
// set — matching how the Calc treats tp!=1 as line-level.
func ClassOf(tpEquipment int) EquipClass {
	if tpEquipment == 1 {
		return ClassMember
	}
	return ClassLine
}

// LocalSegment returns an equipment's topic with the tenant prefix stripped,
// e.g. "CPACK/SC/LINHAS/L5/BREYER" → "/L5/BREYER". A topic that is exactly the
// prefix yields "" (the tenant root, no local part). A topic that does not
// start with the prefix is returned unchanged with ok=false so the caller can
// skip a cross-tenant / mis-scoped row rather than mangle it.
func (p *Profile) LocalSegment(canonicalTopic string) (string, bool) {
	if canonicalTopic == p.TenantPrefix {
		return "", true
	}
	if strings.HasPrefix(canonicalTopic, p.TenantPrefix) {
		return strings.TrimPrefix(canonicalTopic, p.TenantPrefix), true
	}
	return canonicalTopic, false
}

// ResolveCountIndex returns the {idx} value for an equipment given its local
// segment and register id_equipment. Overrides win; otherwise equipment_id mode
// uses the register id and explicit mode errors on a missing override.
func (p *Profile) ResolveCountIndex(localSegment string, idEquipment int) (int, error) {
	if v, ok := p.CountIndex.Overrides[localSegment]; ok {
		return v, nil
	}
	switch p.CountIndex.Mode {
	case "explicit":
		return 0, fmt.Errorf("count_index.mode=explicit but no override for %q", localSegment)
	default: // "" and "equipment_id"
		return idEquipment, nil
	}
}

// templatesFor returns the metric-template set for a class.
func (p *Profile) templatesFor(class EquipClass) []TemplateEntry {
	if class == ClassMember {
		return p.MetricTemplates.Member
	}
	return p.MetricTemplates.Line
}

// SynthMetric is one synthesized canonical tag: the metric SUFFIX (local
// segment + filled leaf) and its SparkPlug type. Suffix is exactly what
// agentcfg.TagMapEntry.MetricSuffix carries.
type SynthMetric struct {
	Suffix string
	Type   string
}

// SynthesizeEquipment expands one equipment (local segment + class + id) into
// its canonical metric suffixes using the class templates and count-index rule.
//
// It ALSO appends the Emit suffixes of every Derived rule that belongs to this
// equipment's segment (ADR-0045 P2c): a derived count leaf must be in the agent
// raw_tag_map allowlist or the resolver would drop the deriver's synthesized tag
// as unmapped. A derived Emit that a metric template already produces is skipped
// (same suffix — the template's entry already declares the allowlist + type),
// so a FLEXO whose count leaf is both templated AND derived maps exactly once.
func (p *Profile) SynthesizeEquipment(localSegment string, class EquipClass, idEquipment int) ([]SynthMetric, error) {
	tmpls := p.templatesFor(class)
	out := make([]SynthMetric, 0, len(tmpls))
	seen := make(map[string]bool, len(tmpls))
	var idx int
	var idxErr error
	idxResolved := false
	for _, t := range tmpls {
		leaf := t.Leaf
		if strings.Contains(leaf, IdxPlaceholder) {
			if !idxResolved {
				idx, idxErr = p.ResolveCountIndex(localSegment, idEquipment)
				if idxErr != nil {
					return nil, fmt.Errorf("equipment %q: %w", localSegment, idxErr)
				}
				idxResolved = true
			}
			leaf = strings.ReplaceAll(leaf, IdxPlaceholder, strconv.Itoa(idx))
		}
		suffix := localSegment + leaf
		seen[suffix] = true
		out = append(out, SynthMetric{Suffix: suffix, Type: t.Type})
	}
	// Derived Emit leaves (already segment-qualified + {idx}-resolved) — add any
	// not already produced by a template so the allowlist covers the deriver's
	// synthesized counts.
	for _, r := range p.Derived {
		if r.Segment != localSegment {
			continue
		}
		for _, suffix := range r.Emit {
			if seen[suffix] {
				continue
			}
			seen[suffix] = true
			out = append(out, SynthMetric{Suffix: suffix, Type: r.Type})
		}
	}
	return out, nil
}

// ApplyPrefixFixups rewrites only the topic head (real→canonical), leaving the
// metric leaf untouched. Used on an equipment ROOT topic before LocalSegment so
// the synthesize path is robust to a register that stores real "C-PACK/…"
// naming, without running the leaf-level aliases (a root has no leaf).
func (p *Profile) ApplyPrefixFixups(topic string) string {
	out := topic
	for _, f := range p.PrefixFixups {
		out = strings.Replace(out, f.From, f.To, 1)
	}
	return out
}

// NormalizeTopic canonicalises a full raw topic: apply prefix fixups (head) then
// metric aliases + parameter aliases (leaf). class scopes the parameter aliases
// ("" = any). This is the resolver-side transform for a register that already
// carries per-metric rows in real naming.
func (p *Profile) NormalizeTopic(rawTopic string, class EquipClass) string {
	out := p.ApplyPrefixFixups(rawTopic)
	for _, a := range p.MetricAliases {
		out = strings.Replace(out, a.From, a.To, 1)
	}
	for _, pa := range p.ParameterAliases {
		if pa.AppliesTo != "" && pa.AppliesTo != class {
			continue
		}
		out = strings.Replace(out, pa.From, pa.To, 1)
	}
	return out
}
