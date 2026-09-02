package clientdescriptor

// generate.go turns one client descriptor (the SSoT) into the four downstream
// onboarding artifacts (ADR-0045 §2.2 "generate, never hand-edit"):
//
//	1. the tenant conversion profile  (tenantprofile.Profile / *-profile.yaml)
//	2. the packml_register INSERT SQL (topic ↔ id_equipment rows)
//	3. the sparkplug-agent client.yaml (agentcfg.Config)
//	4. the Node-RED tee snippet       (the Tier-1 raw forwarder flow JSON)
//
// The one rule that makes this safe (ADR-0045 §5): a descriptor is VALIDATED as
// a whole before any artifact is emitted, and every generator is a PURE function
// of the (already-valid) descriptor. A quirk lives in exactly one place — the
// descriptor — so the four artifacts cannot drift out of sync, which is the
// entire failure mode of the hand-edited #590→#601 arc this replaces.

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/clientconfig"

	"gopkg.in/yaml.v3"
)

// Artifacts bundles every generated output. YAML/JSON byte forms are produced
// alongside the typed values so a caller can write files without re-marshalling
// (and so a test can assert on either representation).
type Artifacts struct {
	Profile     *tenantprofile.Profile
	ProfileYAML []byte

	RegisterSQL string

	// PositionSQL backfills equipments.position (line flow order) — the
	// persistent substrate for line attribution (ADR-0045 Bronze).
	PositionSQL string

	AgentConfig *agentcfg.Config
	AgentYAML   []byte

	TeeSnippet []byte // Node-RED flow JSON (an array of nodes)

	// ClientYAML is the per-tenant client.yaml (a clientconfig.Config) the Go
	// s7/modbus/opcua-reader loads. Non-nil ONLY when the descriptor carries a
	// plc block; nil otherwise — so a descriptor without plc emits the same four
	// artifacts as before (artifact 5 is strictly additive).
	ClientYAML []byte

	// ReaderFlow is the Node-RED PLC-reader flow (artifact 6): the AUTONOMOUS-edge
	// alternative to the tee — protocol input nodes → normalize → POST raw tags to
	// the local sparkplug-agent, plus a first-class per-client customizations tab.
	// Generated from the SAME descriptor `plc:` block as ClientYAML, so it is non-nil
	// on exactly the same condition (d.PLC != nil) and can never disagree with the Go
	// reader's config; nil otherwise, leaving the historical artifact set unchanged.
	ReaderFlow []byte
}

// GenerateOptions gates cutover-readiness.
type GenerateOptions struct {
	// Cutover requires every captured count index be confirmed. When true and any
	// member's index is still inferred, Generate REFUSES and lists them — the
	// ADR-0045 §2.4b "no tenant cuts over on inferred data" rule enforced in code.
	// The default (false, i.e. draft/observe) emits everything so onboarding can
	// proceed up to — but not through — the cutover step.
	Cutover bool

	// StagingTee, when true, makes the generated Node-RED reader flow (artifact 6)
	// dual-publish: alongside its primary POST to the local sparkplug-agent it adds a
	// second, parallel POST to a staging ingest front door. The staging URL + key are
	// read from env at runtime (<TENANT>_STAGING_TEE_URL / _STAGING_TEE_KEY), so the
	// branch is compiled in but INERT until configured (off by default). Only affects
	// artifact 6; the other artifacts are unchanged.
	StagingTee bool
}

// localSegment returns a topic with the canonical prefix stripped, e.g.
// "CPACK/SC/LINHAS/L5/BREYER" → "/LINHAS/L5/BREYER". Validate() has already
// guaranteed every topic starts with the prefix.
func (d *Descriptor) localSegment(topic string) string {
	return strings.TrimPrefix(topic, d.Canonical.Prefix)
}

// InferredMembers returns, sorted, the topics of every equipment whose captured
// count index is still inferred (not observed on a live tee). Empty ⇒ the
// tenant is cutover-eligible on count-index grounds.
func (d *Descriptor) InferredMembers() []string {
	var out []string
	for _, e := range d.Equipment {
		if e.CountIndex != nil && e.CountIndex.Confidence == ConfidenceInferred {
			out = append(out, e.Topic)
		}
		// A line whose count roles are still inferred is no more cutover-eligible
		// than a member — one inferred role gates the whole line.
		for _, r := range e.LineRoles {
			if r.Confidence == ConfidenceInferred {
				out = append(out, e.Topic)
				break
			}
		}
	}
	sort.Strings(out)
	return out
}

// InferredIndex is one member whose captured count index is still inferred: its
// topic and the (unconfirmed) index value. The onboard API surfaces these so a
// caller (CS-Admin UI / edge-api) can show exactly which channels need a live-tee
// CAPTURE before the tenant is cutover-eligible.
type InferredIndex struct {
	Topic string
	Index int
}

// InferredIndices returns, in descriptor order, every member whose count index is
// still inferred, paired with the captured value. Empty ⇒ cutover-eligible on
// count-index grounds — the same condition Generate(Cutover:true) enforces. It is
// the detail form of InferredMembers (which returns bare topics).
func (d *Descriptor) InferredIndices() []InferredIndex {
	var out []InferredIndex
	for _, e := range d.Equipment {
		if e.CountIndex != nil && e.CountIndex.Confidence == ConfidenceInferred {
			out = append(out, InferredIndex{Topic: e.Topic, Index: e.CountIndex.Value})
		}
		for _, r := range e.LineRoles {
			if r.Confidence == ConfidenceInferred {
				out = append(out, InferredIndex{Topic: e.Topic, Index: r.CountIndex})
			}
		}
	}
	return out
}

// UnmappedTopics returns descriptor topics that synthesize NO canonical metric —
// i.e. equipment that contributes nothing to the agent tag-map / register. Under
// the current templates every well-formed equipment maps, so this is normally
// empty; it is a forward data-quality signal so an onboarding surface can flag a
// member the metric templates don't cover. It reuses the SAME synthesis path
// GenerateAgentConfig uses (SynthesizeEquipment), so it can never disagree with
// what actually gets generated.
func (d *Descriptor) UnmappedTopics() ([]string, error) {
	profile, err := d.GenerateProfile()
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range d.Equipment {
		seg := d.localSegment(e.Topic)
		class := tenantprofile.ClassOf(e.TPEquipment)
		metrics, err := profile.SynthesizeEquipment(seg, class, e.IDEquipment)
		if err != nil {
			return nil, fmt.Errorf("synthesize %s: %w", e.Topic, err)
		}
		if len(metrics) == 0 {
			out = append(out, e.Topic)
		}
	}
	return out, nil
}

