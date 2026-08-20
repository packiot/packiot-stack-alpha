// Package clientconfig parses the per-customer client.yaml file (ADR-0009
// Phase 1, ADR-0004 config centralization). One YAML file per customer
// becomes the single source of truth for:
//
//   - the tenant identifier (used to drive per-tenant queue names +
//     per-tenant Prometheus labels — the silent-metric-coverage-gap fix
//     pattern; see services/oeecloud-worker/internal/amqp/topology.go)
//   - equipment mappings (Sparkplug topic → equipment id)
//   - shift schedules + integration targets
//   - references to AWS Secrets Manager secret IDs for the runtime creds
//
// NOT in this file (deliberate, per ADR-0009 Errata Correction 3):
//
//   - the actual secret values (DB passwords, API keys, cert bytes) —
//     those live in AWS Secrets Manager and are referenced by ID here.
//     The naming convention is `*_env: VAR_NAME` → matching key in the
//     SM secret JSON; CI lint enforces both sides.
//
// TODO(ADR-0009 Phase 2): expand the schema to cover the full ADR-0004
// surface (currently shipping the minimum needed for tenant discovery +
// shadow-mode boot). Spec must absorb `docs/clients/cpack.example.yaml`
// once that file lands.
//
// TODO(ADR-0009 Phase 2): add a `clientconfig.Watch(ctx, path)` that
// fsnotify-watches the YAML file and emits new snapshots on the returned
// channel. Today the loader is one-shot at boot — a config change
// requires a service restart, matching oeecloud-worker's behavior.
package clientconfig

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config is the parsed shape of client.yaml. The skeleton fields
// (tenant_id, customer, environment, equipments) are honored at runtime
// today; the v1.1 sections below (schema_version, plc, equipment_mapping,
// shifts, capabilities) are the descriptor schema from
// docs/adr/reference/designs/0021-tenant-descriptor-and-isolation-gate.md
// §1a. They parse into OPTIONAL typed fields and are validated when
// present, but NOTHING consumes them yet — the capabilities drive the
// C1/C2/C3 components that don't exist. This is the forward-compatible
// parse+validate foundation: skeleton configs (cpack.yaml, incoplast.yaml)
// keep loading unchanged, and a v1.1 descriptor round-trips + lints.
type Config struct {
	// SchemaVersion is the descriptor schema version ("1.1"). Absent in
	// skeleton configs; informational for now (no behavior branches on it).
	SchemaVersion string `yaml:"schema_version,omitempty"`

	// TenantID is the lowercased Sparkplug group_id. Matches what
	// services/oeecloud-worker/internal/tenants/discovery.go computes from
	// packml_register, so per-tenant queue names line up across both
	// services (no mismatched routing keys = no silent drops).
	TenantID string `yaml:"tenant_id"`

	// Customer is the human-readable name. Logged at boot for operator
	// sanity-checks ("yes, this binary booted with the right config").
	Customer string `yaml:"customer"`

	// Environment is one of "staging" | "production". Used today only for
	// log context; in Phase 2 it gates which SM secret-ID prefix is used.
	Environment string `yaml:"environment"`

	// CanonicalPrefix is the tenant/site SparkPlug prefix (e.g. "CPACK/SC") the
	// agent carries as its packml_topic. In raw-emit mode the reader strips it
	// from each compiled tag's full metric name so it emits the GROUP-RELATIVE
	// metric_suffix (e.g. "/CELULA1/CER400/Status/MachSpeed") — the exact string
	// the agent resolves by (newResolver keys byName on metric_suffix; it does
	// NOT strip its own prefix). Optional; empty ⇒ no strip (emit the full name,
	// e.g. the demo-tag path). Set by onboard-gen from descriptor.canonical.prefix.
	CanonicalPrefix string `yaml:"canonical_prefix,omitempty"`

	// Equipments is the static topic→equipment mapping. Empty in the
	// skeleton; Phase 2 fills it from packml_register exports or
	// CS-Admin onboarding output.
	Equipments []EquipmentMapping `yaml:"equipments,omitempty"`

	// PLC (v1.1) describes how this factory's PLC is reached. Optional;
	// nil for skeleton configs. Hosts may be a secret:// REFERENCE or a
	// LITERAL host[:port] — a PLC host is network config (an IP on the
	// factory LAN), not a secret, so a literal is allowed and lets the
	// bundle generator prefill PLC_HOST_*. CREDENTIAL fields (dsn_ref)
	// stay secret-only (the Incoplast cleartext-credentials lesson).
	PLC *PLC `yaml:"plc,omitempty"`

	// EquipmentMapping (v1.1) is the richer topic↔equipment table that
	// also carries per-tenant ERP dimensions. Distinct from Equipments
	// (the skeleton field) which stays as-is for back-compat.
	EquipmentMapping []EquipmentMapEntry `yaml:"equipment_mapping,omitempty"`

	// Shifts (v1.1) selects where shift definitions come from. Optional.
	Shifts *Shifts `yaml:"shifts,omitempty"`

	// Capabilities (v1.1) declares what this tenant's stack must stand up
	// (operator mode, command channel, integrations, custom flows).
	// Optional; nil for skeleton configs.
	Capabilities *Capabilities `yaml:"capabilities,omitempty"`

	// S7TagMap (v1.1, ADR-0019 G4) maps S7 PLC addresses to PackML metric
	// names — the tag→PackML mapping the s7-reader compiles into its poll loop
	// (design: 0019-G4-s7-read-adapter.md). Optional; present only for S7
	// tenants (e.g. Incoplast). Each entry references a plc.endpoints[].name.
	S7TagMap []S7EndpointTags `yaml:"s7_tag_map,omitempty"`

	// ModbusTagMap (v1.1) maps Modbus TCP registers/coils to PackML metric
	// names — the tag→PackML mapping the modbus-reader compiles into its poll
	// loop. The Modbus sibling of S7TagMap. Optional; present only for tenants
	// with Modbus lines (e.g. CPACK). Each entry references a plc.endpoints[].name.
	ModbusTagMap []ModbusEndpointTags `yaml:"modbus_tag_map,omitempty"`

	// OPCUATagMap (v1.1) maps OPC-UA NodeIDs to PackML metric names — the
	// tag→PackML mapping the opcua-reader compiles into its poll loop. The
	// OPC-UA sibling of S7TagMap. Optional; present only for tenants with
	// OPC-UA lines (e.g. CPACK). Each entry references a plc.endpoints[].name.
	OPCUATagMap []OPCUAEndpointTags `yaml:"opcua_tag_map,omitempty"`
}

