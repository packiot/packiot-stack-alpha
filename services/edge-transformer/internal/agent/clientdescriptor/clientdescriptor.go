// Package clientdescriptor is the CS-Admin CLIENT DESCRIPTOR — the single
// source of truth (SSoT) a Customer Success engineer authors to onboard one
// tenant, and the generator that turns it into the four downstream artifacts
// (ADR-0045 P1).
//
// The problem it solves
// ---------------------
// The CPACK onboarding arc (#590 → #593/ADR-0043 → #601 → #602/ADR-0044) built
// the RUNTIME mechanism to convert a client's raw PLC tags into the platform's
// canonical SparkPlug model — a per-tenant conversion profile, a register-driven
// tag-map loader, id-driven Parameter decomposition. But that arc was performed
// BY HAND, one discovery at a time, editing FOUR artifacts per tenant:
//
//  1. the tenant conversion profile (tenantprofile: prefix/alias/param/count)
//  2. the packml_register rows (topic ↔ id_equipment)
//  3. the agent client.yaml (agentcfg: sparkplug identity, brokers, mTLS, tags)
//  4. the Node-RED tee snippet (the Tier-1 raw forwarder)
//
// Four hand-edited artifacts that must stay perfectly consistent do not scale to
// N factories and drift silently. ADR-0045 §2.2 replaces them with ONE descriptor
// that GENERATES all four: "the descriptor is the only thing a human writes."
//
// What the descriptor carries (ADR-0045 §2.1/§2.2)
// ------------------------------------------------
//   - tenant identity + enterprise_id (the register cross-tenant guard)
//   - the canonical topic prefix (tenant_prefix)
//   - the raw→canonical mapping: the per-client quirks (prefix fixups, metric
//     aliases, parameter aliases/decomposition), normalized STACK-SIDE in the
//     agent profile (ADR-0045 §2.3 Option B — the tee stays a dumb forwarder)
//   - the line-vs-member metric templates (the canonical metric leaves)
//   - the equipment inventory: lines (tp=3) + members (tp=1), each with its
//     id_equipment, id_unit, and — for members — the CAPTURED count index with a
//     confidence flag (confirmed | inferred)
//   - agent wiring (edge node id, brokers, mTLS refs) + tee parameters
//
// The confirmed-vs-inferred discipline (ADR-0045 §2.4b)
// -----------------------------------------------------
// A member's count index is an arbitrary PLC channel number — NOT derivable from
// any table (#601). It is OBSERVED from a live tee, member by member, and tagged
// confirmed or inferred. The generator refuses to emit a cutover-ready config
// while any inferred index remains: "no tenant cuts over on inferred data."
package clientdescriptor

import (
	"fmt"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tenantprofile"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
)

// secretScheme is the prefix for a SECRET reference in the plc block — the
// descriptor NEVER carries a secret VALUE inline, only a pointer into the secret
// store. A plain host, being network config rather than a secret, may instead be
// a literal (mirrors clientconfig.validateV11 Rule 1a).
const secretScheme = "secret://"

// PLC endpoint protocol tokens. They select which Go reader
// (s7/modbus/opcua-reader) drives an endpoint, and gate which tag map may
// reference it (an s7_tag_map may only reference an s7 endpoint, etc).
const (
	PLCProtocolS7        = "s7"
	PLCProtocolModbusTCP = "modbus_tcp"
	PLCProtocolOPCUA     = "opcua"
)

// deviceKeyPattern constrains a DECLARED device_key to the same safe charset the
// SparkPlug <device_id> / packml_register.device_key accept: alphanumerics plus
// dot, underscore, hyphen. It deliberately excludes "/" — a device_key is the
// FLAT identity string, not a topic path (the dash form of the topic, ADR-0046 §2).
var deviceKeyPattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// Confidence tags a captured count index. Only a confirmed index — observed on a
// real tee payload — is cutover-eligible (ADR-0045 §2.4b).
const (
	ConfidenceConfirmed = "confirmed"
	ConfidenceInferred  = "inferred"
)

// LineRole roles select the canonical count leaf for a line-level count binding.
// Naming mirrors the platform's counter-intuitive leaves (see LineRole doc):
// consumed=GROSS total, processed=NET good, defective=scrap.
const (
	LineRoleConsumed  = "consumed"  // → /Admin/ProdConsumedCount/<idx>/Unit  (gross)
	LineRoleProcessed = "processed" // → /Admin/ProdProcessedCount/<idx>/Unit (net/good)
	LineRoleDefective = "defective" // → /Admin/ProdDefectiveCount/<idx>/Unit (scrap)
)