// GenerateProfile builds the tenant conversion profile (artifact 1). The
// descriptor's per-member captured count index becomes the profile's
// count_index.overrides map (keyed by LOCAL SEGMENT — exactly how the hand-built
// cpack-full-profile.yaml expresses it), so the register-driven synthesizer
// resolves each member's count leaf to the OBSERVED PLC channel, not the
// register surrogate id (the whole #601 finding).
func (d *Descriptor) GenerateProfile() (*tenantprofile.Profile, error) {
	overrides := map[string]int{}
	for _, e := range d.Equipment {
		if e.CountIndex == nil {
			continue
		}
		overrides[d.localSegment(e.Topic)] = e.CountIndex.Value
	}
	// A tenant with no captured indices has a nil (not empty) map, matching a
	// profile YAML that simply omits the overrides key — so equivalence holds.
	if len(overrides) == 0 {
		overrides = nil
	}
	// Metric templates fallback: a descriptor authored purely through the CS-Admin
	// wizard arrives with an EMPTY metric_templates (the wizard collects equipment +
	// plc tag maps but not the canonical leaf set). With no templates
	// SynthesizeEquipment emits ZERO suffixes, so the agent raw_tag_map allowlist is
	// empty and the client⇄agent §C consistency check rejects EVERY reader tag as
	// unmapped. Fall back to the shared scaffold default (the SAME standard PackML
	// leaves greenfield Scaffold emits) so synthesis always produces the standard
	// leaves. Done at the generation boundary — the stored descriptor is never
	// mutated — and only when BOTH class sets are empty: a descriptor that authors any
	// metric_templates is used verbatim, so a real authored set is never overridden.
	templates := d.MetricTemplates
	if len(templates.Line) == 0 && len(templates.Member) == 0 {
		templates = DefaultMetricTemplates()
	}
	p := &tenantprofile.Profile{
		Tenant:                 d.Tenant,
		EnterpriseID:           d.EnterpriseID,
		TenantPrefix:           d.Canonical.Prefix,
		PrefixFixups:           d.Mapping.PrefixFixups,
		MetricAliases:          d.Mapping.MetricAliases,
		ParameterAliases:       d.Mapping.ParameterAliases,
		ParameterDecomposition: d.Mapping.ParameterDecomposition,
		CountIndex: tenantprofile.CountIndexRule{
			Mode:      d.Mapping.CountIndexDefaultMode,
			Overrides: overrides,
		},
		MetricTemplates: templates,
	}
	// Resolve each equipment's Derived rules into segment-qualified, {idx}-filled
	// profile rules — the form both SynthesizeEquipment (allowlist) and the runtime
	// deriver (values) consume. Resolution reuses the SAME ResolveCountIndex the
	// count templates use, so a derived count leaf and a member count leaf land on
	// the same index.
	derived, err := d.generateDerivedRules(p)
	if err != nil {
		return nil, err
	}
	p.Derived = derived
	if err := p.Validate(); err != nil {
		return nil, fmt.Errorf("generated profile invalid: %w", err)
	}
	return p, nil
}

// generateDerivedRules resolves every equipment's descriptor DerivedMetrics into
// the profile's fully-resolved DerivedRules: leaves prefixed with the equipment
// local segment and {idx} substituted from the equipment's resolved count index
// (via the same p.ResolveCountIndex the templates use). p must already carry the
// count-index rule + overrides (it does — the caller builds it first).
func (d *Descriptor) generateDerivedRules(p *tenantprofile.Profile) ([]tenantprofile.DerivedRule, error) {
	var rules []tenantprofile.DerivedRule
	for _, e := range d.Equipment {
		if len(e.Derived) == 0 {
			continue
		}
		seg := d.localSegment(e.Topic)
		// Resolve the count index once per equipment, lazily: only a leaf carrying
		// {idx} needs it, so an integral/sum on index-free leaves never forces a
		// (possibly failing, in explicit mode) resolution.
		idx := 0
		idxResolved := false
		resolveLeaf := func(leaf string) (string, error) {
			if strings.Contains(leaf, tenantprofile.IdxPlaceholder) {
				if !idxResolved {
					v, err := p.ResolveCountIndex(seg, e.IDEquipment)
					if err != nil {
						return "", fmt.Errorf("equipment %q: derived count index: %w", e.Topic, err)
					}
					idx = v
					idxResolved = true
				}
				leaf = strings.ReplaceAll(leaf, tenantprofile.IdxPlaceholder, strconv.Itoa(idx))
			}
			return seg + leaf, nil
		}
		for _, dm := range e.Derived {
			r := tenantprofile.DerivedRule{Segment: seg, Type: dm.Type}
			for _, leaf := range dm.Emit {
				full, err := resolveLeaf(leaf)
				if err != nil {
					return nil, err
				}
				r.Emit = append(r.Emit, full)
			}
			if dm.Integral != nil {
				src, err := resolveLeaf(dm.Integral.Source)
				if err != nil {
					return nil, err
				}
				r.Integral = &tenantprofile.IntegralSource{
					Source:     src,
					Conversion: dm.Integral.Conversion,
					ClampMin:   dm.Integral.ClampMin,
					MaxRate:    dm.Integral.MaxRate,
				}
			}
			if dm.Sum != nil {
				sum := &tenantprofile.SumSource{}
				for _, a := range dm.Sum.Addends {
					full, err := resolveLeaf(a)
					if err != nil {
						return nil, err
					}
					sum.Addends = append(sum.Addends, full)
				}
				r.Sum = sum
			}
			rules = append(rules, r)
		}
	}
	return rules, nil
}

