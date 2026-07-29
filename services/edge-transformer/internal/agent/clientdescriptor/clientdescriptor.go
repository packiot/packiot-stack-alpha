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
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tenantprofile"
)

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
	}
	// The generated profile must itself validate — build + validate it here so a
	// bad mapping/template is caught at descriptor-validate time.
	if _, err := d.GenerateProfile(); err != nil {
		return fmt.Errorf("generated profile invalid: %w", err)
	}
	return nil
}