// lineRoleLeaf maps a LineRole role to its canonical count-leaf metric name. The
// generator fills `/Admin/<leaf>/<idx>/Unit` from this — the same leaf strings
// the member template and the oeecloud-worker classifier key off, so a line-role
// count is classified identically to a member count of the same role.
var lineRoleLeaf = map[string]string{
	LineRoleConsumed:  "ProdConsumedCount",
	LineRoleProcessed: "ProdProcessedCount",
	LineRoleDefective: "ProdDefectiveCount",
}

// Descriptor is the parsed client descriptor — the CS-Admin SSoT.
type Descriptor struct {
	// Tenant is the SparkPlug group_id / enterprise short-name, e.g. "CPACK".
	Tenant string `yaml:"tenant"`

	// EnterpriseID is the packml_register.id_enterprise the register loader
	// scopes to (cross-tenant guard) and the value emitted in the register SQL.
	EnterpriseID int `yaml:"enterprise_id"`

	// Canonical declares the canonical (post-fixup) topic model.
	Canonical Canonical `yaml:"canonical"`

	// Mapping is the raw→canonical quirk absorber — copied verbatim into the
	// generated tenant conversion profile.
	Mapping Mapping `yaml:"mapping"`

	// MetricTemplates are the per-class canonical metric leaves (reused directly
	// as the profile's metric_templates).
	MetricTemplates tenantprofile.MetricTemplates `yaml:"metric_templates"`

	// Equipment is the tenant inventory: lines (tp=3) + members (tp=1).
	Equipment []Equipment `yaml:"equipment"`

	// Agent is the sparkplug-agent wiring → client.yaml (agentcfg).
	Agent AgentWiring `yaml:"agent"`

	// Tee parameterizes the generated Node-RED tee snippet.
	Tee TeeParams `yaml:"tee"`

	// PLC is the OPTIONAL PLC-connectivity + tag-map block. When present the
	// generator emits a 5th artifact, <tenant>-client.yaml (a clientconfig.Config
	// the Go s7/modbus/opcua-reader loads). When absent (nil) the descriptor
	// behaves EXACTLY as before — the four-artifact set is unchanged — so every
	// descriptor authored before this field keeps generating byte-identically.
	PLC *DescriptorPLC `yaml:"plc,omitempty"`
}

// DescriptorPLC is the descriptor's PLC-connectivity + tag-map section. It maps
// 1:1 onto the clientconfig.Config PLC surface the readers consume: the three
// tag-map slices are the SAME clientconfig types (reused verbatim, so a client.yaml
// tag map is a faithful copy with zero translation loss), and Endpoints mirror
// clientconfig.PLCEndpoint field-for-field plus a per-endpoint Protocol token
// (which clientconfig's PLCEndpoint does not carry) so the descriptor can validate
// that an s7 tag map only references an s7 endpoint.
type DescriptorPLC struct {
	// Endpoints are the reachable PLCs. host_ref / endpoint_url_ref may be a
	// secret:// reference OR a literal host (network config, not a secret).
	Endpoints []DescriptorPLCEndpoint `yaml:"endpoints"`

	// S7TagMap / ModbusTagMap / OPCUATagMap are the per-protocol tag→PackML
	// bindings, reused directly from clientconfig so the emitted client.yaml is a
	// straight copy. Each entry's Endpoint references a DescriptorPLCEndpoint.Name.
	S7TagMap     []clientconfig.S7EndpointTags     `yaml:"s7_tag_map,omitempty"`
	ModbusTagMap []clientconfig.ModbusEndpointTags `yaml:"modbus_tag_map,omitempty"`
	OPCUATagMap  []clientconfig.OPCUAEndpointTags  `yaml:"opcua_tag_map,omitempty"`
}