// GenerateRegisterSQL builds the packml_register INSERT (artifact 2): one row
// per equipment binding packml_topic → id_equipment (+ id_unit, id_enterprise).
// The statement is idempotent. The conflict target carries the `WHERE active`
// predicate to match the PARTIAL unique index the schema deliberately uses —
// `packml_topic_active_un ON packml_register (packml_topic) WHERE active`
// (edge-node-red/db/33-partial-unique-active.sql: only ACTIVE topics are unique,
// so a soft-deleted topic can be re-created). A bare `ON CONFLICT (packml_topic)`
// does NOT match a partial index and errors with "no unique or exclusion
// constraint matching the ON CONFLICT specification". Rows are emitted in descriptor
// order for a stable, reviewable diff. active=true because CS Admin authoring a
// descriptor IS the act of activating the topic (CLAUDE.md: "CS Admin creates
// entries (active=true); oeecloud does NOT auto-register").
func (d *Descriptor) GenerateRegisterSQL() string {
	var b strings.Builder
	fmt.Fprintf(&b, "-- packml_register rows for tenant %s (enterprise %d) — generated from the\n",
		d.Tenant, d.EnterpriseID)
	fmt.Fprintf(&b, "-- client descriptor (ADR-0045 P1). DO NOT hand-edit; edit the descriptor + regenerate.\n")
	b.WriteString("INSERT INTO packml_register (id_enterprise, id_equipment, packml_topic, active, id_unit, device_key)\nVALUES\n")
	for i, e := range d.Equipment {
		idUnit := "NULL"
		if e.IDUnit != nil {
			idUnit = fmt.Sprintf("%d", *e.IDUnit)
		}
		sep := ","
		if i == len(d.Equipment)-1 {
			sep = ""
		}
		// device_key is the DECLARED-else-derived stable identity (ADR-0046 §2),
		// persisted so the register loader + birth resolution key off it instead of
		// re-parsing the topic string.
		fmt.Fprintf(&b, "    (%d, %d, %s, true, %s, %s)%s\n",
			d.EnterpriseID, e.IDEquipment, sqlQuote(e.Topic), idUnit, sqlQuote(e.ResolvedDeviceKey()), sep)
	}
	b.WriteString("ON CONFLICT (packml_topic) WHERE active DO NOTHING;\n")
	// Populate id_site/id_area from the equipment. The stream-engine registry
	// requires them to place a row into equipment_values (id_site/id_area are
	// columns there); a NULL site/area makes the topic read as "topic not
	// registered" and the tenant's counts are SILENTLY DROPPED (verified on
	// staging: bispharma ent 5 decoded fine but never wrote until this backfill).
	// They are not in the descriptor (they are derivable — each equipment belongs
	// to exactly one site/area), so derive them at apply time from equipments.
	// id_equipment is a global PK so this is tenant-precise; idempotent + self-
	// healing (re-running after an equipment moves area fixes the register).
	fmt.Fprintf(&b, "UPDATE packml_register pr\n"+
		"   SET id_site = e.id_site, id_area = e.id_area\n"+
		"  FROM equipments e\n"+
		" WHERE pr.id_equipment = e.id_equipment\n"+
		"   AND pr.id_enterprise = %d\n"+
		"   AND (pr.id_site IS DISTINCT FROM e.id_site OR pr.id_area IS DISTINCT FROM e.id_area);\n",
		d.EnterpriseID)
	return b.String()
}

// GenerateEquipmentPositionSQL builds the equipments.position backfill (artifact
// 2b): one idempotent UPDATE per LINE MEMBER (tp_equipment=1) setting its 1-based
// flow-order rank within its line. This is the persistent, queryable substrate
// for line-level downtime/OEE attribution (ADR-0045 "Bronze" step).
//
// Why it is needed: Parameter30700 — the transient CSV the decoder reads for
// counter aggregation — is never persisted to a column, and for own-stream
// tenants like CPACK it is not published at all (packml_register.line_unit_seq
// NULL on every row, verified against prod packiot40). So nothing else populates
// the flow order; every member's equipments.position stays NULL. This artifact
// closes that gap at onboarding time.
//
// Order source: the descriptor lists a line's members in physical infeed→outfeed
// order (first listed = infeed = position 1, last = outfeed). A single-machine
// cell's lone member is position 1. Members are grouped by their PARENT LINE
// topic (the member topic minus its last segment), preserving descriptor order
// within each group. Lines/sectors (tp_equipment != 1) get no position.
//
// Idempotent: keyed by the id_equipment surrogate (a global PK, so the UPDATE is
// tenant-precise without an enterprise filter), safe to re-run after a descriptor
// edit. The `tp_equipment = 1` guard is belt-and-braces so a line/member sharing
// a name can never be mis-hit.
func (d *Descriptor) GenerateEquipmentPositionSQL() string {
	rankByLine := map[string]int{} // parent-line topic → next 1-based rank
	type row struct{ id, pos int }
	var rows []row
	for _, e := range d.Equipment {
		if e.TPEquipment != 1 {
			continue // only machines (members) carry a within-line flow position
		}
		parent := parentLineTopic(e.Topic)
		rankByLine[parent]++
		rows = append(rows, row{id: e.IDEquipment, pos: rankByLine[parent]})
	}

	var b strings.Builder
	fmt.Fprintf(&b, "-- equipments.position (line flow order) for tenant %s (enterprise %d) —\n", d.Tenant, d.EnterpriseID)
	fmt.Fprintf(&b, "-- generated from the client descriptor (ADR-0045 Bronze). A line's member\n")
	fmt.Fprintf(&b, "-- list order IS the physical infeed→outfeed sequence: first listed = position\n")
	fmt.Fprintf(&b, "-- 1 (infeed), last = outfeed; single-machine cell → position 1. Idempotent.\n")
	fmt.Fprintf(&b, "-- DO NOT hand-edit; edit the descriptor + regenerate.\n")
	for _, r := range rows {
		fmt.Fprintf(&b, "UPDATE equipments SET position = %d WHERE id_equipment = %d AND tp_equipment = 1;\n", r.pos, r.id)
	}
	return b.String()
}

// parentLineTopic strips a member topic's final segment to yield its owning line
// topic, e.g. "CPACK/SC/LINHAS/L3/BREYER" → "CPACK/SC/LINHAS/L3" and the
// single-cell "CPACK/SC/CELULA1/CER400/CER400" → "CPACK/SC/CELULA1/CER400".
func parentLineTopic(topic string) string {
	if i := strings.LastIndex(topic, "/"); i >= 0 {
		return topic[:i]
	}
	return topic
}