// S7EndpointTags binds one PLC endpoint's tag set to a PackML equipment.
type S7EndpointTags struct {
	Endpoint    string  `yaml:"endpoint"`     // references plc.endpoints[].name
	PackMLTopic string  `yaml:"packml_topic"` // tenant-prefixed base; each Tag.Metric is appended
	IDEquipment int     `yaml:"id_equipment"`
	Tags        []S7Tag `yaml:"tags"`
}

// S7Tag is one S7 address → PackML metric-suffix binding. The full SparkPlug
// metric name is PackMLTopic+Metric.
type S7Tag struct {
	Metric string  `yaml:"metric"`          // suffix appended to PackMLTopic, e.g. "/Status/MachSpeed"
	DB     int     `yaml:"db"`              // S7 data block number
	Offset int     `yaml:"offset"`          // byte offset within the DB
	Bit    int     `yaml:"bit,omitempty"`   // bit index (0-7) when type=bool
	Type   string  `yaml:"type"`            // int | dint | real | bool
	Scale  float64 `yaml:"scale,omitempty"` // 0 = 1 (no scaling)
	Long   bool    `yaml:"long,omitempty"`  // emit as SparkPlug Long (state metrics) vs Double
	// Source (ADR-0045 P2c) marks this tag as DERIVED, not polled: its value is
	// synthesized by the agent-side derive stage (integral/sum) from OTHER tags,
	// so it has NO physical S7 address. When set, the db/offset/type checks are
	// skipped (there is nothing to read). Mirrors the agent DerivedRule shape.
	Source *TagSource `yaml:"source,omitempty"`
	// CounterDerive declares, for a COUNT tag, which of gross/net/scrap this
	// equipment physically senses and how the agent derives the rest (ADR-0045,
	// decoded from CPACK's Calc_Counters). One of the CounterDerive* tokens; empty
	// ⇒ full (all three sensed, pass-through). Non-count tags leave it empty (or
	// "none"). The runtime lives in internal/agent/counterderive; the reader stays
	// a dumb physical-tag reader (the agent owns derivation).
	CounterDerive string `yaml:"counter_derive,omitempty"`
}

// ModbusEndpointTags binds one PLC endpoint's Modbus tag set to a PackML
// equipment — the Modbus analogue of S7EndpointTags.
type ModbusEndpointTags struct {
	Endpoint    string      `yaml:"endpoint"`     // references plc.endpoints[].name
	PackMLTopic string      `yaml:"packml_topic"` // tenant-prefixed base; each Tag.Metric is appended
	IDEquipment int         `yaml:"id_equipment"`
	Tags        []ModbusTag `yaml:"tags"`
}