// DescriptorPLCEndpoint is one reachable PLC. It mirrors clientconfig.PLCEndpoint
// field-for-field and adds Protocol. Rack/Slot are S7-specific, UnitID is
// Modbus-specific, EndpointURLRef/SecurityPolicy/SecurityMode are OPC-UA-specific
// — all pointers/omitempty so "absent" is distinguishable from a zero value.
type DescriptorPLCEndpoint struct {
	Name string `yaml:"name"`
	// Protocol ∈ {s7, modbus_tcp, opcua}. Selects the reader + gates which tag
	// map may reference this endpoint.
	Protocol string `yaml:"protocol"`
	// HostRef (S7/Modbus) is the PLC host: a secret:// reference OR a literal
	// host[:port] (network config, not a secret — see requireHostRef).
	HostRef string `yaml:"host_ref,omitempty"`
	Rack    *int   `yaml:"rack,omitempty"` // S7
	Slot    *int   `yaml:"slot,omitempty"` // S7
	UnitID  *int   `yaml:"unit_id,omitempty"`
	// EndpointURLRef (OPC-UA) is the server URL — a secret:// reference OR a
	// literal opc.tcp:// URL. The OPC-UA analogue of host_ref.
	EndpointURLRef  string `yaml:"endpoint_url_ref,omitempty"`
	SecurityPolicy  string `yaml:"security_policy,omitempty"`
	SecurityMode    string `yaml:"security_mode,omitempty"`
	PollingInterval string `yaml:"polling_interval,omitempty"`
}

// Canonical holds the canonical topic-model head.
type Canonical struct {
	// Prefix is the canonical tenant_prefix, e.g. "CPACK/SC". Every equipment
	// topic starts with it; a topic minus the prefix is its local segment.
	Prefix string `yaml:"prefix"`
}

// Mapping mirrors the normalize-side + count-index-mode inputs of a tenant
// conversion profile. Types are reused from tenantprofile so a descriptor
// expresses exactly what the profile can hold (one schema, no translation loss).
type Mapping struct {
	// CountIndexDefaultMode is the profile's count_index.mode fallback for any
	// member without a captured override ("equipment_id" | "explicit" | "").
	CountIndexDefaultMode string `yaml:"count_index_default_mode"`

	PrefixFixups           []tenantprofile.Rewrite              `yaml:"prefix_fixups"`
	MetricAliases          []tenantprofile.Rewrite              `yaml:"metric_aliases"`
	ParameterAliases       []tenantprofile.ParameterAlias       `yaml:"parameter_aliases"`
	ParameterDecomposition tenantprofile.ParameterDecomposition `yaml:"parameter_decomposition"`
}

// Equipment is one line or member as CS Admin declares it.
type Equipment struct {
	// Topic is the canonical (post-fixup) packml_topic, e.g.
	// "CPACK/SC/LINHAS/L5/BREYER". Must start with Canonical.Prefix.
	Topic string `yaml:"topic"`

	// DeviceKey is the equipment's STABLE identity — the ADR-0046 §2 device key
	// that rides on every birth counter metric (properties["device_key"]) and
	// keys packml_register.device_key. It is DECLARED, not string-derived: when
	// set it is AUTHORITATIVE; when empty the birth side falls back to the
	// dash-joined-topic derivation (the transitional bridge, see birth pkg), so
	// nothing breaks for a descriptor that predates this field. Charset
	// [A-Za-z0-9._-]+ (no "/" — it is the flat identity, not a topic path);
	// unique per tenant. Use ResolvedDeviceKey() to read the declared-else-derived
	// value — that is the single place the fallback rule lives.
	DeviceKey string `yaml:"device_key,omitempty"`

	// IDEquipment is the register surrogate id (drives packml_register SQL + id
	// resolution). It is NOT the count index — those diverge (#601).
	IDEquipment int `yaml:"id_equipment"`

	// TPEquipment: 1=machine (member), 2=sector, 3=line.
	TPEquipment int `yaml:"tp_equipment"`

	// IDUnit is id_unit for the register row (id_equipment for machines; NULL for
	// lines). A nil pointer emits NULL.
	IDUnit *int `yaml:"id_unit,omitempty"`

	// CountIndex is the CAPTURED PLC channel index for a member's count metric,
	// with its confidence. Lines omit it (their template carries bare counts).
	CountIndex *CountIndexCapture `yaml:"count_index,omitempty"`

	// LineRoles bind a LINE's (tp!=1) OEE count roles to specific PLC count
	// indices. A member owns one count leaf (CountIndex); a line owns SEVERAL at
	// DISTINCT indices — gross total vs net good vs scrap — which the single-index
	// member path cannot express (the line metric_templates carry only bare,
	// non-count-routable leaves). Each role emits `/Admin/Prod<Role>Count/<idx>/Unit`
	// under the line topic, so a numeric-counter tee's gross and net channels land
	// on the SAME line id_equipment and the rollup's oee_q = net/gross computes.
	// Only valid on tp=2|3 (Validate rejects it on a member). Empty for a member
	// or a line whose counts come via Phase-9 member aggregation.
	LineRoles []LineRole `yaml:"line_roles,omitempty"`

	// Derived declares agent-side SYNTHESIS rules for equipment whose PLC does not
	// emit a canonical count directly (ADR-0045 P2c). Two generic shapes:
	//   - integral: an analog rate (e.g. FLEXO's speed) integrated over time into
	//     a monotonic production counter — the PLC has NO count register at all.
	//   - sum: several count registers (e.g. PTH's A+B) latched and summed into one
	//     canonical count.
	// Each rule's Emit leaves become the equipment's canonical count suffixes,
	// synthesized into the raw_tag_map allowlist (SynthesizeEquipment) so §C holds;
	// the runtime deriver computes their VALUES. Leaves are RELATIVE (a leading
	// "/…"), with the usual {idx} placeholder resolved from this equipment's count
	// index. Empty for equipment whose PLC emits canonical counts directly.
	Derived []DerivedMetric `yaml:"derived,omitempty"`
}