// sqlQuote wraps a string in single quotes, doubling any embedded quote. Topics
// are ASCII/uppercase by the canonical model so this is belt-and-braces, but a
// generator that emits SQL must never assume its input is quote-free.
func sqlQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// GenerateAgentConfig builds the sparkplug-agent descriptor (artifact 3). The
// raw_tag_map is SYNTHESIZED from the profile — the same register-driven path
// the runtime loader uses — so the agent's allowlist is generated from the same
// count indices as everything else, never hand-listed. group_id = tenant and
// packml_topic = the canonical prefix; the tee sends metric SUFFIXES only.
func (d *Descriptor) GenerateAgentConfig() (*agentcfg.Config, error) {
	profile, err := d.GenerateProfile()
	if err != nil {
		return nil, err
	}
	// P0-1: a CS-Admin wizard descriptor carries NO agent block (blankDescriptor
	// omits it), so fill any empty field from DefaultAgentWiring — otherwise the
	// generated agent.yaml is missing edge_node_id/internal_broker/uplink_broker,
	// fails agentcfg.Validate, and the shared agent skips-and-alarms it on push
	// (was: crash-looped, taking cpack ingest down). Explicit descriptor values win.
	aw := mergedAgentWiring(d.Tenant, d.Agent)
	cfg := &agentcfg.Config{
		Sparkplug: agentcfg.SparkplugCfg{
			GroupID:          d.Tenant,
			EdgeNodeID:       aw.EdgeNodeID,
			PackMLTopic:      d.Canonical.Prefix,
			InternalBroker:   aw.InternalBroker,
			RawTopic:         aw.RawTopic,
			UplinkBroker:     aw.UplinkBroker,
			UplinkTLSCertRef: aw.MTLS.CertRef,
			UplinkTLSKeyRef:  aw.MTLS.KeyRef,
			UplinkCARef:      aw.MTLS.CARef,
		},
	}
	for _, e := range d.Equipment {
		seg := d.localSegment(e.Topic)
		class := tenantprofile.ClassOf(e.TPEquipment)
		metrics, err := profile.SynthesizeEquipment(seg, class, e.IDEquipment)
		if err != nil {
			return nil, fmt.Errorf("synthesize %s: %w", e.Topic, err)
		}
		// device_key is stamped on every one of this equipment's tag-map entries so
		// the runtime birth (session → birth.CounterMetricPropsWithDeviceKey) emits
		// the DECLARED identity instead of re-deriving it from the metric name
		// (ADR-0046 §2). All of an equipment's metrics share one device key.
		dk := e.ResolvedDeviceKey()
		for _, m := range metrics {
			cfg.RawTagMap = append(cfg.RawTagMap, agentcfg.TagMapEntry{
				MetricSuffix: m.Suffix,
				Type:         m.Type,
				DeviceKey:    dk,
			})
		}
		// A line's line_roles add indexed count leaves the class template can't
		// (the line templates are bare/non-routable). Each becomes a numeric-
		// routable suffix `<seg>/Admin/Prod<Role>Count/<idx>/Unit` so the tee's
		// gross/net channels land on THIS line's id_equipment.
		for _, m := range lineRoleMetrics(seg, dk, e.LineRoles) {
			cfg.RawTagMap = append(cfg.RawTagMap, m)
		}
	}
	// ADR-0045 counter_derive: carry each count tag's derivation mode from the plc
	// tag map onto its matching raw_tag_map entry, so the agent-side counterderive
	// stage (which loads agent.yaml, not client.yaml) knows how to synthesize the
	// missing gross/net/scrap siblings. This is a pure join on the SAME suffix key
	// the §C consistency check uses; a mode of ""/full/none is a pass-through and is
	// NOT stamped, so a descriptor without counter_derive generates a byte-identical
	// agent.yaml.
	d.stampCounterDerive(cfg)
	// P0-1 (validate at generate time): run the SAME check the runtime applies in
	// agentcfg.Load, so a descriptor that would yield an unloadable agent.yaml
	// fails HERE (generate → 400) instead of silently emitting a bad file that the
	// shared agent then skips on push. With the defaults above this passes for any
	// wizard descriptor that has at least one equipment (a non-empty raw_tag_map).
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("generated agent config is invalid (descriptor would produce an unloadable agent.yaml): %w", err)
	}
	return cfg, nil
}

// stampCounterDerive copies each plc tag map count tag's counter_derive mode onto
// the matching raw_tag_map entry, keyed by the emitted metric SUFFIX (the same key
// checkClientAgentConsistency matches on: <packml_topic><metric> with the
// canonical prefix stripped). A no-op mode (""/full/none) is skipped so the
// generated agent.yaml is byte-identical when no derivation is declared. A tag
// whose suffix has no raw_tag_map entry is silently ignored here — the §C
// consistency check (run separately) is what fails loudly on such a mismatch.
func (d *Descriptor) stampCounterDerive(cfg *agentcfg.Config) {
	if d.PLC == nil {
		return
	}
	idx := make(map[string]int, len(cfg.RawTagMap))
	for i, e := range cfg.RawTagMap {
		idx[e.MetricSuffix] = i
	}
	stamp := func(packmlTopic, metric, mode string) {
		if mode == "" || mode == counterDeriveFull || mode == counterDeriveNone {
			return
		}
		suffix := strings.TrimPrefix(packmlTopic+metric, d.Canonical.Prefix)
		if i, ok := idx[suffix]; ok {
			cfg.RawTagMap[i].CounterDerive = mode
		}
	}
	for _, m := range d.PLC.S7TagMap {
		for _, t := range m.Tags {
			stamp(m.PackMLTopic, t.Metric, t.CounterDerive)
		}
	}
	for _, m := range d.PLC.ModbusTagMap {
		for _, t := range m.Tags {
			stamp(m.PackMLTopic, t.Metric, t.CounterDerive)
		}
	}
	for _, m := range d.PLC.OPCUATagMap {
		for _, t := range m.Tags {
			stamp(m.PackMLTopic, t.Metric, t.CounterDerive)
		}
	}
}

// counterDeriveFull / counterDeriveNone are the pass-through counter_derive tokens
// (mirrors clientconfig.CounterDeriveFull / CounterDeriveNone) that the stamp step
// skips. Duplicated locally to avoid widening this generator's import surface for
// two string constants.
const (
	counterDeriveFull = "full"
	counterDeriveNone = "none"
)