// ModbusTag is one Modbus address → PackML metric-suffix binding. The full
// SparkPlug metric name is PackMLTopic+Metric.
type ModbusTag struct {
	Metric   string  `yaml:"metric"`              // suffix appended to PackMLTopic
	Kind     string  `yaml:"kind"`                // holding | input | coil | discrete
	Address  int     `yaml:"address"`             // 0-based register/coil address
	Quantity int     `yaml:"quantity,omitempty"`  // registers to span (0 = derive from type)
	Type     string  `yaml:"type,omitempty"`      // uint16|int16|uint32|int32|float32|bool (register kinds; ignored for coil/discrete)
	Scale    float64 `yaml:"scale,omitempty"`     // 0 = 1 (no scaling)
	Long     bool    `yaml:"long,omitempty"`      // emit as SparkPlug Long vs Double
	WordSwap bool    `yaml:"word_swap,omitempty"` // swap the two registers of a 32-bit value (CDAB vs ABCD)
	// Source (ADR-0045 P2c) marks this tag as DERIVED, not polled (see S7Tag.Source):
	// its value is synthesized by the agent-side derive stage, so it has no Modbus
	// address. When set, the kind/type/address checks are skipped.
	Source *TagSource `yaml:"source,omitempty"`
	// CounterDerive — see S7Tag.CounterDerive. Sensor-presence + derivation mode for
	// a count tag; empty ⇒ full. Owned by the agent-side counterderive stage.
	CounterDerive string `yaml:"counter_derive,omitempty"`
}

// OPCUAEndpointTags binds one PLC endpoint's OPC-UA tag set to a PackML
// equipment — the OPC-UA analogue of S7EndpointTags.
type OPCUAEndpointTags struct {
	Endpoint    string     `yaml:"endpoint"`     // references plc.endpoints[].name
	PackMLTopic string     `yaml:"packml_topic"` // tenant-prefixed base; each Tag.Metric is appended
	IDEquipment int        `yaml:"id_equipment"`
	Tags        []OPCUATag `yaml:"tags"`
}

// OPCUATag is one OPC-UA NodeID → PackML metric-suffix binding. The full
// SparkPlug metric name is PackMLTopic+Metric.
type OPCUATag struct {
	Metric string  `yaml:"metric"`          // suffix appended to PackMLTopic
	NodeID string  `yaml:"node_id"`         // OPC-UA node address, e.g. "ns=2;s=Machine.Speed"
	Type   string  `yaml:"type"`            // int | float | bool | string
	Scale  float64 `yaml:"scale,omitempty"` // 0 = 1 (no scaling)
	Long   bool    `yaml:"long,omitempty"`  // emit as SparkPlug Long vs Double
	// Source (ADR-0045 P2c) marks this tag as DERIVED, not polled (see S7Tag.Source):
	// its value is synthesized by the agent-side derive stage, so it has no OPC-UA
	// node_id. When set, the node_id/type checks are skipped.
	Source *TagSource `yaml:"source,omitempty"`
	// CounterDerive — see S7Tag.CounterDerive. Sensor-presence + derivation mode for
	// a count tag; empty ⇒ full. Owned by the agent-side counterderive stage.
	CounterDerive string `yaml:"counter_derive,omitempty"`
}

// TagSource is the reader-side mirror of the agent DerivedRule shape (ADR-0045
// P2c): a tag whose value is SYNTHESIZED (integral or sum) rather than read from
// a physical address. It carries no addressing — the agent-side deriver owns the
// computation; this is the schema record so a client.yaml can DECLARE a derived
// tag (and the §C consistency check still sees its metric). Exactly one of
// {Integral, Sum} is set.
type TagSource struct {
	Integral *IntegralSource `yaml:"integral,omitempty"`
	Sum      *SumSource      `yaml:"sum,omitempty"`
}

// IntegralSource declares an analog→count time integral (see the agent
// tenantprofile.IntegralSource; duplicated here so clientconfig has no import
// dependency on the agent packages).
type IntegralSource struct {
	Source     string  `yaml:"source"`
	Conversion float64 `yaml:"conversion"`
	ClampMin   float64 `yaml:"clamp_min,omitempty"`
	MaxRate    float64 `yaml:"max_rate,omitempty"`
}

// SumSource declares a multi-register sum (≥2 addends).
type SumSource struct {
	Addends []string `yaml:"addends"`
}

// EquipmentMapping is one row of the topic↔equipment table — the same
// thing packml_register stores in the DB, lifted into git per ADR-0004.
type EquipmentMapping struct {
	PackMLTopic string `yaml:"packml_topic"`
	IDEquipment int    `yaml:"id_equipment"`
	IDUnit      int    `yaml:"id_unit,omitempty"`
}

// PLC (v1.1 §1a) is the PLC-connectivity section.
type PLC struct {
	Protocol  string        `yaml:"protocol,omitempty"`
	Endpoints []PLCEndpoint `yaml:"endpoints,omitempty"`
}

