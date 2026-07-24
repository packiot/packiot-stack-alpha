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
	"sort"
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

	// ParameterAliases disambiguate a bare, overloaded "Parameter" tag. Real
	// PLCs may publish "Status/Parameter" for what the Calc keys as
	// Parameter30700 (line-machines CSV), Parameter30750 (min speed), or
	// Parameter30758 (event trigger) — the raw name alone cannot tell them
	// apart, so CS Admin states the mapping per tenant, optionally scoped to a
	// class (Parameter30700 is a line concept).
	ParameterAliases []ParameterAlias `yaml:"parameter_aliases"`

	// ── SYNTHESIZE side (build canonical raw_tag_map from register) ───────────

	// CountIndex resolves the {idx} embedded in a count metric's name.
	CountIndex CountIndexRule `yaml:"count_index"`

	// MetricTemplates are the per-class canonical metric leaves the loader emits
	// for each equipment. "{idx}" in a leaf is filled from CountIndex.
	MetricTemplates MetricTemplates `yaml:"metric_templates"`
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
func (p *Profile) SynthesizeEquipment(localSegment string, class EquipClass, idEquipment int) ([]SynthMetric, error) {
	tmpls := p.templatesFor(class)
	out := make([]SynthMetric, 0, len(tmpls))
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
		out = append(out, SynthMetric{Suffix: localSegment + leaf, Type: t.Type})
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

// sortedSynth returns metrics in a stable order (by suffix) — handy for
// deterministic output + test diffs. Not required for correctness (the agent
// resolver is a map).
func sortedSynth(ms []SynthMetric) []SynthMetric {
	out := append([]SynthMetric(nil), ms...)
	sort.Slice(out, func(i, j int) bool { return out[i].Suffix < out[j].Suffix })
	return out
}