// lineRoleMetrics expands a line's line_roles into indexed count-leaf tag-map
// entries. seg is the line's local segment (prefix already stripped). The leaf
// shape `/Admin/Prod<Role>Count/<idx>/Unit` matches the member count template so
// numeric.countIndexOf routes the tee's <idx> channel onto it and the
// oeecloud-worker classifier assigns the same role a member of that role gets.
// Type is "double" to match the count templates. Validate() has already checked
// the roles + index uniqueness, so this is a pure expansion.
func lineRoleMetrics(seg, deviceKey string, roles []LineRole) []agentcfg.TagMapEntry {
	if len(roles) == 0 {
		return nil
	}
	out := make([]agentcfg.TagMapEntry, 0, len(roles))
	for _, r := range roles {
		leaf := lineRoleLeaf[r.Role] // validated present
		out = append(out, agentcfg.TagMapEntry{
			MetricSuffix: fmt.Sprintf("%s/Admin/%s/%d/Unit", seg, leaf, r.CountIndex),
			Type:         "double",
			DeviceKey:    deviceKey,
		})
	}
	return out
}

// GenerateTeeSnippet builds the Node-RED tee flow (artifact 4): a raw SparkPlug
// forwarder that POSTs to the ingest front-door. It is fully PARAMETERIZED from
// the descriptor's tee block (ingest URL, key env, gateway) + the tenant group,
// so a new client's tee is generated, never copy-pasted-and-fixed. The ingest
// key is read from a Node-RED env var at runtime — the flow file never carries a
// secret (ADR-0004 Layer-2).
func (d *Descriptor) GenerateTeeSnippet() ([]byte, error) {
	p := strings.ToLower(d.Tenant) // node-id prefix + default gateway stem
	keyEnv := d.Tee.IngestKeyEnv
	if keyEnv == "" {
		keyEnv = strings.ToUpper(d.Tenant) + "_INGEST_KEY"
	}
	gateway := d.Tee.Gateway
	if gateway == "" {
		gateway = p + "-edge"
	}
	verify := !d.Tee.TLSInsecure

	tabID := p + "_tab"
	fnID := p + "_fn"
	httpID := p + "_http"
	switchID := p + "_route"
	okID := p + "_ok"
	errID := p + "_err"
	tlsID := p + "_tls"

	fnBody := teeFunctionBody(d.Tenant, gateway, keyEnv)

	nodes := []map[string]any{
		{
			"id":       tabID,
			"type":     "tab",
			"label":    d.Tenant + " ingest tee",
			"disabled": false,
			"info": "Generated from the ADR-0045 client descriptor. Wire your SparkPlug-assembly " +
				"node's output into '" + d.Tenant + " tee'. Set env " + keyEnv + " to the ingest key (never hardcode).",
		},
		{
			"id": fnID, "type": "function", "z": tabID,
			"name":    d.Tenant + " tee (set headers + key)",
			"func":    fnBody,
			"outputs": 1, "noerr": 0, "initialize": "", "finalize": "", "libs": []any{},
			"x": 320, "y": 120, "wires": []any{[]any{httpID}},
		},
		{
			"id": httpID, "type": "http request", "z": tabID,
			"name":   "POST " + d.Tee.IngestURL,
			"method": "POST", "ret": "obj", "paytoqs": "ignore",
			"url": d.Tee.IngestURL, "tls": tlsID, "persist": false, "proxy": "",
			"insecureHTTPParser": false, "authType": "", "senderr": true,
			"headers": []any{},
			"x":       620, "y": 120, "wires": []any{[]any{switchID}},
		},
		{
			"id": switchID, "type": "switch", "z": tabID,
			"name": "statusCode", "property": "statusCode", "propertyType": "msg",
			"rules": []any{
				map[string]any{"t": "eq", "v": "202", "vt": "num"},
				map[string]any{"t": "else"},
			},
			"checkall": "false", "repair": false, "outputs": 2,
			"x": 840, "y": 120, "wires": []any{[]any{okID}, []any{errID}},
		},
		{
			"id": okID, "type": "debug", "z": tabID, "name": "202 accepted",
			"active": true, "tosidebar": true, "console": false, "complete": "statusCode",
			"x": 1030, "y": 90, "wires": []any{},
		},
		{
			"id": errID, "type": "debug", "z": tabID, "name": "NOT 202 (see README)",
			"active": true, "tosidebar": true, "console": true, "complete": "payload",
			"x": 1050, "y": 160, "wires": []any{},
		},
		{
			"id": tlsID, "type": "tls-config",
			"name":             d.Tenant + " ingest (self-signed ok=" + fmt.Sprintf("%t", d.Tee.TLSInsecure) + ")",
			"verifyservercert": verify,
			"cert":             "", "key": "", "ca": "", "certname": "", "keyname": "", "caname": "",
			"servername": "", "alpnprotocol": "",
		},
	}
	out, err := json.MarshalIndent(nodes, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal tee snippet: %w", err)
	}
	return append(out, '\n'), nil
}

// teeFunctionBody renders the tee `function` node body. It reads the ingest key
// from the environment, normalizes the payload to the { timestamp, gateway,
// metrics[] } envelope the worker's sparkplug.Parse expects, guards against an
// empty metrics array, and sets the two headers the shim requires. The tenant
// group is stamped in a comment so the reviewer can see the scope guard target.
func teeFunctionBody(tenant, gateway, keyEnv string) string {
	return "// " + tenant + " → ingest tee — generated from the ADR-0045 client descriptor.\n" +
		"// Place on a SECOND wire off your SparkPlug-assembly node (a tee, not a redirect).\n" +
		"// The shim enforces the group scope (first topic segment) = \"" + tenant + "\" and routes\n" +
		"// the tenant on lower(\"" + tenant + "\"). Key is read from env " + keyEnv + " — NEVER hardcoded.\n" +
		"\n" +
		"const key = env.get(\"" + keyEnv + "\");\n" +
		"if (!key) {\n" +
		"    node.error(\"" + keyEnv + " env var is not set — refusing to POST without an ingest key\", msg);\n" +
		"    return null;\n" +
		"}\n" +
		"\n" +
		"let envelope = msg.payload;\n" +
		"if (Array.isArray(envelope)) {\n" +
		"    envelope = { timestamp: Date.now(), gateway: \"" + gateway + "\", metrics: envelope };\n" +
		"} else if (envelope && !envelope.timestamp) {\n" +
		"    envelope.timestamp = Date.now();\n" +
		"}\n" +
		"if (!envelope || !Array.isArray(envelope.metrics) || envelope.metrics.length === 0) {\n" +
		"    node.warn(\"tee: payload has no metrics[]; skipping this message\");\n" +
		"    return null;\n" +
		"}\n" +
		"\n" +
		"msg.headers = { \"Content-Type\": \"application/json\", \"X-Ingest-Key\": key };\n" +
		"msg.payload = envelope;\n" +
		"return msg;\n"
}