// PLCEndpoint is one reachable PLC. HostRef / EndpointURLRef are a secret://
// reference OR a literal host (network config, not a secret — see
// requireHostRef); Rack/Slot are S7-specific (the schema gap ADR-0019 named)
// and UnitID is Modbus-specific — all pointers so "absent" is distinguishable
// from "0".
type PLCEndpoint struct {
	Name    string `yaml:"name,omitempty"`
	HostRef string `yaml:"host_ref,omitempty"`
	Rack    *int   `yaml:"rack,omitempty"`
	Slot    *int   `yaml:"slot,omitempty"`
	// UnitID (Modbus) is the unit/slave id byte in the MBAP header — usually 1
	// on a native Ethernet device, or the RTU address behind a serial gateway.
	// Pointer so "absent" is distinguishable from "0" (a valid broadcast id).
	UnitID *int `yaml:"unit_id,omitempty"`
	// EndpointURLRef (OPC-UA) is the server URL (opc.tcp://host:port/path) —
	// the OPC-UA analogue of host_ref. It may be a secret:// reference OR a
	// literal opc.tcp:// URL (network config, not a secret); requireEndpointURLRef
	// rejects any other scheme.
	EndpointURLRef string `yaml:"endpoint_url_ref,omitempty"`
	// SecurityPolicy / SecurityMode (OPC-UA) are optional; empty = "None" (the
	// MVP default, see internal/opcua/client.go). Not secrets — plain tokens.
	SecurityPolicy string `yaml:"security_policy,omitempty"`
	SecurityMode   string `yaml:"security_mode,omitempty"`
	// PollingInterval / ReconnectBackoff are Go duration strings ("1s", "30s")
	// parsed by the readers; empty = the reader's default.
	PollingInterval  string `yaml:"polling_interval,omitempty"`
	ReconnectBackoff string `yaml:"reconnect_backoff,omitempty"`
}

// EquipmentMapEntry (v1.1 §1a) maps a Sparkplug topic to an equipment id
// and carries the per-tenant ERP dimensions that had no home before v1.1.
type EquipmentMapEntry struct {
	PackMLTopic string            `yaml:"packml_topic"`
	IDEquipment int               `yaml:"id_equipment"`
	ERP         map[string]string `yaml:"erp,omitempty"`
}

// Shifts (v1.1 §1a) selects the shift source: cloud_db or descriptor.
type Shifts struct {
	Source string `yaml:"source,omitempty"`
}

// Capabilities (v1.1 §1a) declares what the tenant's stack must provide.
type Capabilities struct {
	Operator       *OperatorCapability `yaml:"operator,omitempty"`
	Commands       *CommandsCapability `yaml:"commands,omitempty"`
	Integrations   []Integration       `yaml:"integrations,omitempty"`
	Customizations []string            `yaml:"customizations,omitempty"`
}

// OperatorCapability picks where the operator UI runs. Mode ∈ {cloud, edge}.
type OperatorCapability struct {
	Mode     string `yaml:"mode,omitempty"`
	Language string `yaml:"language,omitempty"`
}

// CommandsCapability is the operator→PLC write-back channel. When Enabled,
// Allowed must be non-empty (you can't enable commands with none allowed).
type CommandsCapability struct {
	Enabled bool     `yaml:"enabled,omitempty"`
	Allowed []string `yaml:"allowed,omitempty"`
}

// Integration is one outbound connector (e.g. the ERP database sync,
// ADR-0019 G1). DSNRef is a secret reference, never a value.
type Integration struct {
	Type     string   `yaml:"type,omitempty"`
	Driver   string   `yaml:"driver,omitempty"`
	DSNRef   string   `yaml:"dsn_ref,omitempty"`
	Reads    []string `yaml:"reads,omitempty"`
	Writes   []string `yaml:"writes,omitempty"`
	DedupKey string   `yaml:"dedup_key,omitempty"`
}

// secretScheme is the required prefix for any host/dsn reference. The
// descriptor NEVER carries secret values inline — only pointers into the
// secret store. Enforced by validate() so a leaked credential fails CI.
const secretScheme = "secret://"

// CounterDerive* are the closed enum of per-count sensor-presence + derivation
// modes a tag may declare (ADR-0045, decoded from CPACK's Calc_Counters). Each
// says which of gross/net/scrap the factory physically senses and how the
// agent-side counterderive stage fills in the rest. Empty ⇒ CounterDeriveFull.
// The EXACT arithmetic lives in internal/agent/counterderive.Apply — this file
// owns only the schema + the closed-enum lint (matching the inline type-token
// validation style already used for s7/modbus/opcua types).
const (
	// CounterDeriveFull — all three counts sensed; no derivation (pass-through).
	CounterDeriveFull = "full"
	// CounterDeriveOutfeedOnly — one outfeed sensor: net := gross; scrap := 0.
	CounterDeriveOutfeedOnly = "outfeed_only"
	// CounterDeriveInfeedOnly — one infeed sensor: gross := net; scrap := 0.
	CounterDeriveInfeedOnly = "infeed_only"
	// CounterDeriveScrapDerived — gross+net sensed, no scrap sensor: scrap := gross-net (floored at 0).
	CounterDeriveScrapDerived = "scrap_derived"
	// CounterDeriveGrossDerived — net+scrap sensed, no gross sensor: gross := net+scrap.
	CounterDeriveGrossDerived = "gross_derived"
	// CounterDeriveOutfeedDerived — line edge-case; best-effort net := max(gross-scrap,0)
	// (an approximation of the legacy stateful formula — see counterderive.Apply).
	CounterDeriveOutfeedDerived = "outfeed_derived"
	// CounterDeriveNone — not a counter; ignore.
	CounterDeriveNone = "none"
)