// DerivedMetric is one agent-side synthesis rule as CS Admin declares it in the
// descriptor. Exactly one of {Integral, Sum} is set. Its leaves are RELATIVE
// (equipment-local, optional {idx}); GenerateProfile resolves them to the FULL
// segment-qualified suffixes the runtime deriver + allowlist use. The Integral /
// Sum source types are reused verbatim from tenantprofile so the descriptor
// expresses exactly what the profile (and thus the deriver) can hold.
type DerivedMetric struct {
	// Emit are the canonical count leaves this rule publishes, e.g.
	// ["/Admin/ProdConsumedCount/{idx}/Unit", "/Admin/ProdProcessedCount/{idx}/Unit"].
	// A FLEXO with no NET/GROSS distinction lists BOTH (gross=net, oee_quality=1):
	// the legacy ***TRIG_C=O trick is NOT propagated cloud-side, so emit both leaves
	// rather than trying to reattach a TRIG variant.
	Emit []string `yaml:"emit"`

	// Type is the SparkPlug type of the emitted count — the tenant's count type
	// (CPACK = "double"). The deriver floors before emit so the cloud's float→int64
	// truncation stays monotonic.
	Type string `yaml:"type"`

	// Integral integrates an analog source rate into a monotonic count. Source is
	// the RAW arriving suffix (the tee's real name, e.g. "/Status/CurMachSpeed").
	Integral *tenantprofile.IntegralSource `yaml:"integral,omitempty"`

	// Sum latches + sums several arriving count registers (Addends, ≥2) into one.
	Sum *tenantprofile.SumSource `yaml:"sum,omitempty"`
}

// ResolvedDeviceKey returns the equipment's DECLARED device_key, or — when none is
// declared — the dash-joined-topic derivation (the transitional bridge form the
// birth side and the golden fixtures use, e.g. "CPACK/SC/LINHAS/L5/BREYER" →
// "CPACK-SC-LINHAS-L5-BREYER"). This is the single source of the declared-else-
// derived rule; the register SQL, the agent tag-map, and (via them) the runtime
// birth all read identity through here so producer and consumer cannot disagree.
func (e Equipment) ResolvedDeviceKey() string {
	if k := strings.TrimSpace(e.DeviceKey); k != "" {
		return k
	}
	return strings.ReplaceAll(e.Topic, "/", "-")
}

// LineRole binds one canonical count-leaf ROLE on a line to a specific PLC count
// index. It is the line-level analogue of a member's CountIndexCapture, but keyed
// by role because a line owns multiple count leaves at once.
//
// ⚠ The platform's leaf naming is counter-intuitive (oeecloud-worker
// parse.go / equipment_values.go): ProdConsumedCount → gross_production (TOTAL
// in), ProdProcessedCount → net_production (GOOD out), ProdDefectiveCount →
// scrap. The rollup computes oee_q = net/gross = ProdProcessedCount /
// ProdConsumedCount. So for a standard line: gross infeed → role "consumed",
// net good → role "processed".
type LineRole struct {
	// Role is one of the LineRole* roles below (consumed=gross | processed=net |
	// defective=scrap). It selects the canonical count leaf.
	Role string `yaml:"role"`

	// CountIndex is the legacy PLC channel id whose absolute totalizer feeds this
	// role — the same numeric id the tee forwards (count_index.value semantics).
	CountIndex int `yaml:"count_index"`

	// Confidence is confirmed (observed on a live tee) or inferred. Cutover
	// requires confirmed, exactly like a member's CountIndexCapture.
	Confidence string `yaml:"confidence"`
}