// GenerateClientYAML builds the per-tenant client.yaml (artifact 5) the Go PLC
// readers load: a clientconfig.Config assembled from the descriptor's plc block.
// It is only meaningful when d.PLC != nil (returns an error otherwise — callers
// gate on d.PLC before calling, and Generate only invokes it when present).
//
// Three guarantees before it returns bytes:
//  1. the assembled config passes the REAL clientconfig validator (the same code
//     the readers run at boot) — via clientconfig.Config.Validate, so there is one
//     source of truth for client.yaml validity and no drift from a reimplemented
//     copy;
//  2. the client⇄agent consistency invariant holds (checkClientAgentConsistency);
//  3. it marshals to YAML.
func (d *Descriptor) GenerateClientYAML() (string, error) {
	if d.PLC == nil {
		return "", fmt.Errorf("descriptor has no plc block — nothing to generate for client.yaml")
	}
	cfg, err := d.toClientConfig()
	if err != nil {
		return "", err
	}
	if err := cfg.Validate(); err != nil {
		return "", fmt.Errorf("generated client.yaml invalid: %w", err)
	}
	if err := d.checkClientAgentConsistency(cfg); err != nil {
		return "", err
	}
	out, err := yaml.Marshal(cfg)
	if err != nil {
		return "", fmt.Errorf("marshal client.yaml: %w", err)
	}
	return string(out), nil
}

// toClientConfig assembles the clientconfig.Config from the descriptor. The tag
// maps are copied by reference (same clientconfig types); the endpoints are
// mapped field-for-field, dropping only the descriptor-only Protocol token —
// which is folded into PLC.Protocol when the tenant is single-protocol (the
// common case) and left empty for a mixed-protocol tenant (each reader still
// selects its endpoint by name). Environment is not modeled on the descriptor;
// it is a deploy-time concern, so a safe "staging" default is emitted that keeps
// the config loadable — the ops team's placed client.yaml supplies the real one.
func (d *Descriptor) toClientConfig() (*clientconfig.Config, error) {
	cfg := &clientconfig.Config{
		SchemaVersion: "1.1",
		TenantID:      strings.ToLower(d.Tenant),
		Customer:      d.Tenant,
		Environment:   "staging",
		// The reader strips this off each full metric in raw-emit mode to emit the
		// group-relative metric_suffix the agent resolves by (packml_topic here IS
		// the tenant/site prefix). Same value the agent carries as its packml_topic.
		CanonicalPrefix: d.Canonical.Prefix,
	}
	if d.PLC == nil {
		return cfg, nil
	}
	eps := make([]clientconfig.PLCEndpoint, 0, len(d.PLC.Endpoints))
	protos := map[string]bool{}
	for _, raw := range d.PLC.Endpoints {
		ep := d.resolvedEndpoint(raw) // inherit protocol/rack/slot from its plc type
		protos[ep.Protocol] = true
		eps = append(eps, clientconfig.PLCEndpoint{
			Name:            ep.Name,
			HostRef:         ep.HostRef,
			Rack:            ep.Rack,
			Slot:            ep.Slot,
			UnitID:          ep.UnitID,
			EndpointURLRef:  ep.EndpointURLRef,
			SecurityPolicy:  ep.SecurityPolicy,
			SecurityMode:    ep.SecurityMode,
			PollingInterval: ep.PollingInterval,
		})
	}
	plc := &clientconfig.PLC{Endpoints: eps}
	if len(protos) == 1 {
		for p := range protos {
			plc.Protocol = p
		}
	}
	cfg.PLC = plc
	// S7 tag map is the EXPLICIT entries plus the type-expanded ones (ADR-0050);
	// modbus/opcua have no type expansion yet, so they are copied verbatim.
	s7Map, err := d.effectiveS7TagMap()
	if err != nil {
		return nil, err
	}
	cfg.S7TagMap = s7Map
	cfg.ModbusTagMap = d.PLC.ModbusTagMap
	cfg.OPCUATagMap = d.PLC.OPCUATagMap
	return cfg, nil
}