// validateCounterDerive rejects any counter_derive value outside the closed
// enum above. Empty is allowed (treated as CounterDeriveFull downstream). The
// section/i/j/metric coordinates give a precise error, matching the tag-type
// checks in validateV11.
func validateCounterDerive(section string, i, j int, metric, v string) error {
	switch v {
	case "", CounterDeriveFull, CounterDeriveOutfeedOnly, CounterDeriveInfeedOnly,
		CounterDeriveScrapDerived, CounterDeriveGrossDerived, CounterDeriveOutfeedDerived, CounterDeriveNone:
		return nil
	default:
		return fmt.Errorf("%s[%d].tags[%d] (%s): counter_derive=%q must be full|outfeed_only|infeed_only|scrap_derived|gross_derived|outfeed_derived|none",
			section, i, j, metric, v)
	}
}

// Load parses client.yaml from disk. Returns a useful error for the
// common failure modes (missing file, bad YAML, missing required field).
func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("validate %s: %w", path, err)
	}
	return &cfg, nil
}

// Validate normalizes and validates an in-memory Config — the exact checks Load
// runs on a file, exposed so a PRODUCER of a Config (e.g. the onboard
// generator's GenerateClientYAML) can hold a generated config to the loader
// contract without round-tripping through a temp file. Load delegates to it, so
// there is one source of truth for "is this a valid client.yaml?".
//
// Normalize BEFORE validate: lowercased tenant id to match the per-tenant queue
// naming convention used in internal/amqp/topology.go. CS Admin often writes
// uppercase customer codes (CPACK, SIMCORP) so the normalize step here saves a
// class of "almost-matches" bugs. Doing it first also lets validateV11's
// tenant_id↔topic check compare the canonical (lowercased) form directly. It is
// idempotent, so calling Validate on an already-normalized config is safe.
func (c *Config) Validate() error {
	c.TenantID = strings.ToLower(strings.TrimSpace(c.TenantID))
	return c.validate()
}

func (c *Config) validate() error {
	if strings.TrimSpace(c.TenantID) == "" {
		return fmt.Errorf("tenant_id is required")
	}
	if strings.TrimSpace(c.Customer) == "" {
		return fmt.Errorf("customer is required")
	}
	switch strings.ToLower(c.Environment) {
	case "staging", "production":
	case "":
		return fmt.Errorf("environment is required (staging|production)")
	default:
		return fmt.Errorf("environment=%q: must be staging or production", c.Environment)
	}
	return c.validateV11()
}

