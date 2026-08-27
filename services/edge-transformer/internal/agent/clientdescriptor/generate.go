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
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tenantprofile"

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
}

// GenerateOptions gates cutover-readiness.
type GenerateOptions struct {
	// Cutover requires every captured count index be confirmed. When true and any
	// member's index is still inferred, Generate REFUSES and lists them — the
	// ADR-0045 §2.4b "no tenant cuts over on inferred data" rule enforced in code.
	// The default (false, i.e. draft/observe) emits everything so onboarding can
	// proceed up to — but not through — the cutover step.
	Cutover bool
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
		MetricTemplates: d.MetricTemplates,
	}
	if err := p.Validate(); err != nil {
		return nil, fmt.Errorf("generated profile invalid: %w", err)
	}
	return p, nil
}

// GenerateRegisterSQL builds the packml_register INSERT (artifact 2): one row
// per equipment binding packml_topic → id_equipment (+ id_unit, id_enterprise).
// The statement is idempotent (ON CONFLICT on the packml_topic unique key) so a
// re-run after a descriptor edit is safe, and rows are emitted in descriptor
// order for a stable, reviewable diff. active=true because CS Admin authoring a
// descriptor IS the act of activating the topic (CLAUDE.md: "CS Admin creates
// entries (active=true); oeecloud does NOT auto-register").
func (d *Descriptor) GenerateRegisterSQL() string {
	var b strings.Builder
	fmt.Fprintf(&b, "-- packml_register rows for tenant %s (enterprise %d) — generated from the\n",
		d.Tenant, d.EnterpriseID)
	fmt.Fprintf(&b, "-- client descriptor (ADR-0045 P1). DO NOT hand-edit; edit the descriptor + regenerate.\n")
	b.WriteString("INSERT INTO packml_register (id_enterprise, id_equipment, packml_topic, active, id_unit)\nVALUES\n")
	for i, e := range d.Equipment {
		idUnit := "NULL"
		if e.IDUnit != nil {
			idUnit = fmt.Sprintf("%d", *e.IDUnit)
		}
		sep := ","
		if i == len(d.Equipment)-1 {
			sep = ""
		}
		fmt.Fprintf(&b, "    (%d, %d, %s, true, %s)%s\n",
			d.EnterpriseID, e.IDEquipment, sqlQuote(e.Topic), idUnit, sep)
	}
	b.WriteString("ON CONFLICT (packml_topic) DO NOTHING;\n")
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
	cfg := &agentcfg.Config{
		Sparkplug: agentcfg.SparkplugCfg{
			GroupID:          d.Tenant,
			EdgeNodeID:       d.Agent.EdgeNodeID,
			PackMLTopic:      d.Canonical.Prefix,
			InternalBroker:   d.Agent.InternalBroker,
			RawTopic:         d.Agent.RawTopic,
			UplinkBroker:     d.Agent.UplinkBroker,
			UplinkTLSCertRef: d.Agent.MTLS.CertRef,
			UplinkTLSKeyRef:  d.Agent.MTLS.KeyRef,
			UplinkCARef:      d.Agent.MTLS.CARef,
		},
	}
	for _, e := range d.Equipment {
		seg := d.localSegment(e.Topic)
		class := tenantprofile.ClassOf(e.TPEquipment)
		metrics, err := profile.SynthesizeEquipment(seg, class, e.IDEquipment)
		if err != nil {
			return nil, fmt.Errorf("synthesize %s: %w", e.Topic, err)
		}
		for _, m := range metrics {
			cfg.RawTagMap = append(cfg.RawTagMap, agentcfg.TagMapEntry{
				MetricSuffix: m.Suffix,
				Type:         m.Type,
			})
		}
	}
	return cfg, nil
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

	return &Artifacts{
		Profile:     profile,
		ProfileYAML: profileYAML,
		RegisterSQL: d.GenerateRegisterSQL(),
		PositionSQL: d.GenerateEquipmentPositionSQL(),
		AgentConfig: agentCfg,
		AgentYAML:   agentYAML,
		TeeSnippet:  tee,
	}, nil
}