// CountIndexCapture is one observed count index + provenance.
type CountIndexCapture struct {
	// Value is the integer the PLC embeds in …/ProdProcessedCount/<Value>/Unit.
	Value int `yaml:"value"`

	// Confidence is confirmed (observed on a live tee) or inferred (a guess from
	// the prevailing pattern). Cutover requires confirmed.
	Confidence string `yaml:"confidence"`

	// Active optionally records whether the member's count topic is live. Unset
	// ⇒ assumed active (conservative). Feeds the DQ report's active/dormant split
	// (ADR-0045 open-Q3); the cutover gate is strict on ANY inferred regardless.
	Active *bool `yaml:"active,omitempty"`
}

// AgentWiring is the sparkplug-agent session + transport config (→ client.yaml).
type AgentWiring struct {
	EdgeNodeID     string   `yaml:"edge_node_id"`
	InternalBroker string   `yaml:"internal_broker"`
	RawTopic       string   `yaml:"raw_topic"`
	UplinkBroker   string   `yaml:"uplink_broker"`
	MTLS           MTLSRefs `yaml:"mtls"`
}

// MTLSRefs are uplink mTLS material — secret references only, never values
// (ADR-0042 §6, ADR-0004 Layer-2). Empty on the staging loopback.
type MTLSRefs struct {
	CertRef string `yaml:"cert_ref"`
	KeyRef  string `yaml:"key_ref"`
	CARef   string `yaml:"ca_ref"`
}

// TeeParams parameterize the generated Node-RED tee snippet.
type TeeParams struct {
	// IngestURL is the ingest-shim front-door the tee POSTs to.
	IngestURL string `yaml:"ingest_url"`
	// IngestKeyEnv is the Node-RED env var the tee reads the ingest key from
	// (never hardcoded). Empty ⇒ "<TENANT>_INGEST_KEY".
	IngestKeyEnv string `yaml:"ingest_key_env"`
	// Gateway is a stable gateway identifier stamped in the envelope. Empty ⇒
	// "<tenant-lower>-edge".
	Gateway string `yaml:"gateway"`
	// TLSInsecure skips server-cert verification (staging self-signed).
	TLSInsecure bool `yaml:"tls_insecure"`
}

// Parse unmarshals + validates a client descriptor from raw bytes. It is the
// byte-oriented core Load wraps, so a descriptor that arrives over the wire (the
// ADR-0045 P1 onboard API) is parsed and validated through the EXACT same path a
// file on disk is — one descriptor schema, one validation, no drift between the
// CLI and the HTTP surface.
//
// The body is decoded as YAML. JSON callers are handled transparently: JSON is a
// strict subset of YAML, and yaml.v3 honours the same struct tags, so a JSON
// request body unmarshals into the descriptor with no separate code path.
func Parse(raw []byte) (*Descriptor, error) {
	var d Descriptor
	if err := yaml.Unmarshal(raw, &d); err != nil {
		return nil, fmt.Errorf("clientdescriptor: parse: %w", err)
	}
	if err := d.Validate(); err != nil {
		return nil, fmt.Errorf("clientdescriptor: validate: %w", err)
	}
	return &d, nil
}

// Load reads + validates a client descriptor from disk. It delegates the
// unmarshal + validation to Parse so the file and wire paths share one core.
func Load(path string) (*Descriptor, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("clientdescriptor: read %s: %w", path, err)
	}
	d, err := Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("clientdescriptor: %s: %w", path, err)
	}
	return d, nil
}

