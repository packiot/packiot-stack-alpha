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
	"os"
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

	// Equipments is the static topic→equipment mapping. Empty in the
	// skeleton; Phase 2 fills it from packml_register exports or
	// CS-Admin onboarding output.
	Equipments []EquipmentMapping `yaml:"equipments,omitempty"`

	// PLC (v1.1) describes how this factory's PLC is reached. Optional;
	// nil for skeleton configs. Hosts are carried by REFERENCE only
	// (host_ref: secret://…) — never inline values (the Incoplast
	// cleartext-credentials lesson, made structural).
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

// PLCEndpoint is one reachable PLC. HostRef / EndpointURLRef are secret
// references, never values; Rack/Slot are S7-specific (the schema gap ADR-0019
// named) and UnitID is Modbus-specific — all pointers so "absent" is
// distinguishable from "0".
type PLCEndpoint struct {
	Name    string `yaml:"name,omitempty"`
	HostRef string `yaml:"host_ref,omitempty"`
	Rack    *int   `yaml:"rack,omitempty"`
	Slot    *int   `yaml:"slot,omitempty"`
	// UnitID (Modbus) is the unit/slave id byte in the MBAP header — usually 1
	// on a native Ethernet device, or the RTU address behind a serial gateway.
	// Pointer so "absent" is distinguishable from "0" (a valid broadcast id).
	UnitID *int `yaml:"unit_id,omitempty"`
	// EndpointURLRef (OPC-UA) is a secret reference to the server URL
	// (opc.tcp://host:port/path) — the OPC-UA analogue of host_ref. Never a
	// value; the requireSecretRef check rejects an inline URL.
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
	// Normalize BEFORE validate: lowercased tenant id to match the
	// per-tenant queue naming convention used in internal/amqp/topology.go.
	// CS Admin often writes uppercase customer codes (CPACK, SIMCORP) so
	// the normalize step here saves a class of "almost-matches" bugs.
	// Doing it first also lets validateV11's tenant_id↔topic check compare
	// the canonical (lowercased) form directly.
	cfg.TenantID = strings.ToLower(strings.TrimSpace(cfg.TenantID))
	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("validate %s: %w", path, err)
	}
	return &cfg, nil
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
//  1. No secret VALUES anywhere: any host_ref / dsn_ref / endpoint_url_ref that
//     is present must be a secret://… reference. There is deliberately NO
//     plain-host field that could hold a value — the type system won't let you
//     write one, and this check rejects a value smuggled through the ref field.
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
	// Rule 1a — plc endpoint hosts / URLs are references, never values.
	if c.PLC != nil {
		for i, ep := range c.PLC.Endpoints {
			if err := requireSecretRef("plc.endpoints", i, ep.Name, "host_ref", ep.HostRef); err != nil {
				return err
			}
			if err := requireSecretRef("plc.endpoints", i, ep.Name, "endpoint_url_ref", ep.EndpointURLRef); err != nil {
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

// requireSecretRef enforces "empty, or a secret:// reference" on a host/dsn
// field. Empty is allowed (the field may simply be unset); a non-empty
// value that isn't a secret reference is a leaked credential and is rejected.
func requireSecretRef(section string, idx int, label, field, val string) error {
	if val == "" || strings.HasPrefix(val, secretScheme) {
		return nil
	}
	return fmt.Errorf(
		"%s[%d] (%s): %s=%q must be empty or a %s reference, not a value",
		section, idx, label, field, val, secretScheme)
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