// effectiveS7TagMap returns the S7 tag map the client.yaml, the reader flow, and
// the §C check all consume: every EXPLICIT s7_tag_map entry, PLUS the type-expanded
// entries for each endpoint that references an S7 plc type and has NO explicit entry
// (ADR-0050 precedence: explicit > type > nothing). Explicit entries keep their
// declared order and win intact — the escape hatch for an irregular PLC. Nil when
// nothing is produced, so a descriptor without types/tags stays byte-identical.
func (d *Descriptor) effectiveS7TagMap() ([]clientconfig.S7EndpointTags, error) {
	if d.PLC == nil {
		return nil, nil
	}
	out := make([]clientconfig.S7EndpointTags, 0, len(d.PLC.S7TagMap))
	// explicitTopics[endpoint][packml_topic] = an explicit s7 entry already binds this
	// member. Precedence is PER MEMBER (ADR-0050: "explicit tag entry > type"): an
	// explicit entry overrides ONLY its own member's expansion, so overriding one
	// irregular sensor never silently drops the rest of the line's counters.
	explicitTopics := map[string]map[string]bool{}
	for _, m := range d.PLC.S7TagMap {
		out = append(out, m)
		if explicitTopics[m.Endpoint] == nil {
			explicitTopics[m.Endpoint] = map[string]bool{}
		}
		explicitTopics[m.Endpoint][m.PackMLTopic] = true
	}
	var profile *tenantprofile.Profile // built lazily; only expansion needs it
	for _, ep := range d.PLC.Endpoints {
		if ep.Type == "" {
			continue
		}
		t, ok := d.plcType(ep.Type)
		if !ok || t.Protocol != PLCProtocolS7 {
			// A dangling ref is reported by validatePLC with context; a non-S7 type
			// does not expand into the S7 map (modbus/opcua expansion is future work).
			continue
		}
		if profile == nil {
			p, err := d.GenerateProfile()
			if err != nil {
				return nil, err
			}
			profile = p
		}
		entries, err := d.expandS7TypeEndpoint(profile, ep, t, explicitTopics[ep.Name])
		if err != nil {
			return nil, err
		}
		out = append(out, entries...)
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

// expandS7TypeEndpoint joins one S7 endpoint's plc type with its line's members to
// synthesize that line's s7_tag_map entries (ADR-0050 §2). For each member (tp=1)
// on the endpoint's line it picks the register offset from the type's
// sensor_offsets by the member's sensor key, and pairs it with the SAME canonical
// count leaf SynthesizeEquipment builds for that member —
// /Admin/ProdProcessedCount/<resolved count_index>/Unit. Because both this map and
// the agent raw_tag_map derive that leaf from the same member + count_index +
// metric_templates, they satisfy the §C invariant BY CONSTRUCTION (no hand-authored
// physical/canonical pair to drift). One S7EndpointTags per member (each member is
// its own equipment/topic).
//
// Skip vs error, per member:
//   - a member with an EXPLICIT s7 entry (in explicitTopics) is skipped — that entry
//     overrides the type for this member only (ADR-0050 per-member precedence);
//   - a NON-sensor member (no leading S<n> token, e.g. SCRAP) is skipped — a gap by
//     design; its cross-register scrap lives in the type's `derive` block (§4);
//   - a member that DOES look like a sensor (S<n>) but has no matching offset is an
//     ERROR (a typo / missing offset would otherwise SILENTLY drop a real counter —
//     the §C check is reader→agent only and cannot catch a dropped reader tag);
//   - two members resolving to the SAME sensor key is an ERROR (they would bind the
//     same register — a silent mis-read).
func (d *Descriptor) expandS7TypeEndpoint(profile *tenantprofile.Profile, ep DescriptorPLCEndpoint, t PLCType, explicitTopics map[string]bool) ([]clientconfig.S7EndpointTags, error) {
	members := d.membersOnEndpointLine(ep)
	if len(members) == 0 {
		return nil, fmt.Errorf(
			"plc.endpoints %q: type %q expands to NO members — no tp=1 equipment on line %s "+
				"(check the endpoint name matches a line's final topic segment, or set the endpoint's `line`)",
			ep.Name, ep.Type, endpointLineLabel(ep))
	}
	// Guard an AMBIGUOUS name match: when the endpoint resolves its line by NAME
	// (no explicit `line:`) and the matched members span more than one line — two
	// lines that share a final segment, e.g. .../A/L01 and .../B/L01 — the expansion
	// target is ambiguous. Fail loudly rather than silently pull a foreign line's
	// members onto this endpoint. A pinned `line:` is exact, so it is exempt.
	if ep.Line == "" {
		lines := map[string]bool{}
		for _, m := range members {
			lines[parentLineTopic(m.Topic)] = true
		}
		if len(lines) > 1 {
			names := make([]string, 0, len(lines))
			for l := range lines {
				names = append(names, l)
			}
			sort.Strings(names)
			return nil, fmt.Errorf(
				"plc.endpoints %q: name %q matches members on %d different lines (%s) — set the endpoint's `line:` to the intended line topic to disambiguate",
				ep.Name, ep.Name, len(lines), strings.Join(names, ", "))
		}
	}
	// The NET production leaf, resolved once from the shared role→leaf map so the
	// generated metric can never diverge from the member template / worker classifier.
	netLeaf := lineRoleLeaf[LineRoleProcessed] // "ProdProcessedCount"
	seenKey := map[string]string{}             // sensor key → the member topic that claimed it
	var out []clientconfig.S7EndpointTags
	for _, m := range members {
		if explicitTopics[m.Topic] {
			continue // hand-authored — the explicit entry overrides the type for THIS member
		}
		key := sensorKeyOf(lastSegment(m.Topic))
		if key == "" {
			continue // non-sensor member (e.g. SCRAP) — a gap by design (derive block, §4)
		}
		offset, ok := t.SensorOffsets[key]
		if !ok {
			return nil, fmt.Errorf(
				"plc.endpoints %q: member %s has sensor key %q with no offset in type %q sensor_offsets "+
					"(a missing/typo'd offset would SILENTLY drop this counter) — add the offset, or move a "+
					"derived/uncounted sensor to the type's derive block (ADR-0050 §4)",
				ep.Name, m.Topic, key, ep.Type)
		}
		if prev, dup := seenKey[key]; dup {
			return nil, fmt.Errorf(
				"plc.endpoints %q: sensor key %q is claimed by both %s and %s — two members cannot share "+
					"one register offset (rename one, or give it an explicit s7_tag_map entry)",
				ep.Name, key, prev, m.Topic)
		}
		seenKey[key] = m.Topic
		seg := d.localSegment(m.Topic)
		idx, err := profile.ResolveCountIndex(seg, m.IDEquipment)
		if err != nil {
			return nil, fmt.Errorf("plc.endpoints %q: member %s: %w", ep.Name, m.Topic, err)
		}
		out = append(out, clientconfig.S7EndpointTags{
			Endpoint:    ep.Name,
			PackMLTopic: m.Topic,
			IDEquipment: m.IDEquipment,
			Tags: []clientconfig.S7Tag{{
				Metric: fmt.Sprintf("/Admin/%s/%d/Unit", netLeaf, idx),
				DB:     t.DB,
				Offset: offset,
				Type:   t.Word,
			}},
		})
	}
	return out, nil
}

// membersOnEndpointLine returns the tp=1 members whose parent line matches the
// endpoint's line. The line is ep.Line (a full line topic) when set, else the line
// whose FINAL topic segment equals ep.Name (the ADR-0050 terse `name: L01` form).
// Descriptor order is preserved so the expanded map has a stable, reviewable diff.
func (d *Descriptor) membersOnEndpointLine(ep DescriptorPLCEndpoint) []Equipment {
	var out []Equipment
	for _, e := range d.Equipment {
		if e.TPEquipment != 1 {
			continue
		}
		parent := parentLineTopic(e.Topic)
		if ep.Line != "" {
			if parent == ep.Line {
				out = append(out, e)
			}
			continue
		}
		if lastSegment(parent) == ep.Name {
			out = append(out, e)
		}
	}
	return out
}

// endpointLineLabel names the line an endpoint targets, for a precise expansion
// error: the pinned ep.Line topic when set, else the name it matches on.
func endpointLineLabel(ep DescriptorPLCEndpoint) string {
	if ep.Line != "" {
		return ep.Line
	}
	return "*/" + ep.Name
}

// checkClientAgentConsistency enforces the ADR-0045 §C invariant that keeps the
// two independently-authored artifacts in lockstep: EVERY full SparkPlug metric
// the client.yaml tag maps produce — which each reader forms as
// <packml_topic><tag.metric> (s7/modbus/opcua mapping.go TagsForEndpoint) — MUST
// resolve to an entry in the generated agent.yaml raw_tag_map. If one does not,
// the agent SILENTLY DROPS the reader's tag as unmapped and the metric never
// reaches Calc — a data-loss bug invisible until someone notices a dead counter.
//
// Why a check and not derivation: the plc tag map carries PHYSICAL addressing
// (S7 db/offset, Modbus register, OPC-UA node_id) the equipment-template
// synthesis has no source for, so the two are authored independently. The only
// way to trust they line up is to verify it — here, at generate time, failing
// loudly with the exact offending metric(s).
//
// The comparison is on FULL metric names (agent FullName = packml_topic prefix +
// metric_suffix), so it is independent of how the agent strips the prefix at
// runtime — the same string the reader puts on the wire is the one we match.
func (d *Descriptor) checkClientAgentConsistency(cfg *clientconfig.Config) error {
	agentCfg, err := d.GenerateAgentConfig()
	if err != nil {
		return err
	}
	// The agent resolves an incoming raw tag by matching its metric DIRECTLY
	// against raw_tag_map.metric_suffix (sparkplug-agent newResolver keys byName
	// on e.MetricSuffix; Resolve does NOT strip the packml_topic). The reader, in
	// raw-emit mode, emits <s7_tag_map.packml_topic><tag.metric> with the
	// canonical_prefix TrimPrefix'd off (clientconfig.CanonicalPrefix). So the
	// consistency key is the SUFFIX, and we must strip the same prefix here.
	agentSuffix := make(map[string]bool, len(agentCfg.RawTagMap))
	for _, e := range agentCfg.RawTagMap {
		agentSuffix[e.MetricSuffix] = true
	}
	var missing []string
	check := func(packmlTopic, metric string) {
		emitted := strings.TrimPrefix(packmlTopic+metric, cfg.CanonicalPrefix)
		if !agentSuffix[emitted] {
			missing = append(missing, emitted)
		}
	}
	for _, m := range cfg.S7TagMap {
		for _, t := range m.Tags {
			check(m.PackMLTopic, t.Metric)
		}
	}
	for _, m := range cfg.ModbusTagMap {
		for _, t := range m.Tags {
			check(m.PackMLTopic, t.Metric)
		}
	}
	for _, m := range cfg.OPCUATagMap {
		for _, t := range m.Tags {
			check(m.PackMLTopic, t.Metric)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return fmt.Errorf(
			"client.yaml ⇄ agent.yaml mismatch: %d reader metric(s) have NO matching raw_tag_map metric_suffix "+
				"(the agent resolves by metric_suffix and would DROP these as unmapped, ADR-0045 §C) — each plc "+
				"tag-map <packml_topic><metric> with canonical_prefix stripped must EQUAL a raw_tag_map "+
				"metric_suffix; align the tag metric to the equipment's template leaf + resolved count index: %s",
			len(missing), strings.Join(missing, ", "))
	}
	return nil
}

// Generate produces the full artifact set from a descriptor, enforcing the
// cutover gate. It is the one entry point a caller (CLI / CS-Admin surface)
// should use.
func (d *Descriptor) Generate(opts GenerateOptions) (*Artifacts, error) {
	if opts.Cutover {
		if inferred := d.InferredMembers(); len(inferred) > 0 {
			return nil, fmt.Errorf(
				"refusing to generate CUTOVER-ready config: %d count index(es) still inferred "+
					"(ADR-0045 §2.4b — no tenant cuts over on inferred data); confirm via a live "+
					"tee CAPTURE first: %s",
				len(inferred), strings.Join(inferred, ", "))
		}
	}

	profile, err := d.GenerateProfile()
	if err != nil {
		return nil, err
	}
	profileYAML, err := yaml.Marshal(profile)
	if err != nil {
		return nil, fmt.Errorf("marshal profile: %w", err)
	}

	agentCfg, err := d.GenerateAgentConfig()
	if err != nil {
		return nil, err
	}
	agentYAML, err := yaml.Marshal(agentCfg)
	if err != nil {
		return nil, fmt.Errorf("marshal agent config: %w", err)
	}

	tee, err := d.GenerateTeeSnippet()
	if err != nil {
		return nil, err
	}

	// Artifacts 5 (client.yaml) AND 6 (Node-RED reader flow) are BOTH emitted ONLY
	// when the descriptor carries a plc block — they are the two consumers of the
	// SAME `plc:` source of truth (the Go reader's config and the Node-RED reader's
	// flow), so a tenant can deploy either reader off one descriptor. A descriptor
	// without a plc block produces exactly the historical four artifacts.
	var clientYAML, readerFlow []byte
	if d.PLC != nil {
		s, err := d.GenerateClientYAML()
		if err != nil {
			return nil, err
		}
		clientYAML = []byte(s)

		rf, err := d.GeneratePlcReaderFlow(ReaderFlowOptions{StagingTee: opts.StagingTee})
		if err != nil {
			return nil, fmt.Errorf("generate plc reader flow: %w", err)
		}
		readerFlow = rf
	}

	return &Artifacts{
		Profile:     profile,
		ProfileYAML: profileYAML,
		RegisterSQL: d.GenerateRegisterSQL(),
		PositionSQL: d.GenerateEquipmentPositionSQL(),
		AgentConfig: agentCfg,
		AgentYAML:   agentYAML,
		TeeSnippet:  tee,
		ClientYAML:  clientYAML,
		ReaderFlow:  readerFlow,
	}, nil
}