// Validate checks the descriptor is internally consistent BEFORE generation — a
// bad descriptor should fail loudly here, not fan a silent error out to all four
// artifacts (ADR-0045 §5 negative: "a generator bug fans out to all four").
func (d *Descriptor) Validate() error {
	if strings.TrimSpace(d.Tenant) == "" {
		return fmt.Errorf("tenant is required")
	}
	if strings.TrimSpace(d.Canonical.Prefix) == "" {
		return fmt.Errorf("canonical.prefix (tenant_prefix) is required")
	}
	switch d.Mapping.CountIndexDefaultMode {
	case "", "equipment_id", "explicit":
	default:
		return fmt.Errorf("mapping.count_index_default_mode=%q must be equipment_id|explicit",
			d.Mapping.CountIndexDefaultMode)
	}
	if len(d.Equipment) == 0 {
		return fmt.Errorf("equipment is required (nothing to onboard)")
	}
	seenTopic := map[string]bool{}
	seenID := map[int]bool{}
	// seenDeviceKey tracks every RESOLVED device key (declared or topic-derived) so
	// a collision is caught here rather than at the packml_register partial-unique
	// index (id_enterprise, device_key). Maps key → the topic that first claimed it.
	seenDeviceKey := map[string]string{}
	// seenCountIndex tracks every count index claimed by a member (CountIndex) or a
	// line role (LineRoles), so a collision is caught at descriptor-validate time
	// rather than surfacing as numeric.BuildIndexFromTagMap's runtime error (a
	// numeric id must resolve to exactly one canonical metric). Maps index → the
	// topic that first claimed it, for a precise error.
	seenCountIndex := map[int]string{}
	for i, e := range d.Equipment {
		if strings.TrimSpace(e.Topic) == "" {
			return fmt.Errorf("equipment[%d]: topic is required", i)
		}
		if !strings.HasPrefix(e.Topic, d.Canonical.Prefix) {
			return fmt.Errorf("equipment[%d] (%s): topic must start with canonical.prefix %q",
				i, e.Topic, d.Canonical.Prefix)
		}
		if seenTopic[e.Topic] {
			return fmt.Errorf("equipment[%d]: duplicate topic %q", i, e.Topic)
		}
		seenTopic[e.Topic] = true
		if e.IDEquipment <= 0 {
			return fmt.Errorf("equipment[%d] (%s): id_equipment must be > 0", i, e.Topic)
		}
		if seenID[e.IDEquipment] {
			return fmt.Errorf("equipment[%d] (%s): duplicate id_equipment %d", i, e.Topic, e.IDEquipment)
		}
		seenID[e.IDEquipment] = true
		// device_key: when DECLARED it must be a non-empty, /-free identity string
		// (the flat key, not a topic path). Uniqueness is enforced on the RESOLVED
		// key (declared-else-derived) so a declared key that collides with another
		// equipment's derived key is caught too — both land in the same
		// packml_register.device_key column under one partial-unique index.
		if e.DeviceKey != "" && !deviceKeyPattern.MatchString(e.DeviceKey) {
			return fmt.Errorf("equipment[%d] (%s): device_key=%q must match [A-Za-z0-9._-]+ (no '/'; it is the flat identity, not a topic)",
				i, e.Topic, e.DeviceKey)
		}
		dk := e.ResolvedDeviceKey()
		if prev, dup := seenDeviceKey[dk]; dup {
			return fmt.Errorf("equipment[%d] (%s): device_key %q already claimed by %s "+
				"(unique per tenant — it keys packml_register.device_key)", i, e.Topic, dk, prev)
		}
		seenDeviceKey[dk] = e.Topic
		switch e.TPEquipment {
		case 1, 2, 3:
		default:
			return fmt.Errorf("equipment[%d] (%s): tp_equipment=%d must be 1|2|3", i, e.Topic, e.TPEquipment)
		}
		if e.CountIndex != nil {
			switch e.CountIndex.Confidence {
			case ConfidenceConfirmed, ConfidenceInferred:
			default:
				return fmt.Errorf("equipment[%d] (%s): count_index.confidence=%q must be confirmed|inferred",
					i, e.Topic, e.CountIndex.Confidence)
			}
			if prev, dup := seenCountIndex[e.CountIndex.Value]; dup {
				return fmt.Errorf("equipment[%d] (%s): count_index %d already claimed by %s "+
					"(a numeric id must map to exactly one canonical metric)", i, e.Topic, e.CountIndex.Value, prev)
			}
			seenCountIndex[e.CountIndex.Value] = e.Topic
		}
		// line_roles: a line's (tp!=1) multi-leaf count binding. A member (tp=1)
		// carries CountIndex, not line_roles — reject the mix so a role can't
		// silently land on a member's single-leaf synthesis path.
		if len(e.LineRoles) > 0 {
			if e.TPEquipment == 1 {
				return fmt.Errorf("equipment[%d] (%s): line_roles is only valid on a line/sector (tp_equipment=2|3), not a member (tp=1)",
					i, e.Topic)
			}
			seenRole := map[string]bool{}
			for j, r := range e.LineRoles {
				if _, ok := lineRoleLeaf[r.Role]; !ok {
					return fmt.Errorf("equipment[%d] (%s): line_roles[%d].role=%q must be consumed|processed|defective",
						i, e.Topic, j, r.Role)
				}
				if seenRole[r.Role] {
					return fmt.Errorf("equipment[%d] (%s): line_roles has duplicate role %q", i, e.Topic, r.Role)
				}
				seenRole[r.Role] = true
				switch r.Confidence {
				case ConfidenceConfirmed, ConfidenceInferred:
				default:
					return fmt.Errorf("equipment[%d] (%s): line_roles[%d].confidence=%q must be confirmed|inferred",
						i, e.Topic, j, r.Confidence)
				}
				if prev, dup := seenCountIndex[r.CountIndex]; dup {
					return fmt.Errorf("equipment[%d] (%s): line_roles[%d] count_index %d already claimed by %s "+
						"(a numeric id must map to exactly one canonical metric)", i, e.Topic, j, r.CountIndex, prev)
				}
				seenCountIndex[r.CountIndex] = e.Topic
			}
		}
		// derived: agent-side synthesis rules. Validate the shape here (one-of,
		// non-empty emit, sum≥2 addends, integral.source) so a bad rule fails at
		// descriptor time, not fanned out. The RESOLVED form is re-validated by the
		// generated profile (GenerateProfile → Profile.Validate).
		for j, dm := range e.Derived {
			if err := validateDerivedMetric(i, e.Topic, j, dm); err != nil {
				return err
			}
		}
	}
	// The generated profile must itself validate — build + validate it here so a
	// bad mapping/template is caught at descriptor-validate time.
	if _, err := d.GenerateProfile(); err != nil {
		return fmt.Errorf("generated profile invalid: %w", err)
	}
	// The optional plc block: descriptor-native structural checks (endpoint
	// protocol tokens, endpoint-reference-and-protocol integrity, secret refs).
	if err := d.validatePLC(); err != nil {
		return err
	}
	// And — like GenerateProfile above — build the client.yaml so a bad tag map
	// (invalid type token, prefix violation, OR a metric with no matching agent
	// raw_tag_map entry) is caught at descriptor-validate time, not fanned out to
	// a silently-broken artifact. GenerateClientYAML runs the full clientconfig
	// validator + the client⇄agent consistency invariant (ADR-0045 §C).
	if d.PLC != nil {
		if _, err := d.GenerateClientYAML(); err != nil {
			return err
		}
	}
	return nil
}

