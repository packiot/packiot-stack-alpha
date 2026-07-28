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

// Load reads + validates a client descriptor from disk.
func Load(path string) (*Descriptor, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("clientdescriptor: read %s: %w", path, err)
	}
	var d Descriptor
	if err := yaml.Unmarshal(raw, &d); err != nil {
		return nil, fmt.Errorf("clientdescriptor: parse %s: %w", path, err)
	}
	if err := d.Validate(); err != nil {
		return nil, fmt.Errorf("clientdescriptor: validate %s: %w", path, err)
	}
	return &d, nil
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
		}
	}
	// The generated profile must itself validate — build + validate it here so a
	// bad mapping/template is caught at descriptor-validate time.
	if _, err := d.GenerateProfile(); err != nil {
		return fmt.Errorf("generated profile invalid: %w", err)
	}
	return nil
}