// validateV11 runs the CI-lintable descriptor rules from the ADR-0021 §1a
// spec. Every check is GATED on the presence of the section it governs, so
// a skeleton config (no v1.1 sections) passes untouched — the whole point
// of the forward-compatible parse-and-ignore contract.
//
// Rules (design doc §1a "Rules the descriptor enforces"):
//  1. No secret VALUES anywhere: a credential field (dsn_ref) that is present
//     must be a secret://… reference — a DSN carries a username/password and is
//     a secret. A PLC host_ref / endpoint_url_ref is NETWORK config, not a
//     secret (an IP on the factory LAN grants no access), so it may ALSO be a
//     literal host[:port] / opc.tcp:// URL — this is what lets the bundle
//     generator prefill PLC_HOST_* from the descriptor (F9). Any other shape
//     (e.g. an "oracle://user:pass@…" DSN smuggled through host_ref) is rejected.
//  2. tenant_id must equal the lowercased first '/'-segment of EVERY
//     equipment_mapping topic — the discovery contract, checked statically
//     (guards the silent cross-tenant-drop class of bug).
//  3. capabilities.operator.mode ∈ {cloud, edge}; commands.enabled:true
//     requires a non-empty allowed list.
//  4. s7_tag_map / modbus_tag_map / opcua_tag_map: each entry references a real
//     plc endpoint, its packml_topic obeys the tenant-prefix contract (Rule 2),
//     id_equipment > 0, tags non-empty, and every tag has a valid type token
//     (+ kind ∈ {holding,input,coil,discrete} for modbus; non-empty node_id
//     for opcua).
func (c *Config) validateV11() error {
	// Rule 1a — plc endpoint hosts / URLs are a secret:// reference OR a literal
	// (network config, not a secret); any other shape is rejected.
	if c.PLC != nil {
		for i, ep := range c.PLC.Endpoints {
			if err := requireHostRef("plc.endpoints", i, ep.Name, "host_ref", ep.HostRef); err != nil {
				return err
			}
			if err := requireEndpointURLRef("plc.endpoints", i, ep.Name, "endpoint_url_ref", ep.EndpointURLRef); err != nil {
				return err
			}
		}
	}

	// Rule 2 — tenant_id ↔ equipment_mapping topic prefix. c.TenantID is
	// already normalized (Load lowercases before validate).
	for i, em := range c.EquipmentMapping {
		seg := strings.ToLower(firstTopicSegment(em.PackMLTopic))
		if seg != c.TenantID {
			return fmt.Errorf(
				"equipment_mapping[%d].packml_topic=%q: first segment %q must equal tenant_id %q",
				i, em.PackMLTopic, seg, c.TenantID)
		}
	}

	// Rule 3 + Rule 1b — capabilities.
	if c.Capabilities != nil {
		if op := c.Capabilities.Operator; op != nil && op.Mode != "" {
			switch op.Mode {
			case "cloud", "edge":
			default:
				return fmt.Errorf("capabilities.operator.mode=%q: must be cloud or edge", op.Mode)
			}
		}
		if cmd := c.Capabilities.Commands; cmd != nil && cmd.Enabled && len(cmd.Allowed) == 0 {
			return fmt.Errorf("capabilities.commands.enabled is true but allowed is empty")
		}
		// Rule 1b — integration DSNs are references, never values.
		for i, in := range c.Capabilities.Integrations {
			if err := requireSecretRef("capabilities.integrations", i, in.Type, "dsn_ref", in.DSNRef); err != nil {
				return err
			}
		}
	}

	// knownEndpoints is shared by every tag-map rule below.
	knownEndpoints := map[string]bool{}
	if c.PLC != nil {
		for _, ep := range c.PLC.Endpoints {
			knownEndpoints[ep.Name] = true
		}
	}

	// Rule 4 (ADR-0019 G4) — s7_tag_map. Each entry references a real PLC
	// endpoint, its packml_topic obeys the tenant-prefix contract (Rule 2),
	// and every tag has a valid S7 type + non-negative address.
	for i, m := range c.S7TagMap {
		if err := validateMapHeader("s7_tag_map", i, m.Endpoint, m.PackMLTopic, m.IDEquipment, len(m.Tags), knownEndpoints, c.TenantID); err != nil {
			return err
		}
		for j, t := range m.Tags {
			if strings.TrimSpace(t.Metric) == "" {
				return fmt.Errorf("s7_tag_map[%d].tags[%d]: metric is required", i, j)
			}
			if err := validateCounterDerive("s7_tag_map", i, j, t.Metric, t.CounterDerive); err != nil {
				return err
			}
			// A DERIVED tag (Source set) has no physical address — validate the
			// source shape and skip the db/offset/type checks.
			if t.Source != nil {
				if err := validateTagSource("s7_tag_map", i, j, t.Metric, t.Source); err != nil {
					return err
				}
				continue
			}
			switch t.Type {
			case "int", "dint", "real", "bool":
			default:
				return fmt.Errorf("s7_tag_map[%d].tags[%d] (%s): type=%q must be int|dint|real|bool", i, j, t.Metric, t.Type)
			}
			if t.DB < 0 || t.Offset < 0 {
				return fmt.Errorf("s7_tag_map[%d].tags[%d] (%s): db/offset must be non-negative", i, j, t.Metric)
			}
			if t.Type == "bool" && (t.Bit < 0 || t.Bit > 7) {
				return fmt.Errorf("s7_tag_map[%d].tags[%d] (%s): bit must be 0-7 for bool", i, j, t.Metric)
			}
		}
	}

	// Rule 4b — modbus_tag_map. Mirrors the S7 rules; adds the kind token
	// (address space) and non-negative address.
	for i, m := range c.ModbusTagMap {
		if err := validateMapHeader("modbus_tag_map", i, m.Endpoint, m.PackMLTopic, m.IDEquipment, len(m.Tags), knownEndpoints, c.TenantID); err != nil {
			return err
		}
		for j, t := range m.Tags {
			if strings.TrimSpace(t.Metric) == "" {
				return fmt.Errorf("modbus_tag_map[%d].tags[%d]: metric is required", i, j)
			}
			if err := validateCounterDerive("modbus_tag_map", i, j, t.Metric, t.CounterDerive); err != nil {
				return err
			}
			if t.Source != nil {
				if err := validateTagSource("modbus_tag_map", i, j, t.Metric, t.Source); err != nil {
					return err
				}
				continue
			}
			isBit := false
			switch t.Kind {
			case "holding", "input":
			case "coil", "discrete":
				isBit = true
			default:
				return fmt.Errorf("modbus_tag_map[%d].tags[%d] (%s): kind=%q must be holding|input|coil|discrete", i, j, t.Metric, t.Kind)
			}
			// Register kinds carry a numeric type token; bit kinds don't need one.
			if !isBit {
				switch t.Type {
				case "uint16", "int16", "uint32", "int32", "float32", "bool":
				default:
					return fmt.Errorf("modbus_tag_map[%d].tags[%d] (%s): type=%q must be uint16|int16|uint32|int32|float32|bool", i, j, t.Metric, t.Type)
				}
			}
			if t.Address < 0 || t.Quantity < 0 {
				return fmt.Errorf("modbus_tag_map[%d].tags[%d] (%s): address/quantity must be non-negative", i, j, t.Metric)
			}
		}
	}

	// Rule 4c — opcua_tag_map. Mirrors the S7 rules; node_id (not an address)
	// must be non-empty and the type is the coercion token.
	for i, m := range c.OPCUATagMap {
		if err := validateMapHeader("opcua_tag_map", i, m.Endpoint, m.PackMLTopic, m.IDEquipment, len(m.Tags), knownEndpoints, c.TenantID); err != nil {
			return err
		}
		for j, t := range m.Tags {
			if strings.TrimSpace(t.Metric) == "" {
				return fmt.Errorf("opcua_tag_map[%d].tags[%d]: metric is required", i, j)
			}
			if err := validateCounterDerive("opcua_tag_map", i, j, t.Metric, t.CounterDerive); err != nil {
				return err
			}
			if t.Source != nil {
				if err := validateTagSource("opcua_tag_map", i, j, t.Metric, t.Source); err != nil {
					return err
				}
				continue
			}
			if strings.TrimSpace(t.NodeID) == "" {
				return fmt.Errorf("opcua_tag_map[%d].tags[%d] (%s): node_id is required", i, j, t.Metric)
			}
			switch t.Type {
			case "int", "float", "bool", "string":
			default:
				return fmt.Errorf("opcua_tag_map[%d].tags[%d] (%s): type=%q must be int|float|bool|string", i, j, t.Metric, t.Type)
			}
		}
	}
	return nil
}