// validTypes is the SparkPlug type set a derived Emit may declare (mirrors
// tenantprofile.validTypes so a descriptor can never declare a type the profile
// would later reject).
var validTypes = map[string]bool{
	"double": true, "float": true, "long": true,
	"int": true, "bool": true, "string": true,
}

// validateDerivedMetric enforces the DerivedMetric shape at descriptor time:
// exactly one of {integral, sum}; emit non-empty with a valid type; sum needs
// ≥2 addends; integral needs a source. i/topic/j give a precise error location.
func validateDerivedMetric(i int, topic string, j int, dm DerivedMetric) error {
	hasIntegral := dm.Integral != nil
	hasSum := dm.Sum != nil
	if hasIntegral == hasSum {
		return fmt.Errorf("equipment[%d] (%s): derived[%d] must set exactly one of {integral, sum}", i, topic, j)
	}
	if len(dm.Emit) == 0 {
		return fmt.Errorf("equipment[%d] (%s): derived[%d].emit must list at least one canonical count leaf", i, topic, j)
	}
	for k, e := range dm.Emit {
		if strings.TrimSpace(e) == "" {
			return fmt.Errorf("equipment[%d] (%s): derived[%d].emit[%d] is empty", i, topic, j, k)
		}
	}
	if !validTypes[dm.Type] {
		return fmt.Errorf("equipment[%d] (%s): derived[%d].type=%q must be double|float|long|int|bool|string", i, topic, j, dm.Type)
	}
	if hasIntegral && strings.TrimSpace(dm.Integral.Source) == "" {
		return fmt.Errorf("equipment[%d] (%s): derived[%d].integral.source is required", i, topic, j)
	}
	if hasSum && len(dm.Sum.Addends) < 2 {
		return fmt.Errorf("equipment[%d] (%s): derived[%d].sum.addends must list at least two suffixes (a one-addend sum is a rename)", i, topic, j)
	}
	return nil
}

