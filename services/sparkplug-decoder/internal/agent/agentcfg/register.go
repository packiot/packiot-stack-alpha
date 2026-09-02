// register.go — the packml_register-driven raw_tag_map loader (task #13,
// ADR-0009: "Phase 3 replaces EQUIPMENT_MAP with a packml_register-driven
// loader"). It is the config-not-code replacement for the hand-maintained
// raw_tag_map in docs/clients/<tenant>-agent.yaml.
//
// Flag discipline (additive, default OFF): the caller decides via
// AGENT_TAGMAP_FROM_REGISTER whether to use this path. When OFF, Load() returns
// the static YAML raw_tag_map UNCHANGED — byte-for-byte the current behaviour.
// When ON, the agent's tag map is built from packml_register + the tenant
// conversion profile (tenantprofile), and the static raw_tag_map is ignored.
//
// The DB is a SEAM (RegisterFetcher), mirroring operator-adapter's injectable
// queryFn: unit tests build the map from an in-memory fixture with zero DB, and
// the pgx-backed fetcher (register_pg.go) is wired only when the flag is on — so
// the default build keeps edge-transformer's deliberate pgx-free footprint
// (go.mod note) until a tenant actually opts in.
package agentcfg

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// SetRawTagMap replaces the config's raw_tag_map (e.g. with a register-derived
// one) and re-runs full agentcfg validation, so a generated map is held to the
// exact same invariants as a hand-written YAML one (non-empty, unique suffixes,
// valid types). The sparkplug identity + broker wiring are left untouched.
func (c *Config) SetRawTagMap(entries []TagMapEntry) error {
	c.RawTagMap = entries
	return c.validate()
}

// RegisterRow is one equipment as packml_register knows it: the canonical
// (post-fixup) packml_topic, the equipment id, and tp_equipment (1=machine,
// 2=sector, 3=line). This is the SYNTHESIZE input — one row per equipment,
// NOT one per metric.
type RegisterRow struct {
	IDEquipment int
	PackMLTopic string
	TPEquipment int
}

// MetricRow is one packml_register row at metric granularity — the shape
// translate.go documents prod uses (several rows per equipment, one per
// metric, the topic carrying the count index). This is the NORMALIZE input.
type MetricRow struct {
	PackMLTopic string // raw, as registered (may be real "C-PACK/…" naming)
	TPEquipment int    // owning equipment's tp_equipment (scopes parameter aliases)
}

// RegisterFetcher is the DB seam. The real implementation (register_pg.go)
// queries packml_register scoped to the tenant enterprise + prefix; tests
// inject a fake. It returns equipment-granularity rows for the synthesize path.
type RegisterFetcher interface {
	FetchEquipment(ctx context.Context, enterpriseID int, canonicalPrefix string) ([]RegisterRow, error)
}

// BuildRawTagMapFromRegister is the SYNTHESIZE loader: for each equipment row,
// classify line-vs-member, expand the profile's metric templates, fill the
// count index, and emit canonical suffix→type TagMapEntry values — the same
// shape the static YAML raw_tag_map parses into.
//
// It is deterministic (rows sorted by topic, templates in profile order) so the
// generated map is stable across runs and diffable against the hand YAML. A
// row whose topic falls outside the tenant prefix is skipped (mis-scoped),
// never mangled.
func BuildRawTagMapFromRegister(prof *tenantprofile.Profile, rows []RegisterRow) ([]TagMapEntry, error) {
	if prof == nil {
		return nil, fmt.Errorf("nil profile")
	}
	sorted := append([]RegisterRow(nil), rows...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].PackMLTopic < sorted[j].PackMLTopic })

	var out []TagMapEntry
	seen := map[string]bool{}
	for _, r := range sorted {
		// A register may store real "C-PACK/…" naming; canonicalise the head
		// before deriving the local segment.
		local, ok := prof.LocalSegment(prof.ApplyPrefixFixups(r.PackMLTopic))
		if !ok {
			continue // topic outside the tenant prefix — not ours to map
		}
		class := tenantprofile.ClassOf(r.TPEquipment)
		metrics, err := prof.SynthesizeEquipment(local, class, r.IDEquipment)
		if err != nil {
			return nil, fmt.Errorf("synthesize %q (id=%d, tp=%d): %w",
				r.PackMLTopic, r.IDEquipment, r.TPEquipment, err)
		}
		for _, m := range metrics {
			if seen[m.Suffix] {
				return nil, fmt.Errorf("duplicate synthesized suffix %q (topic %q)", m.Suffix, r.PackMLTopic)
			}
			seen[m.Suffix] = true
			out = append(out, TagMapEntry{MetricSuffix: m.Suffix, Type: m.Type})
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("register loader produced no tags (no equipment under prefix %q)", prof.TenantPrefix)
	}
	return out, nil
}