// validateMapHeader checks the shared per-entry rules of a tag map (endpoint
// reference, tenant-prefix contract, positive equipment id, non-empty tags) —
// the identical head of every s7/modbus/opcua tag-map rule.
func validateMapHeader(section string, i int, endpoint, packmlTopic string, idEquipment, nTags int, knownEndpoints map[string]bool, tenantID string) error {
	if endpoint == "" || !knownEndpoints[endpoint] {
		return fmt.Errorf("%s[%d].endpoint=%q: must reference a plc.endpoints[].name", section, i, endpoint)
	}
	if seg := strings.ToLower(firstTopicSegment(packmlTopic)); seg != tenantID {
		return fmt.Errorf("%s[%d].packml_topic=%q: first segment %q must equal tenant_id %q",
			section, i, packmlTopic, seg, tenantID)
	}
	if idEquipment <= 0 {
		return fmt.Errorf("%s[%d].id_equipment must be > 0", section, i)
	}
	if nTags == 0 {
		return fmt.Errorf("%s[%d] (%s): no tags", section, i, endpoint)
	}
	return nil
}

// validateTagSource checks a DERIVED tag's Source shape (ADR-0045 P2c): exactly
// one of {integral, sum}; integral needs a source; sum needs ≥2 addends. It is
// the clientconfig mirror of the agent-side DerivedMetric validation, so a
// client.yaml that declares a derived tag fails the same way the descriptor does.
func validateTagSource(section string, i, j int, metric string, s *TagSource) error {
	hasIntegral := s.Integral != nil
	hasSum := s.Sum != nil
	if hasIntegral == hasSum {
		return fmt.Errorf("%s[%d].tags[%d] (%s): source must set exactly one of {integral, sum}", section, i, j, metric)
	}
	if hasIntegral && strings.TrimSpace(s.Integral.Source) == "" {
		return fmt.Errorf("%s[%d].tags[%d] (%s): source.integral.source is required", section, i, j, metric)
	}
	if hasSum && len(s.Sum.Addends) < 2 {
		return fmt.Errorf("%s[%d].tags[%d] (%s): source.sum.addends must list at least two suffixes", section, i, j, metric)
	}
	return nil
}

// requireSecretRef enforces "empty, or a secret:// reference" on a CREDENTIAL
// field (dsn_ref). Empty is allowed (the field may simply be unset); a non-empty
// value that isn't a secret reference is a leaked credential and is rejected.
// Host fields relax this — see requireHostRef / requireEndpointURLRef.
func requireSecretRef(section string, idx int, label, field, val string) error {
	if val == "" || strings.HasPrefix(val, secretScheme) {
		return nil
	}
	return fmt.Errorf(
		"%s[%d] (%s): %s=%q must be empty or a %s reference, not a value",
		section, idx, label, field, val, secretScheme)
}