// validatePLC checks the plc block's descriptor-native invariants — the ones
// clientconfig cannot make because its PLCEndpoint carries no protocol: endpoint
// names are unique + non-empty, every protocol is a known token, host/URL fields
// are secret references (never inline values), and every tag map references a
// defined endpoint WHOSE protocol matches the map kind (an s7_tag_map may only
// bind an s7 endpoint). The per-tag TYPE + tenant-prefix + non-empty-tags rules
// are delegated to clientconfig via GenerateClientYAML, so there is no duplicate
// (drift-prone) copy of them here.
func (d *Descriptor) validatePLC() error {
	if d.PLC == nil {
		return nil
	}
	epProto := map[string]string{} // endpoint name → its protocol
	for i, ep := range d.PLC.Endpoints {
		if strings.TrimSpace(ep.Name) == "" {
			return fmt.Errorf("plc.endpoints[%d]: name is required", i)
		}
		if _, dup := epProto[ep.Name]; dup {
			return fmt.Errorf("plc.endpoints[%d]: duplicate name %q", i, ep.Name)
		}
		switch ep.Protocol {
		case PLCProtocolS7, PLCProtocolModbusTCP, PLCProtocolOPCUA:
		default:
			return fmt.Errorf("plc.endpoints[%d] (%s): protocol=%q must be %s|%s|%s",
				i, ep.Name, ep.Protocol, PLCProtocolS7, PLCProtocolModbusTCP, PLCProtocolOPCUA)
		}
		epProto[ep.Name] = ep.Protocol
		if err := requireHostRef("plc.endpoints", i, ep.Name, "host_ref", ep.HostRef); err != nil {
			return err
		}
		if err := requireEndpointURLRef("plc.endpoints", i, ep.Name, "endpoint_url_ref", ep.EndpointURLRef); err != nil {
			return err
		}
	}
	// Each tag map's endpoint must exist AND carry the map's protocol.
	checkRef := func(section, endpoint string, i int, wantProto string) error {
		proto, ok := epProto[endpoint]
		if !ok {
			return fmt.Errorf("plc.%s[%d].endpoint=%q must reference a plc.endpoints[].name", section, i, endpoint)
		}
		if proto != wantProto {
			return fmt.Errorf("plc.%s[%d].endpoint=%q is protocol %q, but this tag map requires %q",
				section, i, endpoint, proto, wantProto)
		}
		return nil
	}
	for i, m := range d.PLC.S7TagMap {
		if err := checkRef("s7_tag_map", m.Endpoint, i, PLCProtocolS7); err != nil {
			return err
		}
	}
	for i, m := range d.PLC.ModbusTagMap {
		if err := checkRef("modbus_tag_map", m.Endpoint, i, PLCProtocolModbusTCP); err != nil {
			return err
		}
	}
	for i, m := range d.PLC.OPCUATagMap {
		if err := checkRef("opcua_tag_map", m.Endpoint, i, PLCProtocolOPCUA); err != nil {
			return err
		}
	}
	return nil
}

// requireHostRef enforces host_ref is empty, a secret:// reference, OR a literal
// host[:port]. A PLC host is NETWORK config (an IP on the factory LAN), not a
// secret, so a literal is allowed — this is what lets the bundle generator
// prefill PLC_HOST_* from the descriptor (F9). The literal-host rule itself lives
// in clientconfig (IsLiteralHost) and is REUSED here so the descriptor surface
// and the client.yaml GenerateClientYAML emits accept byte-identical shapes —
// otherwise a literal that passes here would be rejected at reader boot.
func requireHostRef(section string, idx int, label, field, val string) error {
	if val == "" || strings.HasPrefix(val, secretScheme) || clientconfig.IsLiteralHost(val) {
		return nil
	}
	return fmt.Errorf("%s[%d] (%s): %s=%q must be empty, a %s reference, or a literal host[:port]",
		section, idx, label, field, val, secretScheme)
}

// requireEndpointURLRef is the OPC-UA analogue: empty, a secret:// reference, OR
// a literal opc.tcp:// endpoint URL. Reuses clientconfig.IsOPCUAEndpointURL for
// the same cross-surface consistency reason as requireHostRef.
func requireEndpointURLRef(section string, idx int, label, field, val string) error {
	if val == "" || strings.HasPrefix(val, secretScheme) || clientconfig.IsOPCUAEndpointURL(val) {
		return nil
	}
	return fmt.Errorf("%s[%d] (%s): %s=%q must be empty, a %s reference, or an opc.tcp:// URL",
		section, idx, label, field, val, secretScheme)
}