// BuildRawTagMapFromMetricRows is the NORMALIZE loader: for a register that
// already carries per-metric rows in real naming, canonicalise each topic via
// the profile (prefix fixups + metric/parameter aliases), strip the tenant
// prefix to the suffix, and infer the SparkPlug type from the matching class
// template leaf. This path exercises the inbound quirk absorbers directly.
//
// Type inference: after normalisation, a metric's canonical leaf is matched
// against the profile's class templates (by leaf shape, {idx} wildcarded) to
// recover its declared type — so a single profile drives both directions
// consistently.
func BuildRawTagMapFromMetricRows(prof *tenantprofile.Profile, rows []MetricRow) ([]TagMapEntry, error) {
	if prof == nil {
		return nil, fmt.Errorf("nil profile")
	}
	sorted := append([]MetricRow(nil), rows...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].PackMLTopic < sorted[j].PackMLTopic })

	var out []TagMapEntry
	seen := map[string]bool{}
	for _, r := range sorted {
		class := tenantprofile.ClassOf(r.TPEquipment)
		canon := prof.NormalizeTopic(r.PackMLTopic, class)
		suffix, ok := prof.LocalSegment(canon)
		if !ok || suffix == "" {
			continue // outside prefix, or the bare equipment root (no metric leaf)
		}
		typ, ok := inferType(prof, class, suffix)
		if !ok {
			continue // no template matches this leaf — not a Calc input we map
		}
		if seen[suffix] {
			continue
		}
		seen[suffix] = true
		out = append(out, TagMapEntry{MetricSuffix: suffix, Type: typ})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("register loader produced no tags from %d metric rows under prefix %q",
			len(rows), prof.TenantPrefix)
	}
	return out, nil
}

// inferType matches a normalized suffix against the class templates to recover
// the declared SparkPlug type. The local-segment portion of the suffix is
// ignored; only the leaf shape matters, with {idx} matching any integer run.
func inferType(prof *tenantprofile.Profile, class tenantprofile.EquipClass, suffix string) (string, bool) {
	tmpls := prof.MetricTemplates.Member
	if class == tenantprofile.ClassLine {
		tmpls = prof.MetricTemplates.Line
	}
	for _, t := range tmpls {
		if leafMatches(suffix, t.Leaf) {
			return t.Type, true
		}
	}
	return "", false
}

// leafMatches reports whether suffix ENDS WITH the template leaf, treating the
// "{idx}" placeholder as a wildcard for one path segment of digits. Exact for
// index-free leaves ("/Status/MachSpeed"); wildcarded for count leaves
// ("/Admin/ProdConsumedCount/{idx}/Unit").
func leafMatches(suffix, leaf string) bool {
	if !strings.Contains(leaf, tenantprofile.IdxPlaceholder) {
		return strings.HasSuffix(suffix, leaf)
	}
	before, after, _ := strings.Cut(leaf, tenantprofile.IdxPlaceholder)
	// suffix must contain `before` then digits then `after` at its tail.
	i := strings.LastIndex(suffix, before)
	if i < 0 {
		return false
	}
	rest := suffix[i+len(before):]
	// rest = <digits><after>
	if !strings.HasSuffix(rest, after) {
		return false
	}
	digits := rest[:len(rest)-len(after)]
	if digits == "" {
		return false
	}
	for _, c := range digits {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