// requireHostRef enforces host_ref is empty, a secret:// reference, OR a literal
// host[:port]. Unlike a credential, a PLC host is NETWORK config — an IP or
// hostname on the factory LAN, the same class of value carried in a compose
// PLC_HOST_* env line; knowing it grants no access. Allowing a literal here is
// what lets the turnkey bundle generator PREFILL PLC_HOST_* from the descriptor
// (F9) instead of leaving the CS engineer a blank per-PLC line. Credential
// fields (dsn_ref) deliberately do NOT get this relaxation — they stay
// requireSecretRef.
func requireHostRef(section string, idx int, label, field, val string) error {
	if val == "" || strings.HasPrefix(val, secretScheme) || IsLiteralHost(val) {
		return nil
	}
	return fmt.Errorf(
		"%s[%d] (%s): %s=%q must be empty, a %s reference, or a literal host[:port]",
		section, idx, label, field, val, secretScheme)
}

// requireEndpointURLRef is the OPC-UA analogue of requireHostRef: empty, a
// secret:// reference, OR a literal opc.tcp:// endpoint URL. Any other scheme
// (or a bare host without opc.tcp://) is rejected.
func requireEndpointURLRef(section string, idx int, label, field, val string) error {
	if val == "" || strings.HasPrefix(val, secretScheme) || IsOPCUAEndpointURL(val) {
		return nil
	}
	return fmt.Errorf(
		"%s[%d] (%s): %s=%q must be empty, a %s reference, or an opc.tcp:// URL",
		section, idx, label, field, val, secretScheme)
}

// opcuaURLScheme is the only URL scheme an OPC-UA endpoint literal may carry.
const opcuaURLScheme = "opc.tcp://"

// IsLiteralHost reports whether val is a bare PLC host: an IPv4 address or a DNS
// hostname, each with an OPTIONAL ":port". It deliberately rejects anything
// carrying a scheme, path, credentials or whitespace (an "opc.tcp://…" URL or an
// "oracle://user:pass@…" DSN is NOT a host). Exported so the descriptor validator
// (clientdescriptor) reuses the exact same rule — one definition of "literal
// host", so the descriptor and the client.yaml it generates accept the same shape.
func IsLiteralHost(val string) bool {
	host := val
	// net.SplitHostPort succeeds only when there's exactly one ':' — a bare host
	// ("10.0.0.7") returns a "missing port" error and is left whole; a scheme'd
	// value ("opc.tcp://…") has too many colons and is likewise left whole (then
	// rejected below). When a port IS present it must be a valid 1..65535.
	if h, p, err := net.SplitHostPort(val); err == nil {
		host = h
		port, perr := strconv.Atoi(p)
		if perr != nil || port < 1 || port > 65535 {
			return false
		}
	}
	if host == "" {
		return false
	}
	if net.ParseIP(host) != nil {
		return true
	}
	return isHostname(host)
}

// IsOPCUAEndpointURL reports whether val is a literal OPC-UA endpoint URL —
// "opc.tcp://<host>[:port][/path]". The host portion must itself be a literal
// host (IsLiteralHost); the optional path is accepted verbatim. Exported for the
// same cross-package reuse reason as IsLiteralHost.
func IsOPCUAEndpointURL(val string) bool {
	if !strings.HasPrefix(val, opcuaURLScheme) {
		return false
	}
	rest := val[len(opcuaURLScheme):]
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		rest = rest[:i] // strip the optional /path, leaving host[:port]
	}
	return IsLiteralHost(rest)
}

// isHostname reports whether h is a syntactically valid DNS hostname: dot-joined
// labels of [A-Za-z0-9-], each 1..63 chars and not starting/ending in '-'.
func isHostname(h string) bool {
	if len(h) == 0 || len(h) > 253 {
		return false
	}
	for _, label := range strings.Split(h, ".") {
		if label == "" || len(label) > 63 {
			return false
		}
		for i := 0; i < len(label); i++ {
			c := label[i]
			switch {
			case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '-':
			default:
				return false
			}
		}
		if label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
	}
	return true
}

// firstTopicSegment returns the substring of topic before the first '/'
// (the whole string if there is no '/'). This is the Sparkplug group_id
// that must match tenant_id.
func firstTopicSegment(topic string) string {
	if i := strings.IndexByte(topic, '/'); i >= 0 {
		return topic[:i]
	}
	return topic
}

// Tenants returns the single-element tenant list this transformer
// instance is responsible for. The skeleton ships ONE tenant per
// container — same factory-per-container model as edge-node-red today.
// Returned as a slice to match the shape oeecloud-worker's amqp.Consumer
// expects (it consumes from N per-tenant queues in one process; we
// consume from 1, but the topology code generalizes).
func (c *Config) Tenants() []string {
	return []string{c.TenantID}
}
